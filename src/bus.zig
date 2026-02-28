const std = @import("std");

pub const flash_base: u32 = 0x0800_0000;
pub const ram_base: u32 = 0x2000_0000;
pub const gpioa_base: u32 = 0x4001_0800;
pub const gpioc_base: u32 = 0x4001_1000;
pub const gpiod_base: u32 = 0x4001_1400;
pub const i2c1_base: u32 = 0x4000_5400;
pub const rcc_base: u32 = 0x4002_1000;
pub const flash_reg_base: u32 = 0x4002_2000;
pub const systick_base: u32 = 0xE000_F000;
pub const cfg0_pll_trim: u32 = 0x1FFF_F7D4;

pub const flash_size = 16 * 1024;
pub const ram_size = 2 * 1024;

const systick_ctlr_ste: u32 = 1 << 0;
const systick_ctlr_stclk: u32 = 1 << 2;
const i2c_star1_txe: u16 = 0x0080;
const i2c_star2_busy: u16 = 0x0002;

const OledState = struct {
    vram: [128 * 64 / 8]u8 = [_]u8{0} ** (128 * 64 / 8),
    column_start: u8 = 0,
    column_end: u8 = 127,
    page_start: u8 = 0,
    page_end: u8 = 7,
    current_column: u8 = 0,
    current_page: u8 = 0,
    pending_command: enum { none, set_column_start, set_column_end, set_page_start, set_page_end } = .none,
    dirty: bool = true,

    pub fn processPacket(self: *OledState, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const control = bytes[0];
        if (control == 0x00) {
            for (bytes[1..]) |byte| self.processCommand(byte);
        } else if (control == 0x40) {
            for (bytes[1..]) |byte| self.processData(byte);
        }
    }

    fn processCommand(self: *OledState, byte: u8) void {
        switch (self.pending_command) {
            .set_column_start => {
                self.column_start = byte;
                self.current_column = byte;
                self.pending_command = .set_column_end;
                return;
            },
            .set_column_end => {
                self.column_end = byte;
                self.pending_command = .none;
                return;
            },
            .set_page_start => {
                self.page_start = byte;
                self.current_page = byte;
                self.pending_command = .set_page_end;
                return;
            },
            .set_page_end => {
                self.page_end = byte;
                self.pending_command = .none;
                return;
            },
            .none => {},
        }

        switch (byte) {
            0x21 => self.pending_command = .set_column_start,
            0x22 => self.pending_command = .set_page_start,
            else => {},
        }
    }

    fn processData(self: *OledState, byte: u8) void {
        if (self.current_column > self.column_end or self.current_page > self.page_end) return;
        const index = @as(usize, self.current_page) * 128 + self.current_column;
        if (index < self.vram.len) {
            self.vram[index] = byte;
            self.dirty = true;
        }
        self.current_column +%= 1;
        if (self.current_column > self.column_end) {
            self.current_column = self.column_start;
            if (self.current_page < self.page_end) self.current_page +%= 1;
        }
    }
};

const GpioRegs = struct {
    cfglr: u32 = 0,
    cfghr: u32 = 0,
    indr: u32 = 0,
    outdr: u32 = 0,
    bshr: u32 = 0,
    bcr: u32 = 0,
    lckr: u32 = 0,
};

const RccRegs = struct {
    ctlr: u32 = 0x0200_0000,
    cfgr0: u32 = 0,
    intr: u32 = 0,
    apb2prstr: u32 = 0,
    apb1prstr: u32 = 0,
    ahbpcenr: u32 = 0,
    apb2pcenr: u32 = 0,
    apb1pcenr: u32 = 0,
    reserved0: u32 = 0,
    rstsckr: u32 = 0,
};

const FlashRegs = struct {
    actlr: u32 = 0,
};

const SysTickRegs = struct {
    ctlr: u32 = 0,
    sr: u32 = 0,
    cnt: u32 = 0,
    cmp: u32 = 0,
    start_ns: u64 = 0,

    fn now(self: *const SysTickRegs) u32 {
        if ((self.ctlr & systick_ctlr_ste) == 0 or (self.ctlr & systick_ctlr_stclk) == 0) return self.cnt;
        const elapsed_ns = std.time.nanoTimestamp() - @as(i128, @intCast(self.start_ns));
        const ticks = (@as(u128, @intCast(elapsed_ns)) * 48_000_000) / std.time.ns_per_s;
        return self.cnt +% @as(u32, @truncate(ticks));
    }
};

