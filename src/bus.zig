const std = @import("std");

pub const flash_base: u32 = 0x0800_0000;
pub const ram_base: u32 = 0x2000_0000;
pub const gpioa_base: u32 = 0x4001_0800;
pub const gpioc_base: u32 = 0x4001_1000;
pub const gpiod_base: u32 = 0x4001_1400;
pub const afio_base: u32 = 0x4001_0000;
pub const exti_base: u32 = 0x4001_0400;
pub const i2c1_base: u32 = 0x4000_5400;
pub const rcc_base: u32 = 0x4002_1000;
pub const flash_reg_base: u32 = 0x4002_2000;
pub const systick_base: u32 = 0xE000_F000;
pub const pfic_base: u32 = 0xE000_E000;
pub const cfg0_pll_trim: u32 = 0x1FFF_F7D4;

pub const flash_size = 16 * 1024;
pub const ram_size = 2 * 1024;

const systick_ctlr_ste: u32 = 1 << 0;
const systick_ctlr_stclk: u32 = 1 << 2;
const i2c_star1_txe: u16 = 0x0080;
const i2c_star2_busy: u16 = 0x0002;
// ch32fun_zig configures I2C1 for 1 MHz. One byte including ACK occupies
// nine bus clocks, or 432 CPU clocks at the CH32V003's 48 MHz core clock.
const i2c_byte_cycles: u64 = 9 * 48;

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

const AfioRegs = struct {
    reserved0: u32 = 0,
    pcfr1: u32 = 0,
    exticr: u32 = 0,
};

const ExtiRegs = struct {
    intenr: u32 = 0,
    evenr: u32 = 0,
    rtenr: u32 = 0,
    ftenr: u32 = 0,
    swievr: u32 = 0,
    intfr: u32 = 0,
};

