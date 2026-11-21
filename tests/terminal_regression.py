#!/usr/bin/env python3
"""PTY transport regression/benchmark; does not verify terminal rendering."""
import argparse
import base64
import json
import os
import pty
import re
import select
import subprocess
import termios
import tempfile
import time
import zlib


def decode_frames(raw):
    if b"\x1bPtmux;" in raw:
        raw = raw.replace(b"\x1bPtmux;", b"").replace(b"\x1b\x1b", b"\x1b").replace(b"\x1b\\\x1b\\", b"\x1b\\")
    frames = []
    encoded = bytearray()
    for header, payload in re.findall(rb"\x1b_G([^;]*);(.*?)\x1b\\", raw, re.S):
        if b"a=q" in header:
            continue
        encoded.extend(payload)
        if b"m=0" in header:
            frame = zlib.decompress(base64.b64decode(encoded))
            assert len(frame) == 256 * 128 * 3
            frames.append(frame)
            encoded.clear()
    return frames


ROW_MARKERS = [0x305, 0x30d, 0x30e, 0x310, 0x312, 0x33d, 0x33e, 0x33f,
               0x346, 0x34a, 0x34b, 0x34c, 0x350, 0x351, 0x352, 0x357]


def verify_placeholder_coordinates(raw):
    # Check what tmux sends to the outer terminal, not just capture-pane text.
    # Previously each cell was emitted in partial forms (zero/one/two marks),
    # which passed the pane ownership test but could render repeated image bands.
    text = raw.decode("utf8", errors="replace")
    marks = re.findall("\U0010eeee([\u0300-\u036f]*)", text)
    assert len(marks) >= 64 * 16, "incomplete initial image grid"
    assert all(len(mark) == 1 and ord(mark) in ROW_MARKERS for mark in marks), "partial or ambiguous image cell coordinates"
    expected = [chr(mark) for mark in ROW_MARKERS for _ in range(64)]
    assert marks[:64 * 16] == expected, "image row coordinates changed through tmux"


