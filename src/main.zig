const std = @import("std");
const elf = @import("elf_loader.zig");
const cpu_mod = @import("cpu.zig");
const bus_mod = @import("bus.zig");
const ui_mod = @import("ui.zig");

const core_clock_hz: u64 = 48_000_000;

const RuntimeOptions = struct {
    // Roughly 1 ms of emulated work. Larger slices avoid thousands of short
    // sleeps and clock syscalls per second while keeping input responsive.
    cpu_slice_steps: usize = 50_000,
    target_frame_ns: u64 = std.time.ns_per_s / 60,
    enable_stats: bool = false,
    graphics_protocol: ui_mod.Protocol = .auto,
};

const StatsSnapshot = struct {
    cpu_instruction_count: u64,
    ui_frames_presented: u64 = 0,
    ui_texture_uploads: u64 = 0,
    ui_acquire_timeout_count: u64 = 0,
    ui_bytes_written: u64 = 0,
};

const Emulator = struct {
    allocator: std.mem.Allocator,
    bus: bus_mod.Bus = .{},
    cpu: cpu_mod.Cpu,
    ui: ?ui_mod.Ui = null,
    options: RuntimeOptions,
    io: std.Io,

    fn init(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, elf_path: []const u8, enable_ui: bool, options: RuntimeOptions) !Emulator {
        var bus = bus_mod.Bus{ .io = io };
        const elf_bytes = try std.Io.Dir.cwd().readFileAlloc(io, elf_path, allocator, .limited(1 << 20));
        defer allocator.free(elf_bytes);

        const image = try elf.load(elf_bytes, &bus.flash, &bus.ram);
        const cpu = cpu_mod.Cpu.init(image.entry, bus_mod.ram_base + bus_mod.ram_size);
        var ui: ?ui_mod.Ui = null;
        if (enable_ui) {
            ui = try ui_mod.Ui.init(allocator, io, options.graphics_protocol, environ);
        }
        return .{
            .allocator = allocator,
            .bus = bus,
            .cpu = cpu,
            .ui = ui,
            .options = options,
            .io = io,
        };
    }

    fn deinit(self: *Emulator) void {
        if (self.ui) |*ui| ui.deinit();
    }

    fn run(self: *Emulator) !void {
        const frame_interval_ns = self.options.target_frame_ns;
        const clock_start_ns = nowNs(self.io);
        var next_present_ns = clock_start_ns;
        var stats_last_ns = next_present_ns;
        var stats_last_snapshot = self.statsSnapshot();

        if (self.ui) |*ui| {
            _ = ui.pumpEvents(&self.bus);
            try ui.present(&self.bus);
            next_present_ns += frame_interval_ns;
        }

        while (true) {
            if (self.ui) |*ui| {
                if (!ui.pumpEvents(&self.bus)) break;
            }

            var steps: usize = 0;
            while (steps < self.options.cpu_slice_steps) : (steps += 1) {
                self.cpu.step(&self.bus) catch |err| {
                    std.log.err("CPU stopped at pc=0x{x}: {}", .{ self.cpu.pc, err });
                    return err;
                };
            }

            try self.syncRealTime(clock_start_ns);

            const now_ns = nowNs(self.io);
            if (self.ui != null and now_ns >= next_present_ns) {
                if (self.ui) |*ui| try ui.present(&self.bus);
                next_present_ns = now_ns + frame_interval_ns;
            }

            if (self.options.enable_stats and now_ns - stats_last_ns >= std.time.ns_per_s) {
                const snapshot = self.statsSnapshot();
                const elapsed_ns: u64 = @intCast(now_ns - stats_last_ns);
                const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
                const cpu_delta = snapshot.cpu_instruction_count - stats_last_snapshot.cpu_instruction_count;
                const frame_delta = snapshot.ui_frames_presented - stats_last_snapshot.ui_frames_presented;
                const upload_delta = snapshot.ui_texture_uploads - stats_last_snapshot.ui_texture_uploads;
                const acquire_delta = snapshot.ui_acquire_timeout_count - stats_last_snapshot.ui_acquire_timeout_count;
                const bytes_delta = snapshot.ui_bytes_written - stats_last_snapshot.ui_bytes_written;
                std.log.info("stats fps={d:.1} step/s={d:.0} uploads/s={d:.1} output={d:.1} KiB/s acquire_timeout/s={d:.1}", .{
                    @as(f64, @floatFromInt(frame_delta)) / elapsed_s,
                    @as(f64, @floatFromInt(cpu_delta)) / elapsed_s,
                    @as(f64, @floatFromInt(upload_delta)) / elapsed_s,
                    @as(f64, @floatFromInt(bytes_delta)) / elapsed_s / 1024.0,
                    @as(f64, @floatFromInt(acquire_delta)) / elapsed_s,
                });
                stats_last_ns = now_ns;
                stats_last_snapshot = snapshot;
            }
        }
    }

    fn syncRealTime(self: *const Emulator, clock_start_ns: i96) !void {
        const emulated_ns: i96 = @intCast((@as(u128, self.cpu.cycle_count) * std.time.ns_per_s) / core_clock_hz);
        const target_ns = clock_start_ns + emulated_ns;
        const now_ns = nowNs(self.io);
        if (target_ns > now_ns) {
            try std.Io.sleep(self.io, .{ .nanoseconds = target_ns - now_ns }, .awake);
        }
    }

    fn runHeadless(self: *Emulator, max_steps: usize) !void {
        var steps: usize = 0;
        while (steps < max_steps) : (steps += 1) {
            try self.cpu.step(&self.bus);
        }
        var nonzero_vram: usize = 0;
        for (self.bus.oled.vram) |byte| {
            if (byte != 0) nonzero_vram += 1;
        }
        std.log.info("headless steps={d} pc=0x{x} instr={d} i2c_tx={d} oled_packets={d} nonzero_vram={d}", .{
            max_steps,
            self.cpu.pc,
            self.cpu.instruction_count,
            self.bus.i2c_transactions,
            self.bus.oled_packets,
            nonzero_vram,
        });
        std.log.info("i2c start={d} addr={d} data={d} stop={d}", .{
            self.bus.i2c_start_events,
            self.bus.i2c_address_events,
            self.bus.i2c_data_writes,
            self.bus.i2c_stop_events,
        });
    }

    fn dumpOledAscii(self: *const Emulator, writer: anytype) !void {
        var y: usize = 0;
        while (y < 64) : (y += 1) {
            var x: usize = 0;
            while (x < 128) : (x += 1) {
                const index = (y / 8) * 128 + x;
                const mask = @as(u8, 1) << @as(u3, @intCast(y & 7));
                const on = (self.bus.oled.vram[index] & mask) != 0;
                try writer.writeByte(if (on) '#' else '.');
            }
            try writer.writeByte('\n');
        }
    }

    fn statsSnapshot(self: *const Emulator) StatsSnapshot {
        var snapshot = StatsSnapshot{
            .cpu_instruction_count = self.cpu.instruction_count,
        };
        if (self.ui) |*ui| {
            const ui_stats = ui.stats();
            snapshot.ui_frames_presented = ui_stats.frames_presented;
            snapshot.ui_texture_uploads = ui_stats.texture_uploads;
            snapshot.ui_acquire_timeout_count = ui_stats.acquire_timeout_count;
            snapshot.ui_bytes_written = ui_stats.bytes_written;
        }
        return snapshot;
    }
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    var arg_index: usize = 1;

    var elf_path: ?[]const u8 = null;
    var headless = false;
    var headless_steps: usize = 200_000;
    var dump_oled = false;
    var options = RuntimeOptions{};

    while (arg_index < args.len) {
        const arg = args[arg_index];
        arg_index += 1;
        if (std.mem.eql(u8, arg, "--elf")) {
            if (arg_index == args.len) return error.InvalidUsage;
            elf_path = args[arg_index];
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--steps")) {
            if (arg_index == args.len) return error.InvalidUsage;
            const raw = args[arg_index];
            arg_index += 1;
            headless_steps = try std.fmt.parseInt(usize, raw, 10);
        } else if (std.mem.eql(u8, arg, "--dump-oled")) {
            dump_oled = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            options.enable_stats = true;
        } else if (std.mem.eql(u8, arg, "--cpu-slice")) {
            if (arg_index == args.len) return error.InvalidUsage;
            const raw = args[arg_index];
            arg_index += 1;
            options.cpu_slice_steps = try std.fmt.parseInt(usize, raw, 10);
            if (options.cpu_slice_steps == 0) return error.InvalidUsage;
        } else if (std.mem.eql(u8, arg, "--target-fps")) {
            if (arg_index == args.len) return error.InvalidUsage;
            const raw = args[arg_index];
            arg_index += 1;
            const fps = try std.fmt.parseInt(u32, raw, 10);
            if (fps == 0) return error.InvalidUsage;
            options.target_frame_ns = std.time.ns_per_s / fps;
        } else if (std.mem.eql(u8, arg, "--graphics")) {
            if (arg_index == args.len) return error.InvalidUsage;
            const value = args[arg_index];
            arg_index += 1;
            options.graphics_protocol = if (std.mem.eql(u8, value, "auto"))
                .auto
            else if (std.mem.eql(u8, value, "kitty"))
                .kitty
            else if (std.mem.eql(u8, value, "sixel"))
                .sixel
            else
                return error.InvalidUsage;
        } else {
            return error.InvalidUsage;
        }
    }

    const path = elf_path orelse {
        std.log.err("usage: ch32fun-desktop-emulator --elf firmware.elf [--graphics auto|kitty|sixel] [--target-fps N]", .{});
        return error.InvalidUsage;
    };

    var emulator = try Emulator.init(allocator, init.io, init.environ_map, path, !headless, options);
    defer emulator.deinit();
    if (headless) {
        try emulator.runHeadless(headless_steps);
        if (dump_oled) {
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
            try emulator.dumpOledAscii(&stdout_writer.interface);
            try stdout_writer.interface.flush();
        }
    } else {
        try emulator.run();
    }
}