const SysTickRegs = struct {
    ctlr: u32 = 0,
    sr: u32 = 0,
    cnt: u32 = 0,
    cmp: u32 = 0,
    start_ns: u64 = 0,

    fn now(self: *const SysTickRegs, io: ?std.Io) u32 {
        if ((self.ctlr & systick_ctlr_ste) == 0 or (self.ctlr & systick_ctlr_stclk) == 0) return self.cnt;
        const elapsed_ns = nowNs(io) - @as(i96, @intCast(self.start_ns));
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
    ready_cycle: u64 = 0,
    ready_star1: u16 = 0,
};

pub const Bus = struct {
    const rotary_a_mask: u32 = 1 << 2;
    const rotary_b_mask: u32 = 1 << 5;

    io: ?std.Io = null,
    cpu_cycles: u64 = 0,
    // MMIO devices can request that the CPU advance directly to the cycle at
    // which a polled condition changes. This avoids interpreting thousands of
    // iterations of a firmware busy-wait without changing device timing.
    stall_until_cycle: ?u64 = null,
    flash: [flash_size]u8 = [_]u8{0} ** flash_size,
    ram: [ram_size]u8 = [_]u8{0} ** ram_size,
    rcc: RccRegs = .{},
    flash_regs: FlashRegs = .{},
    afio: AfioRegs = .{},
    exti: ExtiRegs = .{},
    pfic_enabled: u64 = 0,
    gpio_a: GpioRegs = .{ .indr = rotary_a_mask },
    gpio_c: GpioRegs = .{},
    gpio_d: GpioRegs = .{ .indr = (1 << 1) | rotary_b_mask },
    systick: SysTickRegs = .{},
    i2c: I2cRegs = .{},
    oled: OledState = .{},
    button_pressed: bool = false,
    rotary_pending: i16 = 0,
    rotary_phase: u3 = 0,
    rotary_active: i2 = 0,
    rotary_ports_read: u2 = 0,
    terminated: bool = false,
    i2c_transactions: usize = 0,
    oled_packets: usize = 0,
    i2c_start_events: usize = 0,
    i2c_address_events: usize = 0,
    i2c_data_writes: usize = 0,
    i2c_stop_events: usize = 0,

    pub fn setButtonPressed(self: *Bus, pressed: bool) void {
        const was_pressed = self.button_pressed;
        self.button_pressed = pressed;
        if (pressed) {
            self.gpio_d.indr &= ~@as(u32, 1 << 1);
        } else {
            self.gpio_d.indr |= @as(u32, 1 << 1);
        }
        if (pressed != was_pressed) {
            const bit: u32 = 1 << 1;
            const rising = !pressed;
            const trigger = if (rising) self.exti.rtenr else self.exti.ftenr;
            // EXTICR value 3 routes line 1 to port D.
            if (((self.afio.exticr >> 2) & 0x3) == 3 and (trigger & bit) != 0) self.exti.intfr |= bit;
        }
    }

    pub fn extiInterruptPending(self: *const Bus) bool {
        const exti_irq: u6 = 20;
        return (self.exti.intfr & self.exti.intenr & 0xff) != 0 and (self.pfic_enabled & (@as(u64, 1) << exti_irq)) != 0;
    }

    pub fn setRotaryState(self: *Bus, a: bool, b: bool) void {
        if (a) {
            self.gpio_a.indr |= rotary_a_mask;
        } else {
            self.gpio_a.indr &= ~rotary_a_mask;
        }
        if (b) {
            self.gpio_d.indr |= rotary_b_mask;
        } else {
            self.gpio_d.indr &= ~rotary_b_mask;
        }
    }

    pub fn queueRotaryStep(self: *Bus, direction: i2) void {
        if (direction > 0 and self.rotary_pending < std.math.maxInt(i16)) {
            self.rotary_pending += 1;
        } else if (direction < 0 and self.rotary_pending > std.math.minInt(i16)) {
            self.rotary_pending -= 1;
        }
        if (self.rotary_phase == 0) self.startRotaryStep();
    }

    fn startRotaryStep(self: *Bus) void {
        if (self.rotary_pending == 0) return;
        self.rotary_active = if (self.rotary_pending > 0) 1 else -1;
        self.rotary_pending += if (self.rotary_active > 0) -1 else 1;
        self.rotary_phase = 1;
        self.applyRotaryPhase();
    }

    fn observeRotaryPort(self: *Bus, port_bit: u2) void {
        if (self.rotary_phase == 0) return;
        self.rotary_ports_read |= port_bit;
        if (self.rotary_ports_read != 0b11) return;

        self.rotary_ports_read = 0;
        if (self.rotary_phase < 4) {
            self.rotary_phase += 1;
            self.applyRotaryPhase();
        } else {
            self.rotary_phase = 0;
            self.rotary_active = 0;
            self.startRotaryStep();
        }
    }

    fn applyRotaryPhase(self: *Bus) void {
        const clockwise = self.rotary_active > 0;
        const state = if (clockwise)
            switch (self.rotary_phase) {
                1 => .{ false, true },
                2 => .{ false, false },
                3 => .{ true, false },
                4 => .{ true, true },
                else => unreachable,
            }
        else switch (self.rotary_phase) {
            1 => .{ true, false },
            2 => .{ false, false },
            3 => .{ false, true },
            4 => .{ true, true },
            else => unreachable,
        };
        self.setRotaryState(state[0], state[1]);
    }

    pub fn fetch16(self: *Bus, address: u32) !u16 {
        return @as(u16, @intCast(try self.readInt(u16, address)));
    }

    pub fn fetch32(self: *Bus, address: u32) !u32 {
        return @as(u32, @intCast(try self.readInt(u32, address)));
    }

    pub fn fetchInstruction(self: *Bus, address: u32) !u32 {
        if (flashOffset(address, 2)) |offset| {
            if (offset + 4 <= self.flash.len) return readNativeInt(u32, self.flash[offset .. offset + 4]);
            return readNativeInt(u16, self.flash[offset .. offset + 2]);
        }
        return self.fetch32(address);
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
        if (flashOffset(address, @sizeOf(T))) |offset| {
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
        if (flashOffset(address, @sizeOf(T)) != null) {
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
        if (address >= afio_base and address < afio_base + @sizeOf(AfioRegs)) return self.readStruct(T, &self.afio, address - afio_base);
        if (address >= exti_base and address < exti_base + @sizeOf(ExtiRegs)) return self.readStruct(T, &self.exti, address - exti_base);
        if (address >= gpioa_base and address < gpioa_base + 28) {
            const offset = address - gpioa_base;
            const result = self.readStruct(T, &self.gpio_a, offset);
            if (offset == 8 and T == u32) self.observeRotaryPort(0b01);
            return result;
        }
        if (address >= gpioc_base and address < gpioc_base + 28) return self.readStruct(T, &self.gpio_c, address - gpioc_base);
        if (address >= gpiod_base and address < gpiod_base + 28) {
            const offset = address - gpiod_base;
            const result = self.readStruct(T, &self.gpio_d, offset);
            if (offset == 8 and T == u32) self.observeRotaryPort(0b10);
            return result;
        }

        if (address >= systick_base and address < systick_base + 24) {
            const offset = address - systick_base;
            return switch (offset) {
                0 => castRead(T, self.systick.ctlr),
                4 => castRead(T, self.systick.sr),
                8 => castRead(T, self.systick.now(self.io)),
                16 => castRead(T, self.systick.cmp),
                else => castRead(T, 0),
            };
        }

        if (address >= i2c1_base and address < i2c1_base + 32) {
            self.updateI2cStatus();
            const offset = address - i2c1_base;
            if (offset == 20 and self.i2c.ready_star1 != 0 and self.cpu_cycles < self.i2c.ready_cycle) {
                self.stall_until_cycle = self.i2c.ready_cycle;
            }
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
        if (address >= afio_base and address < afio_base + @sizeOf(AfioRegs)) {
            self.writeStruct(T, &self.afio, address - afio_base, value);
            return;
        }
        if (address >= exti_base and address < exti_base + @sizeOf(ExtiRegs)) {
            const offset = address - exti_base;
            if (offset == 20) {
                self.exti.intfr &= ~@as(u32, @intCast(value));
            } else {
                self.writeStruct(T, &self.exti, offset, value);
            }
            return;
        }
        if (address >= pfic_base + 0x100 and address < pfic_base + 0x108) {
            const shift: u6 = @intCast((address - (pfic_base + 0x100)) * 8);
            self.pfic_enabled |= @as(u64, @intCast(value)) << shift;
            return;
        }
        if (address >= pfic_base + 0x180 and address < pfic_base + 0x188) {
            const shift: u6 = @intCast((address - (pfic_base + 0x180)) * 8);
            self.pfic_enabled &= ~(@as(u64, @intCast(value)) << shift);
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
                    self.systick.start_ns = @as(u64, @intCast(nowNs(self.io)));
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
                        self.i2c.ready_star1 = 0;
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
                            self.i2c.star1 = 0;
                            self.i2c.ready_star1 = 0x0082;
                            self.i2c.ready_cycle = self.cpu_cycles + i2c_byte_cycles;
                            self.i2c.star2 = 0x0007;
                        },
                        .addressed => {
                            self.i2c_data_writes += 1;
                            if (self.i2c.packet_len < self.i2c.packet.len) {
                                self.i2c.packet[self.i2c.packet_len] = @as(u8, @truncate(v));
                                self.i2c.packet_len += 1;
                            }
                            self.i2c.star1 = 0;
                            self.i2c.ready_star1 = 0x0084;
                            self.i2c.ready_cycle = self.cpu_cycles + i2c_byte_cycles;
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

    fn updateI2cStatus(self: *Bus) void {
        if (self.i2c.ready_star1 != 0 and self.cpu_cycles >= self.i2c.ready_cycle) {
            self.i2c.star1 = self.i2c.ready_star1;
            self.i2c.ready_star1 = 0;
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
            if (ptr == &self.gpio_a) {
                const preserved = ptr.indr & rotary_a_mask;
                ptr.indr = (ptr.outdr & ~rotary_a_mask) | preserved;
            } else if (ptr == &self.gpio_d) {
                const external_mask = @as(u32, 1 << 1) | rotary_b_mask;
                const preserved = ptr.indr & external_mask;
                ptr.indr = (ptr.outdr & ~external_mask) | preserved;
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

fn flashOffset(address: u32, size: usize) ?usize {
    const offset: usize = if (address < flash_base)
        address
    else if (address >= flash_base)
        address - flash_base
    else
        return null;
    if (offset > flash_size or size > flash_size - offset) return null;
    return offset;
}

fn nowNs(io: ?std.Io) i96 {
    return if (io) |value| std.Io.Clock.awake.now(value).nanoseconds else 0;
}

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

test "instruction fetch supports compressed instruction at flash end" {
    var bus = Bus{};
    bus.flash[flash_size - 2] = 0x34;
    bus.flash[flash_size - 1] = 0x12;
    try std.testing.expectEqual(@as(u32, 0x1234), try bus.fetchInstruction(flash_base + flash_size - 2));
}

test "zero-address flash alias matches native flash address" {
    var bus = Bus{};
    bus.flash[0x20] = 0x34;
    bus.flash[0x21] = 0x12;

    try std.testing.expectEqual(@as(u16, 0x1234), try bus.read16(0x20));
    try std.testing.expectEqual(@as(u16, 0x1234), try bus.read16(flash_base + 0x20));
    try std.testing.expectEqual(try bus.fetchInstruction(0x20), try bus.fetchInstruction(flash_base + 0x20));
}

test "polling pending I2C status requests virtual clock advance" {
    var bus = Bus{};
    bus.cpu_cycles = 100;
    bus.i2c.ready_star1 = i2c_star1_txe;
    bus.i2c.ready_cycle = 532;

    try std.testing.expectEqual(@as(u16, 0), try bus.read16(i2c1_base + 20));
    try std.testing.expectEqual(@as(?u64, 532), bus.stall_until_cycle);
}

test "PD1 button edges raise configured EXTI interrupt" {
    var bus = Bus{};
    bus.afio.exticr = 3 << 2;
    bus.exti.intenr = 1 << 1;
    bus.exti.rtenr = 1 << 1;
    bus.exti.ftenr = 1 << 1;
    bus.pfic_enabled = 1 << 20;

    bus.setButtonPressed(true);
    try std.testing.expect(bus.extiInterruptPending());
    try bus.write32(exti_base + 20, 1 << 1);
    try std.testing.expect(!bus.extiInterruptPending());

    bus.setButtonPressed(false);
    try std.testing.expect(bus.extiInterruptPending());
}

test "rotary inputs survive GPIO output writes" {
    var bus = Bus{};
    bus.setRotaryState(false, true);

    try bus.write32(gpioa_base + 16, 1 << 7);
    try bus.write32(gpiod_base + 16, 1 << 6);

    try std.testing.expectEqual(@as(u32, 0), (try bus.read32(gpioa_base + 8)) & Bus.rotary_a_mask);
    try std.testing.expectEqual(Bus.rotary_b_mask, (try bus.read32(gpiod_base + 8)) & Bus.rotary_b_mask);
    try std.testing.expectEqual(@as(u32, 1 << 7), (try bus.read32(gpioa_base + 8)) & (1 << 7));
    try std.testing.expectEqual(@as(u32, 1 << 6), (try bus.read32(gpiod_base + 8)) & (1 << 6));
}

test "rotary cycle advances only after firmware reads both ports" {
    var bus = Bus{};
    bus.queueRotaryStep(1);
    const expected = [_]u32{
        1 << 5,
        0,
        1 << 2,
        (1 << 2) | (1 << 5),
    };

    for (expected) |state| {
        const phase_before = bus.rotary_phase;
        const a = (try bus.read32(gpioa_base + 8)) & Bus.rotary_a_mask;
        try std.testing.expectEqual(phase_before, bus.rotary_phase);
        const b = (try bus.read32(gpiod_base + 8)) & Bus.rotary_b_mask;
        try std.testing.expectEqual(state, a | b);
    }
    try std.testing.expectEqual(@as(u3, 0), bus.rotary_phase);
}
