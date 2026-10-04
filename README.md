# CH32fun Desktop Emulator

[日本語版 README](docs/README.ja.md)

Terminal emulator for a CH32fun-based firmware ELF. It renders the SSD1306-style OLED at its full 128x64 resolution using the Kitty graphics protocol or Sixel.

## Demo

![CH32fun Desktop Emulator demo](docs/emu_demo.gif)

## Features

- Loads a firmware `.elf` image at runtime
- Emulates the CPU, flash, RAM, I2C traffic, button input, and OLED VRAM
- Synchronizes the emulated QingKe CPU to 48 MHz and I2C1 to its configured 1 MHz bus rate
- Displays the full-resolution OLED framebuffer using Kitty or Sixel terminal graphics
- Uses crisp nearest-neighbor scaling, white pixels, and top/left display margins
- Compresses Kitty frames with zlib and sends only changed VRAM to reduce terminal load
- Supports headless execution for quick inspection and debugging
- Uses only the Zig standard library

## Requirements

- Zig 0.17
- A terminal with Kitty graphics or Sixel support

## Build

```sh
zig build
```

Run the emulator tests with `zig build test`.

This builds:

- `zig-out/bin/ch32fun-desktop-emulator`

## Install the `chemu` command

```sh
scripts/install.sh
```

This installs `chemu` and a ReleaseFast-optimized emulator executable to `~/.local/bin`. Set
`PREFIX` or `BINDIR` to use another location.

From a `ch32fun_zig` project directory, build and run its firmware with:

```sh
chemu
```

The command runs `zig build`, detects the RISC-V ELF in `zig-out/bin`, and
starts the emulator with Kitty graphics at 60 FPS by default. Useful launcher options include:

- `--no-build`: run an existing artifact without rebuilding
- `--firmware PATH`: select an ELF explicitly when the project produces more than one

Emulator options can follow the launcher options:

```sh
chemu --graphics sixel --target-fps 30
```

## Usage

Run the emulator with a firmware ELF:

```sh
zig build run -- --elf /path/to/firmware.elf
```

Useful options:

- `--stats`: print actual FPS, instruction rate, terminal output rate, and other statistics once per second
- `--cpu-slice N`: number of CPU steps per execution slice
- `--target-fps N`: UI presentation target
- `--graphics auto|kitty|sixel`: select the terminal graphics protocol
- `--headless`: run without terminal graphics
- `--steps N`: number of instructions to execute in headless mode
- `--dump-oled`: print the OLED framebuffer as ASCII after headless execution

Example:

```sh
zig build run -- --elf /path/to/firmware.elf --stats
```

The defaults are tuned for efficiency. Lowering `--cpu-slice` can reduce input
latency, but increases CPU usage by performing more sleeps and clock queries.

Headless example:

```sh
zig build run -- --elf /path/to/firmware.elf --headless --steps 200000 --dump-oled
```

## Controls

- `Left` / `Right`: rotate the emulated quadrature encoder one detent counterclockwise/clockwise (phase A: PA2, phase B: PD5)
- `Space`: press/release the emulated button (true key-up on Kitty keyboard capable terminals; a 600 ms pulse otherwise, sufficient for a 500 ms long-press threshold)
- `d`: hold the tact switch down
- `u`: release the tact switch
- `Esc`, `q`, or `Ctrl-C`: quit

Kitty is selected automatically when `KITTY_WINDOW_ID` or a Kitty `TERM` is detected. Other terminals default to Sixel. Override detection when needed:

```sh
zig build run -- --elf firmware.elf --graphics kitty --target-fps 60
zig build run -- --elf firmware.elf --graphics sixel --target-fps 30
```

## Helper Script

[`tools/run-mopeck.sh`](tools/run-mopeck.sh) builds the related Mopeck firmware project and then launches this emulator with:

```sh
tools/run-mopeck.sh
```

The script uses these environment variables when needed:

- `MOPECK_DIR`
- `EMULATOR_DIR`

## Project Layout

- `src/`: emulator implementation
- `tools/`: helper scripts

## License

Add a license before publishing on GitHub if you want to allow reuse.
