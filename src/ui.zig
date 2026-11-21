const std = @import("std");
const bus_mod = @import("bus.zig");

const oled_width = 128;
const oled_height = 64;
// The terminal scales the image to 64x16 cells, so 2x source pixels retain
// sharp OLED pixels while avoiding the cost of compressing a 512x256 frame.
const kitty_scale = 2;
const kitty_width = oled_width * kitty_scale;
const kitty_height = oled_height * kitty_scale;
const kitty_rgb_len = kitty_width * kitty_height * 3;
// DEFLATE's worst-case overhead is well below one percent for this input.
const kitty_compressed_capacity = kitty_rgb_len + kitty_rgb_len / 100 + 64;
const kitty_encoded_len = std.base64.standard.Encoder.calcSize(kitty_compressed_capacity);
const legacy_button_pulse_ms = 600;

pub const Protocol = enum {
    auto,
    kitty,
    sixel,
};

pub const Transport = enum { auto, direct, tmux };

pub const Ui = struct {
    pub const Stats = struct {
        frames_presented: u64,
        texture_uploads: u64,
        acquire_timeout_count: u64,
        bytes_written: u64,
    };

    protocol: Protocol,
    transport: Transport = .direct,
    in_tmux: bool = false,
    image_id: u32 = 1,
    placeholder_size: ?CellSize = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    original_termios: std.posix.termios,
    kitty_rgb: []u8,
    kitty_compressed: []u8,
    kitty_encoded: []u8,
    flate_buffer: []u8,
    button_release_deadline_ns: ?i96 = null,
    frames_presented: u64 = 0,
    bytes_written: u64 = 0,
    last_vram: [128 * 64 / 8]u8 = @splat(0),
    has_presented_frame: bool = false,
    startup_input: [256]u8 = undefined,
    startup_input_len: usize = 0,
    pending_input: [256]u8 = undefined,
    pending_input_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, protocol: Protocol, transport: Transport, environ: *const std.process.Environ.Map) !Ui {
        var selected = if (protocol == .auto) detectProtocol(environ) catch Protocol.auto else protocol;
        const kitty_rgb = try allocator.alloc(u8, kitty_rgb_len);
        errdefer allocator.free(kitty_rgb);
        const kitty_compressed = try allocator.alloc(u8, kitty_compressed_capacity);
        errdefer allocator.free(kitty_compressed);
        const kitty_encoded = try allocator.alloc(u8, kitty_encoded_len);
        errdefer allocator.free(kitty_encoded);
        const flate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(flate_buffer);
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        errdefer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};

        var startup_input: [256]u8 = undefined;
        var startup_input_len: usize = 0;
        var selected_transport = selectTransport(transport, environ);
        // Query unknown environments, including tmux sessions that did not
        // inherit any outer-terminal hints. Prefer verified native support.
        if (selected == .auto) {
            if (try probeKitty(io, &startup_input, &startup_input_len, if (transport == .auto) .direct else selected_transport)) {
                selected = .kitty;
                if (transport == .auto) selected_transport = .direct;
            } else if (transport == .auto and environ.get("TMUX") != null and try probeKitty(io, &startup_input, &startup_input_len, .tmux)) {
                selected = .kitty;
                selected_transport = .tmux;
            } else {
                std.log.err("unknown terminal graphics capability; specify --graphics kitty or --graphics sixel (or --headless)", .{});
                return error.UnknownGraphicsCapability;
            }
        } else if (selected == .kitty and transport == .auto and environ.get("TMUX") != null) {
            if (try probeKitty(io, &startup_input, &startup_input_len, .direct)) selected_transport = .direct;
        }

        var image_id: u32 = undefined;
        std.Io.random(io, std.mem.asBytes(&image_id));
        image_id = (image_id & 0xffffff) | 1;

        // Older emulator versions accidentally pushed keyboard modes onto the
        // main-screen stack and popped the alternate-screen stack. Clear those
        // leaked entries before switching screens; popping an empty stack is a
        // harmless reset according to the protocol.
        try writeAll(io, "\x1b[<64u");

        // Kitty keyboard mode is scoped to the active screen buffer. Enter the
        // alternate screen first so this push is paired with deinit's pop on
        // that same buffer and cannot leak into the user's shell.
        try writeAll(io, "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H\x1b[>3u");
        std.log.info("terminal graphics protocol: {s} (Kitty transport: {s})", .{ @tagName(selected), @tagName(selected_transport) });
        return .{
            .protocol = selected,
            .image_id = image_id,
            .transport = selected_transport,
            .startup_input = startup_input,
            .startup_input_len = startup_input_len,
            .in_tmux = environ.get("TMUX") != null,
            .allocator = allocator,
            .io = io,
            .original_termios = original,
            .kitty_rgb = kitty_rgb,
            .kitty_compressed = kitty_compressed,
            .kitty_encoded = kitty_encoded,
            .flate_buffer = flate_buffer,
        };
    }

    pub fn deinit(self: *Ui) void {
        // Pop exactly one Kitty keyboard mode entry before giving stdin back
        // to the shell, then consume key-release reports already in flight.
        writeAll(self.io, "\x1b[<1u") catch {};
        drainTerminalInput(self.io);
        if (self.protocol == .kitty) {
            var command: [80]u8 = undefined;
            const deletion = std.fmt.bufPrint(&command, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{self.image_id}) catch unreachable;
            self.sendKitty(deletion) catch {};
        }
        writeAll(self.io, "\x1b[?25h\x1b[?1049l") catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, self.original_termios) catch {};
        self.allocator.free(self.kitty_encoded);
        self.allocator.free(self.kitty_compressed);
        self.allocator.free(self.flate_buffer);
        self.allocator.free(self.kitty_rgb);
    }

    pub fn pumpEvents(self: *Ui, bus: *bus_mod.Bus) bool {
        self.expireButton(bus, nowNs(self.io));
        if (self.startup_input_len > 0) {
            const len = self.startup_input_len;
            self.startup_input_len = 0;
            if (!self.processInput(bus, self.startup_input[0..len])) return false;
        }

        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if ((std.posix.poll(&fds, 0) catch return true) == 0) return true;

        var input: [32]u8 = undefined;
        const count = std.posix.read(std.posix.STDIN_FILENO, &input) catch return true;
        return self.processInput(bus, input[0..count]);
    }

    fn expireButton(self: *Ui, bus: *bus_mod.Bus, now: i96) void {
        if (self.button_release_deadline_ns) |deadline| if (now >= deadline) {
            bus.setButtonPressed(false);
            self.button_release_deadline_ns = null;
        };
    }

    fn processInput(self: *Ui, bus: *bus_mod.Bus, incoming: []const u8) bool {
        if (incoming.len > self.pending_input.len - self.pending_input_len) {
            self.pending_input_len = 0;
            return true;
        }
        @memcpy(self.pending_input[self.pending_input_len..][0..incoming.len], incoming);
        self.pending_input_len += incoming.len;
        const input = self.pending_input[0..self.pending_input_len];
        var index: usize = 0;
        while (index < input.len) {
            if (input.len - index == 2 and input[index] == 27 and (input[index + 1] == '[' or input[index + 1] == 'O')) {
                self.keepInputSuffix(index);
                return true;
            }
            if (std.mem.startsWith(u8, input[index..], "\x1b_")) {
                const end = std.mem.indexOf(u8, input[index + 2 ..], "\x1b\\") orelse {
                    self.keepInputSuffix(index);
                    return true;
                };
                index += 2 + end + 2;
                continue;
            }
            if (input[index] == 0x1b and index + 2 < input.len and input[index + 1] == 'O' and
                (input[index + 2] == 'C' or input[index + 2] == 'D'))
            {
                bus.queueRotaryStep(if (input[index + 2] == 'C') 1 else -1);
                index += 3;
                continue;
            }
            if (input[index] == 0x1b and index + 2 < input.len and input[index + 1] == '[') {
                var final = index + 2;
                while (final < input.len and (input[final] < 0x40 or input[final] > 0x7e)) : (final += 1) {}
                if (final == input.len) {
                    self.keepInputSuffix(index);
                    return true;
                }

                const final_byte = input[final];
                const parameters = input[index + 2 .. final];
                if (final_byte == 'C' or final_byte == 'D') {
                    if (keyEventType(parameters) != 3) {
                        bus.queueRotaryStep(if (final_byte == 'C') 1 else -1);
                    }
                    index = final + 1;
                    continue;
                }
                if (final_byte != 'u') {
                    // A lone Escape remains the quit key.
                    if (index + 1 == input.len) return false;
                    index = final + 1;
                    continue;
                }
                if (!self.processKittyKey(bus, parameters)) return false;
                index = final + 1;
                continue;
            }

            switch (input[index]) {
                3, 27, 'q' => return false,
                // Legacy terminals do not report key-up. Keep a normal Space
                // press active long enough for firmware to detect a 500 ms
                // long press despite input polling latency.
                ' ' => {
                    bus.setButtonPressed(true);
                    self.button_release_deadline_ns = nowNs(self.io) + legacy_button_pulse_ms * std.time.ns_per_ms;
                },
                // Portable explicit switch controls for terminals without the
                // Kitty keyboard protocol: d=contact down, u=contact up.
                'd' => {
                    bus.setButtonPressed(true);
                    self.button_release_deadline_ns = null;
                },
                'u' => {
                    bus.setButtonPressed(false);
                    self.button_release_deadline_ns = null;
                },
                else => {},
            }
            index += 1;
        }
        self.pending_input_len = 0;
        return true;
    }

    fn keepInputSuffix(self: *Ui, start: usize) void {
        std.mem.copyForwards(u8, &self.pending_input, self.pending_input[start..self.pending_input_len]);
        self.pending_input_len -= start;
    }

    fn processKittyKey(self: *Ui, bus: *bus_mod.Bus, parameters: []const u8) bool {
        const key_end = std.mem.indexOfAny(u8, parameters, ";:") orelse parameters.len;
        const codepoint = std.fmt.parseInt(u21, parameters[0..key_end], 10) catch return true;
        const event = keyEventType(parameters);

        if (codepoint == 27 or codepoint == 'q' or (codepoint == 'c' and std.mem.indexOf(u8, parameters, ";5") != null)) return false;
        if (codepoint == ' ') {
            if (event == 3) {
                bus.setButtonPressed(false);
            } else {
                bus.setButtonPressed(true);
            }
            self.button_release_deadline_ns = if (event != 3 and self.in_tmux) nowNs(self.io) + legacy_button_pulse_ms * std.time.ns_per_ms else null;
        } else if (codepoint == 'd' and event != 3) {
            bus.setButtonPressed(true);
            self.button_release_deadline_ns = null;
        } else if (codepoint == 'u' and event != 3) {
            bus.setButtonPressed(false);
            self.button_release_deadline_ns = null;
        }
        return true;
    }

    pub fn present(self: *Ui, bus: *const bus_mod.Bus) !void {
        const placeholders = self.protocol == .kitty and self.transport == .tmux;
        const size = if (placeholders) terminalCellSize() else CellSize{ .cols = 0, .rows = 0 };
        const layout_changed = placeholders and (self.placeholder_size == null or !std.meta.eql(self.placeholder_size.?, size));
        if (!layout_changed and self.has_presented_frame and std.mem.eql(u8, &self.last_vram, &bus.oled.vram)) return;
        switch (self.protocol) {
            .kitty => try self.presentKitty(bus),
            .sixel => try presentSixel(self.io, bus),
            .auto => unreachable,
        }
        if (layout_changed) {
            var grid: [12000]u8 = undefined;
            const output = try placeholderGrid(&grid, self.image_id, size, self.placeholder_size != null);
            try writeAll(self.io, output);
            self.bytes_written += output.len;
            self.placeholder_size = size;
        }
        @memcpy(&self.last_vram, &bus.oled.vram);
        self.has_presented_frame = true;
        self.frames_presented += 1;
    }

    fn presentKitty(self: *Ui, bus: *const bus_mod.Bus) !void {
        // Expand each source row once, then copy it vertically. This avoids a
        // division and VRAM lookup for every one of the 131,072 output pixels.
        var source_y: usize = 0;
        while (source_y < oled_height) : (source_y += 1) {
            const first_row = source_y * kitty_scale * kitty_width * 3;
            var source_x: usize = 0;
            while (source_x < oled_width) : (source_x += 1) {
                const value: u8 = if (pixel(bus, source_x, source_y)) 0xff else 0x00;
                const offset = first_row + source_x * kitty_scale * 3;
                @memset(self.kitty_rgb[offset .. offset + kitty_scale * 3], value);
            }
            const row = self.kitty_rgb[first_row .. first_row + kitty_width * 3];
            var repeat: usize = 1;
            while (repeat < kitty_scale) : (repeat += 1) {
                const offset = first_row + repeat * kitty_width * 3;
                @memcpy(self.kitty_rgb[offset .. offset + kitty_width * 3], row);
            }
        }

        var compressed_writer = std.Io.Writer.fixed(self.kitty_compressed);
        var compressor = try std.compress.flate.Compress.init(
            &compressed_writer,
            self.flate_buffer,
            .zlib,
            .fastest,
        );
        try compressor.writer.writeAll(self.kitty_rgb);
        try compressor.finish();
        const compressed = compressed_writer.buffered();
        const encoded_len = std.base64.standard.Encoder.calcSize(compressed.len);
        _ = std.base64.standard.Encoder.encode(self.kitty_encoded[0..encoded_len], compressed);

        if (self.transport != .tmux) {
            try writeAll(self.io, "\x1b[2;3H");
            self.bytes_written += 6;
        }
        var offset: usize = 0;
        while (offset < encoded_len) {
            var command: [4300]u8 = undefined;
            const end = @min(offset + 4096, encoded_len);
            const apc = try kittyChunk(&command, self.kitty_encoded[offset..end], offset == 0, end < encoded_len, self.image_id, self.transport == .tmux);
            try self.sendKitty(apc);
            offset = end;
        }
    }

    fn sendKitty(self: *Ui, apc: []const u8) !void {
        var buffer: [8700]u8 = undefined;
        const output = try wrapKitty(&buffer, apc, self.transport);
        try writeAll(self.io, output);
        self.bytes_written += output.len;
    }

    pub fn writeStatus(self: *Ui, message: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.writeAll("\x1b7\x1b[1;1H\x1b[2K");
        const width = terminalCellSize().cols -| 1;
        try writer.writeAll(message[0..@min(width, message.len)]);
        try writer.writeAll("\x1b8");
        try writeAll(self.io, writer.buffered());
    }

    pub fn stats(self: *const Ui) Stats {
        return .{
            .frames_presented = self.frames_presented,
            .texture_uploads = self.frames_presented,
            .acquire_timeout_count = 0,
            .bytes_written = self.bytes_written,
        };
    }
};