def run(core, firmware, transport, fps, seconds, key=b"q", native=False, graphics="kitty", through_tmux=False, unknown=False, passthrough_reply=False):
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)
    env = dict(os.environ, TERM="xterm-ghostty", TERM_PROGRAM="ghostty")
    if transport != "direct":
        env["TMUX"] = "/tmp/chemu-test,1,0"
    else:
        env.pop("TMUX", None)
    if unknown:
        env["TERM"] = "tmux-256color"
        env["TERM_PROGRAM"] = "tmux"
        env.pop("KITTY_WINDOW_ID", None)
        env.pop("GHOSTTY_RESOURCES_DIR", None)
    cmd = [core, "--elf", firmware, "--graphics", graphics, "--kitty-transport", transport,
           "--target-fps", str(fps), "--stats"]
    config = None
    socket = "chemu-regression-" + str(os.getpid())
    if through_tmux:
        config = tempfile.NamedTemporaryFile(mode="w", suffix=".conf")
        config.write("set -g allow-passthrough on\nset -g status off\n")
        config.flush()
        env.pop("TMUX", None)
        cmd = ["tmux", "-L", socket, "-f", config.name, "new-session", "-x", "80", "-y", "24", "--"] + cmd
    proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, env=env)
    output = bytearray()
    started = time.monotonic()
    pane_checks = False
    sent = False
    replied = False
    latency = []
    awaiting = None
    event_index = 0
    rss = 0
    next_sample = 0
    try:
        while proc.poll() is None:
            elapsed = time.monotonic() - started
            if graphics != "sixel" and seconds >= 2 and event_index < 2 and elapsed >= (0.7, 1.5)[event_index]:
                os.write(master, (b"d", b"u")[event_index])
                awaiting = (time.monotonic(), (0, 255)[event_index], len(decode_frames(bytes(output))))
                event_index += 1
            if through_tmux and seconds >= 2 and elapsed >= 1.0 and not pane_checks:
                def control(*args):
                    return subprocess.check_output(["tmux", "-L", socket, *args])
                original = control("display-message", "-p", "#{pane_id}").decode().strip()
                other = control("split-window", "-h", "-d", "-P", "-F", "#{pane_id}", "sleep 15").decode().strip()
                marker = "\U0010eeee".encode()
                assert marker in control("capture-pane", "-p", "-t", original), "image cells missing from owning pane"
                control("select-pane", "-t", other)
                assert marker not in control("capture-pane", "-p", "-t", other), "image cells leaked into other pane"
                control("select-pane", "-t", original)
                assert marker in control("capture-pane", "-p", "-t", original), "image cells lost on return"
                window = control("new-window", "-d", "-P", "-F", "#{window_id}", "sleep 15").decode().strip()
                control("select-window", "-t", window)
                assert marker not in control("capture-pane", "-p"), "image cells leaked into other window"
                control("select-pane", "-t", original)
                control("select-window", "-t", original)
                control("kill-window", "-t", window)
                control("kill-pane", "-t", other)
                pane_checks = True
            if elapsed > seconds and not sent:
                os.write(master, key)
                sent = True
            if elapsed > seconds + 3:
                raise AssertionError("quit did not terminate emulator")
            if select.select([master], [], [], 0.01)[0]:
                output.extend(os.read(master, 65536))
                if awaiting is not None:
                    frames_now = decode_frames(bytes(output))
                    event_time, expected_pixel, previous_count = awaiting
                    if len(frames_now) > previous_count and frames_now[-1][0] == expected_pixel:
                        latency.append(round((time.monotonic() - event_time) * 1000, 2))
                        awaiting = None
            if native and not replied and b"a=q,i=2147483646" in output and (not passthrough_reply or b"\x1bPtmux;" in output):
                os.write(master, b"\x1b_Gi=2147483646;OK\x1b\\")
                replied = True
            if elapsed >= next_sample:
                next_sample = elapsed + 0.25
                value = subprocess.check_output(["ps", "-o", "rss=", "-p", str(proc.pid)]).strip()
                if value:
                    rss = max(rss, int(value))
        while select.select([master], [], [], 0)[0]:
            output.extend(os.read(master, 65536))
        assert proc.returncode == 0, output[-2000:]
        after = termios.tcgetattr(slave)
        # macOS sets transient PENDIN when canonical processing is restored.
        pending = getattr(termios, "PENDIN", 0)
        before[3] &= ~pending
        after[3] &= ~pending
        assert before == after, ("termios was not restored", before, after)
        if not through_tmux:
            assert b"\x1b[<1u" in output and b"\x1b[?25h\x1b[?1049l" in output
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        if through_tmux:
            subprocess.run(["tmux", "-L", socket, "kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            config.close()
        os.close(master)
        os.close(slave)
    raw = bytes(output)
    wrapped = b"\x1bPtmux;\x1b\x1b_Ga=T" in raw
    assert wrapped == (graphics != "sixel" and transport != "direct" and (not native or passthrough_reply) and not through_tmux)
    unwrapped = raw
    if wrapped:
        unwrapped = raw.replace(b"\x1bPtmux;", b"").replace(b"\x1b\x1b", b"\x1b").replace(b"\x1b\\\x1b\\", b"\x1b\\")
    if through_tmux:
        verify_placeholder_coordinates(raw)
    frames = decode_frames(raw)
    if graphics != "sixel":
        assert len(frames) >= 2 and any(frame != frames[0] for frame in frames[1:])
        image_ids = re.findall(rb"a=T,[^;]*?i=(\d+),", unwrapped)
        assert image_ids and len(set(image_ids)) == 1
        assert b"a=d,d=I,i=" + image_ids[0] + b",q=2" in unwrapped
        uses_placeholders = transport != "direct" and (not native or passthrough_reply)
        if uses_placeholders:
            assert b"U=1" in unwrapped
            assert "\U0010eeee".encode() in unwrapped
        else:
            assert b"U=1" not in unwrapped
    else:
        assert b"\x1bPq" in raw
    if graphics != "sixel" and seconds >= 2:
        assert len(latency) == 2, ("button did not update OLED", latency)
    stats = re.findall(rb"stats fps=([\d.]+) step/s=([\d.]+).*?output=([\d.]+)", raw)
    result = dict(transport=transport, native_reply=native, graphics=graphics, target_fps=fps,
                  frames=len(frames), pane_switch_checks=pane_checks, peak_sampled_rss_kib=rss, captured_bytes=len(raw), input_to_pty_ms=latency)
    if stats:
        for index, name in enumerate(["fps", "steps_per_s", "kib_per_s"]):
            result[name] = round(sum(float(row[index]) for row in stats) / len(stats), 2)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--core", default="zig-out/bin/ch32fun-desktop-emulator")
    parser.add_argument("--firmware", default="/tmp/chemu-animated.elf")
    parser.add_argument("--through-tmux", action="store_true")
    parser.add_argument("--target-fps", type=int, default=30)
    parser.add_argument("--seconds", type=float, default=3)
    args = parser.parse_args()
    try:
        verify_placeholder_coordinates(("\U0010eeee\b\U0010eeee\u0305\b\U0010eeee\u0305\u0305" * 1024).encode())
    except AssertionError:
        pass
    else:
        raise AssertionError("coordinate regression accepted the old broken wire form")
    if args.through_tmux:
        print(json.dumps(run(args.core, args.firmware, "tmux", args.target_fps, args.seconds, through_tmux=True), indent=2))
        return
    results = [run(args.core, args.firmware, transport, fps, args.seconds)
               for fps in (30, 60) for transport in ("direct", "tmux")]
    results.append(run(args.core, args.firmware, "auto", 30, 0.3, native=True))
    results.append(run(args.core, args.firmware, "auto", 30, 0.3))
    results.append(run(args.core, args.firmware, "auto", 30, 0.3, native=True, graphics="auto", unknown=True))
    results.append(run(args.core, args.firmware, "auto", 30, 0.3, native=True, graphics="auto", unknown=True, passthrough_reply=True))
    results.append(run(args.core, args.firmware, "direct", 30, 0.3, graphics="sixel"))
    for key in (b"\x1b", b"\x03"):
        run(args.core, args.firmware, "direct", 30, 0.3, key=key)
    headless = subprocess.run([args.core, "--elf", args.firmware, "--headless", "--steps", "200000"], capture_output=True)
    assert headless.returncode == 0, headless.stderr
    assert re.search(rb"nonzero_vram=[1-9]", headless.stderr)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
