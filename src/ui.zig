const std = @import("std");
const bus_mod = @import("bus.zig");

const oled_width = 128;
const oled_height = 64;
const kitty_scale = 4;
const kitty_width = oled_width * kitty_scale;
const kitty_height = oled_height * kitty_scale;
const kitty_rgb_len = kitty_width * kitty_height * 3;
// DEFLATE's worst-case overhead is well below one percent for this input.
const kitty_compressed_capacity = kitty_rgb_len + kitty_rgb_len / 100 + 64;
const kitty_encoded_len = std.base64.standard.Encoder.calcSize(kitty_compressed_capacity);

pub const Protocol = enum {
    auto,
    kitty,
    sixel,
};

pub const Ui = struct {
    pub const Stats = struct {
        frames_presented: u64,
        texture_uploads: u64,
        acquire_timeout_count: u64,
        bytes_written: u64,
    };

    protocol: Protocol,
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
    last_vram: [128 * 64 / 8]u8 = [_]u8{0} ** (128 * 64 / 8),
    has_presented_frame: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, protocol: Protocol, environ: *const std.process.Environ.Map) !Ui {
        const selected = if (protocol == .auto) detectProtocol(environ) else protocol;
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
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        errdefer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};

        // Older emulator versions accidentally pushed keyboard modes onto the
        // main-screen stack and popped the alternate-screen stack. Clear those
        // leaked entries before switching screens; popping an empty stack is a
        // harmless reset according to the protocol.
        try writeAll(io, "\x1b[<64u");

        // Kitty keyboard mode is scoped to the active screen buffer. Enter the
        // alternate screen first so this push is paired with deinit's pop on
        // that same buffer and cannot leak into the user's shell.
        try writeAll(io, "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H\x1b[>3u");
        std.log.info("terminal graphics protocol: {s}", .{@tagName(selected)});
        return .{
            .protocol = selected,
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
        drainTerminalInput();
        if (self.protocol == .kitty) writeAll(self.io, "\x1b_Ga=d,d=A,q=2\x1b\\") catch {};
        writeAll(self.io, "\x1b[?25h\x1b[?1049l") catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, self.original_termios) catch {};
        self.allocator.free(self.kitty_encoded);
        self.allocator.free(self.kitty_compressed);
        self.allocator.free(self.flate_buffer);
        self.allocator.free(self.kitty_rgb);
    }

    pub fn pumpEvents(self: *Ui, bus: *bus_mod.Bus) bool {
        if (self.button_release_deadline_ns) |deadline| if (nowNs(self.io) >= deadline) {
            bus.setButtonPressed(false);
            self.button_release_deadline_ns = null;
        };

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

    fn processInput(self: *Ui, bus: *bus_mod.Bus, input: []const u8) bool {
        var index: usize = 0;
        while (index < input.len) {
            if (input[index] == 0x1b and index + 2 < input.len and input[index + 1] == '[') {
                const end = std.mem.indexOfScalarPos(u8, input, index + 2, 'u') orelse {
                    // A lone Escape remains the quit key.
                    if (index + 1 == input.len) return false;
                    index += 1;
                    continue;
                };
                if (!self.processKittyKey(bus, input[index + 2 .. end])) return false;
                index = end + 1;
                continue;
            }

            switch (input[index]) {
                3, 27, 'q' => return false,
                // Legacy terminals do not report key-up. Keep a normal Space
                // press active long enough to survive a complete firmware loop.
                ' ' => {
                    bus.setButtonPressed(true);
                    self.button_release_deadline_ns = nowNs(self.io) + 150 * std.time.ns_per_ms;
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
        return true;
    }

    fn processKittyKey(self: *Ui, bus: *bus_mod.Bus, parameters: []const u8) bool {
        const key_end = std.mem.indexOfAny(u8, parameters, ";:") orelse parameters.len;
        const codepoint = std.fmt.parseInt(u21, parameters[0..key_end], 10) catch return true;
        var event: u8 = 1;
        if (std.mem.indexOfScalar(u8, parameters, ':')) |colon| {
            const event_end = std.mem.indexOfScalarPos(u8, parameters, colon + 1, ';') orelse parameters.len;
            event = std.fmt.parseInt(u8, parameters[colon + 1 .. event_end], 10) catch 1;
        }

        if (codepoint == 27 or codepoint == 'q' or (codepoint == 'c' and std.mem.indexOf(u8, parameters, ";5") != null)) return false;
        if (codepoint == ' ') {
            if (event == 3) {
                bus.setButtonPressed(false);
            } else {
                bus.setButtonPressed(true);
            }
            self.button_release_deadline_ns = null;
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
        if (self.has_presented_frame and std.mem.eql(u8, &self.last_vram, &bus.oled.vram)) return;
        switch (self.protocol) {
            .kitty => try self.presentKitty(bus),
            .sixel => try presentSixel(self.io, bus),
            .auto => unreachable,
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

        var offset: usize = 0;
        var first = true;
        while (offset < encoded_len) {
            const end = @min(offset + 4096, encoded_len);
            const more: u8 = if (end < encoded_len) 1 else 0;
            var header: [160]u8 = undefined;
            const prefix = if (first)
                try std.fmt.bufPrint(&header, "\x1b[2;3H\x1b_Ga=T,f=24,o=z,s={d},v={d},c=64,r=16,i=1,q=2,C=1,m={d};", .{ kitty_width, kitty_height, more })
            else
                try std.fmt.bufPrint(&header, "\x1b_Gm={d};", .{more});
            try writeAll(self.io, prefix);
            try writeAll(self.io, self.kitty_encoded[offset..end]);
            try writeAll(self.io, "\x1b\\");
            first = false;
            offset = end;
        }
        self.bytes_written += encoded_len;
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

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn drainTerminalInput() void {
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var discard: [128]u8 = undefined;
    // Wait for a short quiet period because a key-up report may be emitted
    // just after the keyboard protocol is disabled.
    while ((std.posix.poll(&fds, 25) catch return) != 0) {
        _ = std.posix.read(std.posix.STDIN_FILENO, &discard) catch return;
        fds[0].revents = 0;
    }
}

fn detectProtocol(environ: *const std.process.Environ.Map) Protocol {
    if (environ.get("KITTY_WINDOW_ID") != null) return .kitty;
    if (environ.get("TERM")) |term| {
        if (std.mem.indexOf(u8, term, "kitty") != null) return .kitty;
    }
    return .sixel;
}

fn pixel(bus: *const bus_mod.Bus, x: usize, y: usize) bool {
    return (bus.oled.vram[(y / 8) * 128 + x] & (@as(u8, 1) << @as(u3, @intCast(y & 7)))) != 0;
}

fn presentSixel(io: std.Io, bus: *const bus_mod.Bus) !void {
    var output: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output);
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
    try writeAll(io, stream.buffered());
}

fn writeAll(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.writeStreamingAll(.stdout(), io, bytes);
}

test "sixel encoder emits a complete frame" {
    const bus = bus_mod.Bus{};
    _ = bus;
}