fn keyEventType(parameters: []const u8) u8 {
    const modifiers = std.mem.indexOfScalar(u8, parameters, ';') orelse return 1;
    const colon = std.mem.indexOfScalarPos(u8, parameters, modifiers + 1, ':') orelse return 1;
    const event_end = std.mem.indexOfScalarPos(u8, parameters, colon + 1, ';') orelse parameters.len;
    return std.fmt.parseInt(u8, parameters[colon + 1 .. event_end], 10) catch 1;
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn drainTerminalInput(io: std.Io) void {
    const deadline = nowNs(io) + 60 * std.time.ns_per_ms;
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var discard: [128]u8 = undefined;
    // Wait for a short quiet period because a key-up report may be emitted
    // just after the keyboard protocol is disabled.
    while (nowNs(io) < deadline and (std.posix.poll(&fds, 25) catch return) != 0) {
        if ((std.posix.read(std.posix.STDIN_FILENO, &discard) catch return) == 0) return;
        fds[0].revents = 0;
    }
}

// The query does not create an image. Keep ordinary input received during the
// bounded startup probe; strip only its complete graphics response.
fn probeKitty(io: std.Io, input: []u8, len: *usize, transport: Transport) !bool {
    var buffer: [128]u8 = undefined;
    try writeAll(io, try wrapKitty(&buffer, "\x1b_Ga=q,i=2147483646,f=24,s=1,v=1;AAAA\x1b\\", transport));
    const deadline = nowNs(io) + 60 * std.time.ns_per_ms;
    while (len.* < input.len) {
        const remaining = deadline - nowNs(io);
        if (remaining <= 0) break;
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(@max(1, @divTrunc(remaining, std.time.ns_per_ms)))) == 0) break;
        const count = try std.posix.read(std.posix.STDIN_FILENO, input[len.*..]);
        if (count == 0) break;
        len.* += count;
        if (takeProbeReply(input, len)) |supported| return supported;
    }
    return false;
}

