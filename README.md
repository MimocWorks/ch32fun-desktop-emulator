# CH32fun Desktop Emulator

[日本語版 README](docs/README.ja.md)

Desktop emulator for a CH32fun-based firmware ELF. The project loads a firmware image, emulates the CPU and peripheral bus, and renders the SSD1306-style OLED output in a desktop window using SDL3 and Vulkan.

## Demo

![CH32fun Desktop Emulator demo](docs/emu_demo.gif)

## Features

- Loads a firmware `.elf` image at runtime
- Emulates the CPU, flash, RAM, I2C traffic, button input, and OLED VRAM
- Displays the OLED framebuffer in a resizable desktop window
- Supports headless execution for quick inspection and debugging
- Includes a minimal SDL probe target for environment troubleshooting

## Requirements

- Zig
- SDL3 development libraries
- Vulkan loader / development libraries
- `glslc` for shader compilation
- X11 environment by default when using `zig build run`

## Build

```sh
zig build
```

This builds:

- `zig-out/bin/ch32fun-desktop-emulator`
- `zig-out/bin/sdl-probe`

## Usage

Run the emulator with a firmware ELF:

```sh
zig build run -- --elf /path/to/firmware.elf
```

Useful options:

- `--stats`: print runtime statistics once per second
- `--cpu-slice N`: number of CPU steps per execution slice
- `--target-fps N`: UI presentation target
- `--headless`: run without creating the SDL/Vulkan UI
- `--steps N`: number of instructions to execute in headless mode
- `--dump-oled`: print the OLED framebuffer as ASCII after headless execution

Example:

```sh
zig build run -- --elf /path/to/firmware.elf --stats
```

Headless example:

```sh
zig build run -- --elf /path/to/firmware.elf --headless --steps 200000 --dump-oled
```

## Controls

- `Space`: press the emulated button
- `Esc`: quit
- Window close button: quit

## SDL Environment Probe

If the main window does not appear, test SDL separately:

```sh
zig build probe
```

## Helper Script

[`tools/run-mopeck.sh`](tools/run-mopeck.sh) builds the related Mopeck firmware project and then launches this emulator with:

```sh
tools/run-mopeck.sh
```

The script uses these environment variables when needed:

- `MOPECK_DIR`
- `EMULATOR_DIR`
- `SDL_VIDEODRIVER`

## Project Layout

- `src/`: emulator implementation
- `shaders/`: Vulkan shaders for OLED rendering
- `tools/`: helper scripts

## License

Add a license before publishing on GitHub if you want to allow reuse.