const I2cPhase = enum {
    idle,
    start_sent,
    addressed,
};

const I2cRegs = struct {
    ctlr1: u16 = 0,
    ctlr2: u16 = 0,
    oaddr1: u16 = 0,
    oaddr2: u16 = 0,
    datar: u16 = 0,
    star1: u16 = 0,
    star2: u16 = 0,
    ckcfgr: u16 = 0,
    phase: I2cPhase = .idle,
    current_addr: u8 = 0,
    packet_len: usize = 0,
    packet: [64]u8 = [_]u8{0} ** 64,
};

pub const Bus = struct {
    flash: [flash_size]u8 = [_]u8{0} ** flash_size,
    ram: [ram_size]u8 = [_]u8{0} ** ram_size,
    rcc: RccRegs = .{},
    flash_regs: FlashRegs = .{},
    gpio_a: GpioRegs = .{},
    gpio_c: GpioRegs = .{},
    gpio_d: GpioRegs = .{ .indr = 1 << 1 },
    systick: SysTickRegs = .{},
    i2c: I2cRegs = .{},
    oled: OledState = .{},
    button_pressed: bool = false,
    terminated: bool = false,
    i2c_transactions: usize = 0,
    oled_packets: usize = 0,
    i2c_start_events: usize = 0,
    i2c_address_events: usize = 0,
    i2c_data_writes: usize = 0,
    i2c_stop_events: usize = 0,

    pub fn setButtonPressed(self: *Bus, pressed: bool) void {
        self.button_pressed = pressed;
        if (pressed) {
            self.gpio_d.indr &= ~@as(u32, 1 << 1);
        } else {
            self.gpio_d.indr |= @as(u32, 1 << 1);
        }
    }

    pub fn fetch16(self: *Bus, address: u32) !u16 {
        return @as(u16, @intCast(try self.readInt(u16, address)));
    }

    pub fn fetch32(self: *Bus, address: u32) !u32 {
        return @as(u32, @intCast(try self.readInt(u32, address)));
    }

    pub fn read8(self: *Bus, address: u32) !u8 {
        return @as(u8, @intCast(try self.readInt(u8, address)));
    }

    pub fn read16(self: *Bus, address: u32) !u16 {
        return @as(u16, @intCast(try self.readInt(u16, address)));
    }

    pub fn read32(self: *Bus, address: u32) !u32 {
        return @as(u32, @intCast(try self.readInt(u32, address)));
    }

    pub fn write8(self: *Bus, address: u32, value: u8) !void {
        try self.writeInt(u8, address, value);
    }

    pub fn write16(self: *Bus, address: u32, value: u16) !void {
        try self.writeInt(u16, address, value);
    }

    pub fn write32(self: *Bus, address: u32, value: u32) !void {
        try self.writeInt(u32, address, value);
    }

    fn readInt(self: *Bus, comptime T: type, address: u32) !T {
        if (address >= flash_base and address + @sizeOf(T) <= flash_base + flash_size) {
            const offset = address - flash_base;
            return readNativeInt(T, self.flash[offset .. offset + @sizeOf(T)]);
        }
        if (address >= ram_base and address + @sizeOf(T) <= ram_base + ram_size) {
            const offset = address - ram_base;
            return readNativeInt(T, self.ram[offset .. offset + @sizeOf(T)]);
        }
        if (address == cfg0_pll_trim and T == u8) return 0xFF;
        return self.readMmio(T, address);
    }

    fn writeInt(self: *Bus, comptime T: type, address: u32, value: T) !void {
        if (address >= ram_base and address + @sizeOf(T) <= ram_base + ram_size) {
            const offset = address - ram_base;
            writeNativeInt(T, self.ram[offset .. offset + @sizeOf(T)], value);
            return;
        }
        if (address >= flash_base and address + @sizeOf(T) <= flash_base + flash_size) {
            return;
        }
        try self.writeMmio(T, address, value);
    }

    fn readMmio(self: *Bus, comptime T: type, address: u32) !T {
        if (address >= rcc_base and address < rcc_base + 40) {
            const offset = address - rcc_base;
            if (offset == 0) return castRead(T, self.rcc.ctlr | (@as(u32, 1) << 25));
            if (offset == 4) {
                const sw = self.rcc.cfgr0 & 0x3;
                return castRead(T, (self.rcc.cfgr0 & ~@as(u32, 0xC)) | (sw << 2));
            }
            return self.readStruct(T, &self.rcc, offset);
        }
        if (address >= flash_reg_base and address < flash_reg_base + 44) return self.readStruct(T, &self.flash_regs, address - flash_reg_base);
        if (address >= gpioa_base and address < gpioa_base + 28) return self.readStruct(T, &self.gpio_a, address - gpioa_base);
        if (address >= gpioc_base and address < gpioc_base + 28) return self.readStruct(T, &self.gpio_c, address - gpioc_base);
        if (address >= gpiod_base and address < gpiod_base + 28) return self.readStruct(T, &self.gpio_d, address - gpiod_base);

        if (address >= systick_base and address < systick_base + 24) {
            const offset = address - systick_base;
            return switch (offset) {
                0 => castRead(T, self.systick.ctlr),
                4 => castRead(T, self.systick.sr),
                8 => castRead(T, self.systick.now()),
                16 => castRead(T, self.systick.cmp),
                else => castRead(T, 0),
            };
        }

        if (address >= i2c1_base and address < i2c1_base + 32) {
            const offset = address - i2c1_base;
            return switch (offset) {
                0 => castRead(T, self.i2c.ctlr1),
                4 => castRead(T, self.i2c.ctlr2),
                8 => castRead(T, self.i2c.oaddr1),
                12 => castRead(T, self.i2c.oaddr2),
                16 => castRead(T, self.i2c.datar),
                20 => castRead(T, self.i2c.star1),
                24 => castRead(T, self.i2c.star2),
                28 => castRead(T, self.i2c.ckcfgr),
                else => castRead(T, 0),
            };
        }

        return castRead(T, 0);
    }

    fn writeMmio(self: *Bus, comptime T: type, address: u32, value: T) !void {
        if (address >= rcc_base and address < rcc_base + 40) {
            const offset = address - rcc_base;
            const v = @as(u32, @intCast(value));
            switch (offset) {
                0 => {
                    self.rcc.ctlr = v;
                    if ((v & (@as(u32, 1) << 24)) != 0) {
                        self.rcc.ctlr |= @as(u32, 1) << 25;
                    }
                },
                4 => {
                    self.rcc.cfgr0 = v;
                    const sw = v & 0x3;
                    self.rcc.cfgr0 = (self.rcc.cfgr0 & ~@as(u32, 0xC)) | (sw << 2);
                },
                else => self.writeStruct(T, &self.rcc, offset, value),
            }
            return;
        }
        if (address >= flash_reg_base and address < flash_reg_base + 44) {
            self.writeStruct(T, &self.flash_regs, address - flash_reg_base, value);
            return;
        }
        if (address >= gpioa_base and address < gpioa_base + 28) {
            self.writeGpio(T, &self.gpio_a, address - gpioa_base, value);
            return;
        }
        if (address >= gpioc_base and address < gpioc_base + 28) {
            self.writeGpio(T, &self.gpio_c, address - gpioc_base, value);
            return;
        }
        if (address >= gpiod_base and address < gpiod_base + 28) {
            self.writeGpio(T, &self.gpio_d, address - gpiod_base, value);
            return;
        }
        if (address >= systick_base and address < systick_base + 24) {
            const offset = address - systick_base;
            const v = @as(u32, @intCast(value));
            switch (offset) {
                0 => self.systick.ctlr = v,
                4 => self.systick.sr = v,
                8 => {
                    self.systick.cnt = v;
                    self.systick.start_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
                },
                16 => self.systick.cmp = v,
                else => {},
            }
            return;
        }
        if (address >= i2c1_base and address < i2c1_base + 32) {
            const offset = address - i2c1_base;
            const v = @as(u16, @intCast(value));
            switch (offset) {
                0 => {
                    self.i2c.ctlr1 = v;
                    if ((v & 0x0200) != 0) {
                        self.i2c_stop_events += 1;
                        if (self.i2c.current_addr == 0x3c and self.i2c.packet_len > 0) {
                            self.oled.processPacket(self.i2c.packet[0..self.i2c.packet_len]);
                            self.oled_packets += 1;
                        }
                        self.i2c_transactions += 1;
                        self.i2c.phase = .idle;
                        self.i2c.packet_len = 0;
                        self.i2c.star1 = i2c_star1_txe;
                        self.i2c.star2 = 0;
                        self.i2c.ctlr1 &= ~@as(u16, 0x0300);
                    } else if ((v & 0x0100) != 0) {
                        self.i2c_start_events += 1;
                        self.i2c.phase = .start_sent;
                        self.i2c.packet_len = 0;
                        self.i2c.star1 = 0x0001;
                        self.i2c.star2 = 0x0003;
                    }
                },
                4 => self.i2c.ctlr2 = v,
                16 => {
                    self.i2c.datar = v;
                    switch (self.i2c.phase) {
                        .start_sent => {
                            self.i2c_address_events += 1;
                            self.i2c.current_addr = @as(u8, @truncate(v >> 1));
                            self.i2c.phase = .addressed;
                            self.i2c.ctlr1 &= ~@as(u16, 0x0100);
                            self.i2c.star1 = 0x0082;
                            self.i2c.star2 = 0x0007;
                        },
                        .addressed => {
                            self.i2c_data_writes += 1;
                            if (self.i2c.packet_len < self.i2c.packet.len) {
                                self.i2c.packet[self.i2c.packet_len] = @as(u8, @truncate(v));
                                self.i2c.packet_len += 1;
                            }
                            self.i2c.star1 = 0x0084;
                            self.i2c.star2 = 0x0007;
                        },
                        .idle => {},
                    }
                },
                28 => self.i2c.ckcfgr = v,
                else => {},
            }
            return;
        }
    }

    fn readStruct(self: *Bus, comptime T: type, ptr: anytype, offset: u32) T {
        _ = self;
        const bytes = std.mem.asBytes(ptr);
        return readNativeInt(T, bytes[offset .. offset + @sizeOf(T)]);
    }

    fn writeStruct(self: *Bus, comptime T: type, ptr: anytype, offset: u32, value: T) void {
        _ = self;
        const bytes = std.mem.asBytes(ptr);
        writeNativeInt(T, bytes[offset .. offset + @sizeOf(T)], value);
    }

    fn writeGpio(self: *Bus, comptime T: type, ptr: *GpioRegs, offset: u32, value: T) void {
        if (offset == 16 and T == u32) {
            const v = @as(u32, value);
            const set_mask = v & 0xFFFF;
            const clear_mask = v >> 16;
            ptr.outdr |= set_mask;
            ptr.outdr &= ~clear_mask;
            if (ptr == &self.gpio_d) {
                const preserved = if (self.button_pressed) @as(u32, 0) else @as(u32, 1 << 1);
                ptr.indr = (ptr.outdr & ~@as(u32, 1 << 1)) | preserved;
            } else {
                ptr.indr = ptr.outdr;
            }
            ptr.bshr = v;
            return;
        }
        self.writeStruct(T, ptr, offset, value);
    }

    pub fn sendI2cPacket(self: *Bus, packet: []const u8) void {
        self.oled.processPacket(packet);
        self.i2c_transactions += 1;
        self.oled_packets += 1;
        self.i2c.star1 = 0x0084;
        self.i2c.star2 = 0x0007;
    }
};

fn castRead(comptime T: type, value: anytype) T {
    return @as(T, @intCast(value));
}

fn readNativeInt(comptime T: type, bytes: []const u8) T {
    var acc: u64 = 0;
    for (bytes[0..@sizeOf(T)], 0..) |byte, index| {
        acc |= @as(u64, byte) << @as(u6, @intCast(index * 8));
    }
    return @as(T, @intCast(acc));
}

fn writeNativeInt(comptime T: type, bytes: []u8, value: T) void {
    const src = std.mem.asBytes(&value);
    @memcpy(bytes[0..@sizeOf(T)], src);
}