fn takeProbeReply(input: []u8, len: *usize) ?bool {
    const start = std.mem.indexOf(u8, input[0..len.*], "\x1b_Gi=2147483646;") orelse return null;
    const end = start + (std.mem.indexOf(u8, input[start..len.*], "\x1b\\") orelse return null) + 2;
    const supported = std.mem.endsWith(u8, input[start..end], ";OK\x1b\\");
    std.mem.copyForwards(u8, input[start..], input[end..len.*]);
    len.* -= end - start;
    return supported;
}

fn selectTransport(requested: Transport, environ: *const std.process.Environ.Map) Transport {
    return if (requested != .auto) requested else if (environ.get("TMUX") != null) .tmux else .direct;
}

fn detectProtocol(environ: *const std.process.Environ.Map) !Protocol {
    if (environ.get("KITTY_WINDOW_ID") != null or environ.get("GHOSTTY_RESOURCES_DIR") != null) return .kitty;
    if (environ.get("TERM_PROGRAM")) |program| {
        if (std.mem.eql(u8, program, "ghostty") or std.mem.eql(u8, program, "kitty")) return .kitty;
    }
    if (environ.get("TERM")) |term| {
        if (std.mem.indexOf(u8, term, "kitty") != null or std.mem.eql(u8, term, "xterm-ghostty")) return .kitty;
        if (std.mem.indexOf(u8, term, "sixel") != null) return .sixel;
    }
    return error.UnknownGraphicsCapability;
}

