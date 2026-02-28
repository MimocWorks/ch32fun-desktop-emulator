const std = @import("std");
const elf = @import("elf_loader.zig");
const cpu_mod = @import("cpu.zig");
const bus_mod = @import("bus.zig");
const ui_mod = @import("ui.zig");

const RuntimeOptions = struct {
    cpu_slice_steps: usize = 1_000,
    target_frame_ns: u64 = std.time.ns_per_s / 60,
    enable_stats: bool = false,
};

const StatsSnapshot = struct {
    cpu_instruction_count: u64,
    ui_frames_presented: u64 = 0,
    ui_texture_uploads: u64 = 0,
    ui_acquire_timeout_count: u64 = 0,
};

const Emulator = struct {
    allocator: std.mem.Allocator,
    bus: bus_mod.Bus = .{},
    cpu: cpu_mod.Cpu,
    ui: ?ui_mod.Ui = null,
    options: RuntimeOptions,

    fn init(allocator: std.mem.Allocator, elf_path: []const u8, enable_ui: bool, options: RuntimeOptions) !Emulator {
        var bus = bus_mod.Bus{};
        const elf_bytes = try std.fs.cwd().readFileAlloc(allocator, elf_path, 1 << 20);
        defer allocator.free(elf_bytes);

        const image = try elf.load(elf_bytes, &bus.flash, &bus.ram);
        const cpu = cpu_mod.Cpu.init(image.entry, bus_mod.ram_base + bus_mod.ram_size);
        var ui: ?ui_mod.Ui = null;
        if (enable_ui) {
            ui = try ui_mod.Ui.init(allocator);
        }
        return .{
            .allocator = allocator,
            .bus = bus,
            .cpu = cpu,
            .ui = ui,
            .options = options,
        };
    }

    fn deinit(self: *Emulator) void {
        if (self.ui) |*ui| ui.deinit();
    }

    fn run(self: *Emulator) !void {
        const frame_interval_ns = self.options.target_frame_ns;
        var next_present_ns = std.time.nanoTimestamp();
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

            const now_ns = std.time.nanoTimestamp();
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
                std.log.info("stats fps={d:.1} step/s={d:.0} uploads/s={d:.1} acquire_timeout/s={d:.1}", .{
                    @as(f64, @floatFromInt(frame_delta)) / elapsed_s,
                    @as(f64, @floatFromInt(cpu_delta)) / elapsed_s,
                    @as(f64, @floatFromInt(upload_delta)) / elapsed_s,
                    @as(f64, @floatFromInt(acquire_delta)) / elapsed_s,
                });
                stats_last_ns = now_ns;
                stats_last_snapshot = snapshot;
            }
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
        }
        return snapshot;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    var elf_path: ?[]const u8 = null;
    var headless = false;
    var headless_steps: usize = 200_000;
    var dump_oled = false;
    var options = RuntimeOptions{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--elf")) {
            elf_path = args.next() orelse return error.InvalidUsage;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--steps")) {
            const raw = args.next() orelse return error.InvalidUsage;
            headless_steps = try std.fmt.parseInt(usize, raw, 10);
        } else if (std.mem.eql(u8, arg, "--dump-oled")) {
            dump_oled = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            options.enable_stats = true;
        } else if (std.mem.eql(u8, arg, "--cpu-slice")) {
            const raw = args.next() orelse return error.InvalidUsage;
            options.cpu_slice_steps = try std.fmt.parseInt(usize, raw, 10);
            if (options.cpu_slice_steps == 0) return error.InvalidUsage;
        } else if (std.mem.eql(u8, arg, "--target-fps")) {
            const raw = args.next() orelse return error.InvalidUsage;
            const fps = try std.fmt.parseInt(u32, raw, 10);
            if (fps == 0) return error.InvalidUsage;
            options.target_frame_ns = std.time.ns_per_s / fps;
        } else {
            return error.InvalidUsage;
        }
    }

    const path = elf_path orelse {
        std.log.err("usage: ch32fun-desktop-emulator --elf /path/to/mopping_z.elf [--stats] [--cpu-slice N] [--target-fps N]", .{});
        return error.InvalidUsage;
    };

    var emulator = try Emulator.init(allocator, path, !headless, options);
    defer emulator.deinit();
    if (headless) {
        try emulator.runHeadless(headless_steps);
        if (dump_oled) {
            try emulator.dumpOledAscii(std.fs.File.stdout().deprecatedWriter());
        }
    } else {
        try emulator.run();
    }
}