const CellSize = struct { cols: u16, rows: u16 };

fn terminalCellSize() CellSize {
    var size: std.posix.winsize = undefined;
    const builtin = @import("builtin");
    const result = if (builtin.os.tag == .linux)
        std.os.linux.ioctl(std.posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size))
    else
        std.c.ioctl(std.posix.STDOUT_FILENO, std.c.T.IOCGWINSZ, &size);
    if (result != 0 or size.col == 0 or size.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = size.col, .rows = size.row };
}

// First 16 row markers from Kitty's canonical rowcolumn-diacritics.txt.
// Columns follow the protocol's left-to-right inheritance rule. A single
// combining mark per cell avoids tmux rewriting partial multi-mark graphemes.
const diacritics = [_]u21{
    0x0305, 0x030d, 0x030e, 0x0310, 0x0312, 0x033d, 0x033e, 0x033f,
    0x0346, 0x034a, 0x034b, 0x034c, 0x0350, 0x0351, 0x0352, 0x0357,
};

fn placeholderGrid(buffer: []u8, image_id: u32, size: CellSize, clear: bool) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    // Batch the text grid in tmux so it emits completed graphemes instead of
    // base/combining-mark backspace rewrites that confuse placeholder rows.
    try writer.writeAll("\x1b[?2026h\x1b7");
    if (clear) try writer.writeAll("\x1b[2J");
    try writer.print("\x1b[0m\x1b[38;2;{d};{d};{d}m", .{ (image_id >> 16) & 255, (image_id >> 8) & 255, image_id & 255 });
    const cols = @min(64, size.cols -| 2);
    const rows = @min(16, size.rows -| 1);
    for (0..rows) |row| {
        try writer.print("\x1b[{d};3H", .{row + 2});
        for (0..cols) |_| {
            try writer.writeAll("\u{10eeee}");
            var encoded: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(diacritics[row], &encoded);
            try writer.writeAll(encoded[0..len]);
        }
    }
    try writer.writeAll("\x1b[0m\x1b8\x1b[?2026l");
    return writer.buffered();
}

fn kittyChunk(buffer: []u8, payload: []const u8, first: bool, more: bool, image_id: u32, virtual: bool) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (first) {
        try writer.print("\x1b_Ga=T,f=24,o=z,s={d},v={d},c=64,r=16,i={d},q=2,C=1,{s}m={d};", .{ kitty_width, kitty_height, image_id, if (virtual) "U=1," else "", @intFromBool(more) });
    } else try writer.print("\x1b_Gm={d};", .{@intFromBool(more)});
    try writer.writeAll(payload);
    try writer.writeAll("\x1b\\");
    return writer.buffered();
}

fn wrapKitty(buffer: []u8, apc: []const u8, transport: Transport) ![]const u8 {
    if (transport != .tmux) return apc;
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("\x1bPtmux;");
    for (apc) |byte| {
        try writer.writeByte(byte);
        if (byte == 27) try writer.writeByte(byte);
    }
    try writer.writeAll("\x1b\\");
    return writer.buffered();
}

fn pixel(bus: *const bus_mod.Bus, x: usize, y: usize) bool {
    return (bus.oled.vram[(y / 8) * 128 + x] & (@as(u8, 1) << @as(u3, @intCast(y & 7)))) != 0;
}

fn encodeSixel(output: []u8, bus: *const bus_mod.Bus) ![]const u8 {
    var stream = std.Io.Writer.fixed(output);
    try stream.writeAll("\x1b7\x1b[2;3H\x1bPq\"1;1;128;64#0;2;0;0;0#1;2;100;100;100");

    var band: usize = 0;
    while (band < 64) : (band += 6) {
        try stream.writeAll("#0");
        _ = try stream.splatByte('~', 128);
        try stream.writeAll("$#1");
        var x: usize = 0;
        while (x < 128) : (x += 1) {
            var bits: u8 = 0;
            var dy: usize = 0;
            while (dy < 6 and band + dy < 64) : (dy += 1) {
                if (pixel(bus, x, band + dy)) bits |= @as(u8, 1) << @as(u3, @intCast(dy));
            }
            try stream.writeByte(63 + bits);
        }
        if (band + 6 < 64) try stream.writeByte('-');
    }
    try stream.writeAll("\x1b\\\x1b8");
    return stream.buffered();
}

fn presentSixel(io: std.Io, bus: *const bus_mod.Bus) !void {
    var output: [4096]u8 = undefined;
    try writeAll(io, try encodeSixel(&output, bus));
}

fn writeAll(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.writeStreamingAll(.stdout(), io, bytes);
}

test "sixel encoder emits a complete frame" {
    const bus = bus_mod.Bus{};
    var output: [4096]u8 = undefined;
    const frame = try encodeSixel(&output, &bus);
    try std.testing.expect(std.mem.startsWith(u8, frame, "\x1b7\x1b[2;3H\x1bPq"));
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b\\\x1b8"));
}

test "right arrow emits a complete clockwise quadrature cycle" {
    var ui: Ui = undefined;
    ui.pending_input_len = 0;
    var bus = bus_mod.Bus{};

    try std.testing.expect(ui.processInput(&bus, "\x1b[C"));
    const expected = [_]u32{
        1 << 5,
        0,
        1 << 2,
        (1 << 2) | (1 << 5),
    };
    for (expected) |state| {
        const a = (try bus.read32(bus_mod.gpioa_base + 8)) & (1 << 2);
        const b = (try bus.read32(bus_mod.gpiod_base + 8)) & (1 << 5);
        try std.testing.expectEqual(state, a | b);
    }
}

test "Kitty enhanced arrow press is accepted and release is ignored" {
    var ui: Ui = undefined;
    ui.pending_input_len = 0;
    var bus = bus_mod.Bus{};

    try std.testing.expect(ui.processInput(&bus, "\x1b[1;1:1C"));
    try std.testing.expectEqual(@as(u3, 1), bus.rotary_phase);
    try std.testing.expect(ui.processInput(&bus, "\x1b[1;1:3D"));
    try std.testing.expectEqual(@as(i16, 0), bus.rotary_pending);
}

test "tmux escapes every ESC and direct transport preserves APC" {
    var buffer: [128]u8 = undefined;
    const apc = "\x1b_Gm=0;AAAA\x1b\\";
    try std.testing.expectEqualStrings(apc, try wrapKitty(&buffer, apc, .direct));
    try std.testing.expectEqualStrings("\x1bPtmux;\x1b\x1b_Gm=0;AAAA\x1b\x1b\\\x1b\\", try wrapKitty(&buffer, apc, .tmux));
    const deletion = "\x1b_Ga=d,d=I,i=1,q=2\x1b\\";
    const wrapped = try wrapKitty(&buffer, deletion, .tmux);
    try std.testing.expect(std.mem.indexOf(u8, wrapped, "a=d,d=I,i=1") != null);
}

test "Kitty chunks preserve payload and use one image ID for updates" {
    var payload: [9000]u8 = @splat('A');
    payload[8999] = 'B';
    var command: [4300]u8 = undefined;
    var reconstructed: [9000]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const end = @min(offset + 4096, payload.len);
        const apc = try kittyChunk(&command, payload[offset..end], offset == 0, end < payload.len, 1, false);
        try std.testing.expect(std.mem.startsWith(u8, apc, "\x1b_G"));
        try std.testing.expect(std.mem.endsWith(u8, apc, "\x1b\\"));
        try std.testing.expect(std.mem.indexOf(u8, apc, if (end < payload.len) "m=1;" else "m=0;") != null);
        if (offset == 0) try std.testing.expect(std.mem.indexOf(u8, apc, "i=1,q=2,C=1") != null);
        const start = (std.mem.indexOfScalar(u8, apc, ';') orelse unreachable) + 1;
        @memcpy(reconstructed[offset..end], apc[start .. apc.len - 2]);
        offset = end;
    }
    try std.testing.expectEqualSlices(u8, &payload, &reconstructed);
}

test "terminal detection is conservative and transport can be overridden" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM", "xterm-ghostty");
    try std.testing.expectEqual(Protocol.kitty, try detectProtocol(&env));
    try std.testing.expectEqual(Transport.direct, selectTransport(.auto, &env));
    try env.put("TERM", "tmux-256color");
    try env.put("TMUX", "/tmp/tmux/default,123,0");
    try env.put("GHOSTTY_RESOURCES_DIR", "/ghostty");
    try std.testing.expectEqual(Protocol.kitty, try detectProtocol(&env));
    try std.testing.expectEqual(Transport.tmux, selectTransport(.auto, &env));
    try std.testing.expectEqual(Transport.direct, selectTransport(.direct, &env));
}

test "Space fallback, explicit hold and release, and quit keys" {
    var ui: Ui = undefined;
    ui.pending_input_len = 0;
    ui.io = std.testing.io;
    ui.in_tmux = true;
    ui.button_release_deadline_ns = null;
    var bus = bus_mod.Bus{};
    try std.testing.expect(ui.processInput(&bus, " "));
    try std.testing.expect(bus.button_pressed);
    const deadline = ui.button_release_deadline_ns.?;
    ui.expireButton(&bus, deadline - 1);
    try std.testing.expect(bus.button_pressed);
    ui.expireButton(&bus, deadline);
    try std.testing.expect(!bus.button_pressed);
    try std.testing.expect(ui.processInput(&bus, "\x1b[32;1:1u"));
    try std.testing.expect(ui.button_release_deadline_ns != null);
    try std.testing.expect(ui.processInput(&bus, "\x1b[32;1:3u"));
    try std.testing.expect(!bus.button_pressed);
    ui.in_tmux = false;
    try std.testing.expect(ui.processInput(&bus, "\x1b[32;1:1u"));
    try std.testing.expect(ui.button_release_deadline_ns == null);
    try std.testing.expect(ui.processInput(&bus, "\x1b[32;1:3u"));
    try std.testing.expect(ui.processInput(&bus, "d"));
    ui.expireButton(&bus, std.math.maxInt(i96));
    try std.testing.expect(bus.button_pressed);
    try std.testing.expect(ui.processInput(&bus, "u"));
    try std.testing.expect(!bus.button_pressed);
    for ([_][]const u8{ "q", "\x1b", "\x03", "\x1b[99;5u" }) |key| try std.testing.expect(!ui.processInput(&bus, key));
}

test "native capability reply preserves adjacent user input" {
    var input: [128]u8 = undefined;
    const reply = "d\x1b_Gi=2147483646;OK\x1b\\u";
    @memcpy(input[0..reply.len], reply);
    var len = reply.len;
    try std.testing.expectEqual(true, takeProbeReply(&input, &len).?);
    try std.testing.expectEqualStrings("du", input[0..len]);
}

test "fragmented CSI keys and delayed capability replies are consumed safely" {
    var ui: Ui = undefined;
    ui.pending_input_len = 0;
    var bus = bus_mod.Bus{};
    try std.testing.expect(ui.processInput(&bus, "\x1b["));
    try std.testing.expect(ui.processInput(&bus, "1;1:1C"));
    try std.testing.expectEqual(@as(u3, 1), bus.rotary_phase);
    try std.testing.expect(ui.processInput(&bus, "\x1b_Gi=2147483646;"));
    try std.testing.expect(ui.processInput(&bus, "OK\x1b\\"));
    try std.testing.expectEqual(@as(usize, 0), ui.pending_input_len);
}

test "unknown terminal requires explicit graphics selection" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM", "xterm-256color");
    try std.testing.expectError(error.UnknownGraphicsCapability, detectProtocol(&env));
    try env.put("TERM", "xterm-sixel");
    try std.testing.expectEqual(Protocol.sixel, try detectProtocol(&env));
    try env.put("TERM", "xterm-kitty");
    try std.testing.expectEqual(Protocol.kitty, try detectProtocol(&env));
}

test "unchanged OLED VRAM performs no writes or uploads" {
    var ui: Ui = undefined;
    ui.protocol = .kitty;
    ui.transport = .direct;
    ui.has_presented_frame = true;
    ui.frames_presented = 4;
    ui.bytes_written = 100;
    ui.last_vram = @splat(0);
    const bus = bus_mod.Bus{};
    try ui.present(&bus);
    try std.testing.expectEqual(@as(u64, 4), ui.frames_presented);
    try std.testing.expectEqual(@as(u64, 100), ui.bytes_written);
}

test "left arrow and enhanced explicit button hold controls" {
    var ui: Ui = undefined;
    ui.pending_input_len = 0;
    ui.in_tmux = true;
    var bus = bus_mod.Bus{};
    try std.testing.expect(ui.processInput(&bus, "\x1b[D"));
    try std.testing.expectEqual(@as(i2, -1), bus.rotary_active);
    try std.testing.expect(ui.processInput(&bus, "\x1b[100;1:1u"));
    try std.testing.expect(bus.button_pressed);
    ui.expireButton(&bus, std.math.maxInt(i96));
    try std.testing.expect(bus.button_pressed);
    try std.testing.expect(ui.processInput(&bus, "\x1b[117;1:1u"));
    try std.testing.expect(!bus.button_pressed);
}

test "tmux images use virtual placements while direct images stay physical" {
    var buffer: [256]u8 = undefined;
    const virtual = try kittyChunk(&buffer, "AAAA", true, false, 0x123456, true);
    try std.testing.expect(std.mem.indexOf(u8, virtual, "i=1193046,q=2,C=1,U=1,m=0;") != null);
    const direct = try kittyChunk(&buffer, "AAAA", true, false, 1, false);
    try std.testing.expect(std.mem.indexOf(u8, direct, "U=1") == null);
}

test "placeholder grid encodes image ID and row coordinates with implicit columns" {
    var buffer: [12000]u8 = undefined;
    const grid = try placeholderGrid(&buffer, 0x123456, .{ .cols = 4, .rows = 3 }, false);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b7\x1b[0m\x1b[38;2;18;52;86m\x1b[2;3H\u{10eeee}\u{305}\u{10eeee}\u{305}\x1b[3;3H\u{10eeee}\u{30d}\u{10eeee}\u{30d}\x1b[0m\x1b8\x1b[?2026l", grid);
    const empty = try placeholderGrid(&buffer, 1, .{ .cols = 1, .rows = 1 }, true);
    try std.testing.expect(std.mem.indexOf(u8, empty, "\u{10eeee}") == null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "\x1b[2J") != null);
    const full = try placeholderGrid(&buffer, 1, .{ .cols = 80, .rows = 24 }, false);
    try std.testing.expectEqual(@as(usize, 64 * 16), std.mem.count(u8, full, "\u{10eeee}"));
}
