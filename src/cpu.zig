const std = @import("std");
const Bus = @import("bus.zig").Bus;

pub const Error = error{
    UnsupportedOpcode,
    UnsupportedCompressedOpcode,
    MisalignedInstruction,
};

pub const Cpu = struct {
    regs: [32]u32 = [_]u32{0} ** 32,
    pc: u32 = 0,
    instruction_count: u64 = 0,
    cycle_count: u64 = 0,

    pub fn init(entry: u32, stack_top: u32) Cpu {
        var cpu = Cpu{ .pc = entry };
        cpu.regs[2] = stack_top;
        return cpu;
    }

    pub fn step(self: *Cpu, bus: *Bus) !void {
        // A single 32-bit fetch covers both standard and compressed
        // instructions and avoids reading the first halfword twice.
        const inst = try bus.fetchInstruction(self.pc);
        const half: u16 = @truncate(inst);
        const cycles: u64 = estimateCycles(half);
        bus.cpu_cycles = self.cycle_count;
        if ((half & 0b11) != 0b11) {
            try self.execCompressed(bus, half);
        } else {
            try self.exec32(bus, inst);
        }
        self.regs[0] = 0;
        self.instruction_count += 1;
        self.cycle_count += cycles;
        if (bus.stall_until_cycle) |target| {
            if (target > self.cycle_count) self.cycle_count = target;
            bus.stall_until_cycle = null;
        }
        bus.cpu_cycles = self.cycle_count;
    }

    fn exec32(self: *Cpu, bus: *Bus, inst: u32) !void {
        const opcode = inst & 0x7f;
        const rd: u5 = @intCast((inst >> 7) & 0x1f);
        const funct3 = (inst >> 12) & 0x7;
        const rs1: u5 = @intCast((inst >> 15) & 0x1f);
        const rs2: u5 = @intCast((inst >> 20) & 0x1f);
        const funct7 = (inst >> 25) & 0x7f;
        const pc_next = self.pc + 4;

        switch (opcode) {
            0x03 => {
                const imm = immI(inst);
                const address = self.regs[rs1] +% @as(u32, @bitCast(imm));
                self.pc = pc_next;
                switch (funct3) {
                    0 => self.writeReg(rd, @bitCast(@as(i32, @intCast(@as(i8, @bitCast(try bus.read8(address))))))),
                    1 => self.writeReg(rd, @bitCast(@as(i32, @intCast(@as(i16, @bitCast(try bus.read16(address))))))),
                    2 => self.writeReg(rd, try bus.read32(address)),
                    4 => self.writeReg(rd, try bus.read8(address)),
                    5 => self.writeReg(rd, try bus.read16(address)),
                    else => return Error.UnsupportedOpcode,
                }
            },
            0x13 => {
                const imm = immI(inst);
                self.pc = pc_next;
                switch (funct3) {
                    0 => self.writeReg(rd, self.regs[rs1] +% @as(u32, @bitCast(imm))),
                    1 => self.writeReg(rd, self.regs[rs1] << @as(u5, @intCast(@as(u32, @bitCast(imm)) & 0x1f))),
                    2 => self.writeReg(rd, @intFromBool(@as(i32, @bitCast(self.regs[rs1])) < imm)),
                    3 => self.writeReg(rd, @intFromBool(self.regs[rs1] < @as(u32, @bitCast(imm)))),
                    4 => self.writeReg(rd, self.regs[rs1] ^ @as(u32, @bitCast(imm))),
                    5 => {
                        const shamt: u5 = @truncate((inst >> 20) & 0x1f);
                        if ((inst & 0xfe00_0000) == 0x4000_0000) {
                            self.writeReg(rd, @bitCast(@as(i32, @bitCast(self.regs[rs1])) >> shamt));
                        } else {
                            self.writeReg(rd, self.regs[rs1] >> shamt);
                        }
                    },
                    6 => self.writeReg(rd, self.regs[rs1] | @as(u32, @bitCast(imm))),
                    7 => self.writeReg(rd, self.regs[rs1] & @as(u32, @bitCast(imm))),
                    else => return Error.UnsupportedOpcode,
                }
            },
            0x17 => {
                self.writeReg(rd, self.pc +% (inst & 0xfffff000));
                self.pc = pc_next;
            },
            0x23 => {
                const imm = immS(inst);
                const address = self.regs[rs1] +% @as(u32, @bitCast(imm));
                self.pc = pc_next;
                switch (funct3) {
                    0 => try bus.write8(address, @truncate(self.regs[rs2])),
                    1 => try bus.write16(address, @truncate(self.regs[rs2])),
                    2 => try bus.write32(address, self.regs[rs2]),
                    else => return Error.UnsupportedOpcode,
                }
            },
            0x33 => {
                self.pc = pc_next;
                switch (funct3) {
                    0 => self.writeReg(rd, if (funct7 == 0x20) self.regs[rs1] -% self.regs[rs2] else self.regs[rs1] +% self.regs[rs2]),
                    1 => self.writeReg(rd, self.regs[rs1] << @as(u5, @truncate(self.regs[rs2]))),
                    2 => self.writeReg(rd, @intFromBool(@as(i32, @bitCast(self.regs[rs1])) < @as(i32, @bitCast(self.regs[rs2])))),
                    3 => self.writeReg(rd, @intFromBool(self.regs[rs1] < self.regs[rs2])),
                    4 => self.writeReg(rd, self.regs[rs1] ^ self.regs[rs2]),
                    5 => self.writeReg(rd, if (funct7 == 0x20) @bitCast(@as(i32, @bitCast(self.regs[rs1])) >> @as(u5, @truncate(self.regs[rs2]))) else self.regs[rs1] >> @as(u5, @truncate(self.regs[rs2]))),
                    6 => self.writeReg(rd, self.regs[rs1] | self.regs[rs2]),
                    7 => self.writeReg(rd, self.regs[rs1] & self.regs[rs2]),
                    else => return Error.UnsupportedOpcode,
                }
            },
            0x37 => {
                self.writeReg(rd, inst & 0xfffff000);
                self.pc = pc_next;
            },
            0x63 => {
                const imm = immB(inst);
                const take = switch (funct3) {
                    0 => self.regs[rs1] == self.regs[rs2],
                    1 => self.regs[rs1] != self.regs[rs2],
                    4 => @as(i32, @bitCast(self.regs[rs1])) < @as(i32, @bitCast(self.regs[rs2])),
                    5 => @as(i32, @bitCast(self.regs[rs1])) >= @as(i32, @bitCast(self.regs[rs2])),
                    6 => self.regs[rs1] < self.regs[rs2],
                    7 => self.regs[rs1] >= self.regs[rs2],
                    else => return Error.UnsupportedOpcode,
                };
                self.pc = if (take) self.pc +% @as(u32, @bitCast(imm)) else pc_next;
            },
            0x67 => {
                const imm = immI(inst);
                const target = (self.regs[rs1] +% @as(u32, @bitCast(imm))) & ~@as(u32, 1);
                self.writeReg(rd, pc_next);
                self.pc = target;
            },
            0x6f => {
                const imm = immJ(inst);
                self.writeReg(rd, pc_next);
                self.pc = self.pc +% @as(u32, @bitCast(imm));
            },
            0x0f => self.pc = pc_next,
            0x73 => {
                // Minimal CSR subset: treat as NOP unless it is ebreak/ecall.
                if (inst == 0x0010_0073 or inst == 0x0000_0073) return Error.UnsupportedOpcode;
                self.pc = pc_next;
            },
            else => return Error.UnsupportedOpcode,
        }
    }

    fn execCompressed(self: *Cpu, bus: *Bus, inst: u16) !void {
        const quadrant = inst & 0b11;
        const funct3 = (inst >> 13) & 0x7;
        const pc_next = self.pc + 2;

        switch (quadrant) {
            0b00 => switch (funct3) {
                0b000 => {
                    const rd = 8 + ((inst >> 2) & 0x7);
                    const imm = (@as(u32, (inst >> 7) & 0x30)) |
                        (@as(u32, (inst >> 1) & 0x3c0)) |
                        (@as(u32, (inst >> 4) & 0x4)) |
                        (@as(u32, (inst >> 2) & 0x8));
                    self.writeReg(@intCast(rd), self.regs[2] + imm);
                    self.pc = pc_next;
                },
                0b010 => {
                    const rd = 8 + ((inst >> 2) & 0x7);
                    const rs1 = 8 + ((inst >> 7) & 0x7);
                    const imm = (@as(u32, (inst >> 7) & 0x38)) | (@as(u32, (inst >> 4) & 0x4)) | (@as(u32, (inst << 1) & 0x40));
                    self.writeReg(@intCast(rd), try bus.read32(self.regs[@intCast(rs1)] + imm));
                    self.pc = pc_next;
                },
                0b110 => {
                    const rs1 = 8 + ((inst >> 7) & 0x7);
                    const rs2 = 8 + ((inst >> 2) & 0x7);
                    const imm = (@as(u32, (inst >> 7) & 0x38)) | (@as(u32, (inst >> 4) & 0x4)) | (@as(u32, (inst << 1) & 0x40));
                    try bus.write32(self.regs[@intCast(rs1)] + imm, self.regs[@intCast(rs2)]);
                    self.pc = pc_next;
                },
                else => return Error.UnsupportedCompressedOpcode,
            },
            0b01 => switch (funct3) {
                0b000 => {
                    const rd: u5 = @intCast((inst >> 7) & 0x1f);
                    const imm = signExtend(((@as(i32, (inst >> 2) & 0x1f)) | (@as(i32, (inst >> 7) & 0x20))), 6);
                    self.writeReg(rd, self.regs[rd] +% @as(u32, @bitCast(imm)));
                    self.pc = pc_next;
                },
                0b001 => {
                    self.writeReg(1, pc_next);
                    self.pc = self.pc +% @as(u32, @bitCast(cJumpImm(inst)));
                },
                0b010 => {
                    const rd: u5 = @intCast((inst >> 7) & 0x1f);
                    const imm = signExtend(((@as(i32, (inst >> 2) & 0x1f)) | (@as(i32, (inst >> 7) & 0x20))), 6);
                    self.writeReg(rd, @as(u32, @bitCast(imm)));
                    self.pc = pc_next;
                },
                0b011 => {
                    const rd: u5 = @intCast((inst >> 7) & 0x1f);
                    if (rd == 2) {
                        const imm = cAddi16spImm(inst);
                        self.writeReg(2, self.regs[2] +% @as(u32, @bitCast(imm)));
                    } else {
                        const imm = signExtend(((@as(i32, (inst >> 2) & 0x1f)) | (@as(i32, (inst >> 7) & 0x20))) << 12, 18);
                        self.writeReg(rd, @as(u32, @bitCast(imm)));
                    }
                    self.pc = pc_next;
                },
                0b100 => {
                    const subop = (inst >> 10) & 0x3;
                    const rd = 8 + ((inst >> 7) & 0x7);
                    const rs2 = 8 + ((inst >> 2) & 0x7);
                    if (subop != 0b11) {
                        const shamt: u5 = @truncate(((inst >> 2) & 0x1f) | ((inst >> 7) & 0x20));
                        switch (subop) {
                            0 => self.writeReg(@intCast(rd), self.regs[@intCast(rd)] >> shamt),
                            1 => self.writeReg(@intCast(rd), @bitCast(@as(i32, @bitCast(self.regs[@intCast(rd)])) >> shamt)),
                            2 => {
                                const imm = signExtend(((@as(i32, (inst >> 2) & 0x1f)) | (@as(i32, (inst >> 7) & 0x20))), 6);
                                self.writeReg(@intCast(rd), self.regs[@intCast(rd)] & @as(u32, @bitCast(imm)));
                            },
                            else => return Error.UnsupportedCompressedOpcode,
                        }
                    } else {
                        if (((inst >> 12) & 0x1) != 0) return Error.UnsupportedCompressedOpcode;
                        const op = ((inst >> 5) & 0x3);
                        switch (op) {
                            0 => self.writeReg(@intCast(rd), self.regs[@intCast(rd)] -% self.regs[@intCast(rs2)]),
                            1 => self.writeReg(@intCast(rd), self.regs[@intCast(rd)] ^ self.regs[@intCast(rs2)]),
                            2 => self.writeReg(@intCast(rd), self.regs[@intCast(rd)] | self.regs[@intCast(rs2)]),
                            3 => self.writeReg(@intCast(rd), self.regs[@intCast(rd)] & self.regs[@intCast(rs2)]),
                            else => return Error.UnsupportedCompressedOpcode,
                        }
                    }
                    self.pc = pc_next;
                },
                0b101 => self.pc = self.pc +% @as(u32, @bitCast(cJumpImm(inst))),
                0b110 => {
                    const rs1 = 8 + ((inst >> 7) & 0x7);
                    const imm = cBranchImm(inst);
                    self.pc = if (self.regs[@intCast(rs1)] == 0) self.pc +% @as(u32, @bitCast(imm)) else pc_next;
                },
                0b111 => {
                    const rs1 = 8 + ((inst >> 7) & 0x7);
                    const imm = cBranchImm(inst);
                    self.pc = if (self.regs[@intCast(rs1)] != 0) self.pc +% @as(u32, @bitCast(imm)) else pc_next;
                },
                else => return Error.UnsupportedCompressedOpcode,
            },
            0b10 => switch (funct3) {
                0b000 => {
                    const rd: u5 = @intCast((inst >> 7) & 0x1f);
                    const shamt: u5 = @truncate(((inst >> 2) & 0x1f) | ((inst >> 7) & 0x20));
                    self.writeReg(rd, self.regs[rd] << shamt);
                    self.pc = pc_next;
                },
                0b010 => {
                    const rd: u5 = @intCast((inst >> 7) & 0x1f);
                    const imm = (@as(u32, (inst >> 2) & 0x1c)) | (@as(u32, (inst >> 7) & 0x20)) | (@as(u32, (inst << 4) & 0xc0));
                    self.writeReg(rd, try bus.read32(self.regs[2] + imm));
                    self.pc = pc_next;
                },
                0b100 => {
                    const rs1: u5 = @intCast((inst >> 7) & 0x1f);
                    const rs2: u5 = @intCast((inst >> 2) & 0x1f);
                    const bit12 = (inst >> 12) & 0x1;
                    if (bit12 == 0 and rs2 == 0) {
                        self.pc = self.regs[rs1];
                    } else if (bit12 == 0) {
                        self.writeReg(rs1, self.regs[rs2]);
                        self.pc = pc_next;
                    } else if (bit12 == 1 and rs2 == 0) {
                        self.writeReg(1, pc_next);
                        self.pc = self.regs[rs1];
                    } else {
                        self.writeReg(rs1, self.regs[rs1] +% self.regs[rs2]);
                        self.pc = pc_next;
                    }
                },
                0b110 => {
                    const rs2: u5 = @intCast((inst >> 2) & 0x1f);
                    const imm = (@as(u32, (inst >> 7) & 0x3c)) | (@as(u32, (inst >> 1) & 0xc0));
                    try bus.write32(self.regs[2] + imm, self.regs[rs2]);
                    self.pc = pc_next;
                },
                else => return Error.UnsupportedCompressedOpcode,
            },
            else => return Error.UnsupportedCompressedOpcode,
        }
    }

    fn writeReg(self: *Cpu, rd: u5, value: u32) void {
        if (rd == 0) return;
        self.regs[rd] = value;
    }
};

fn estimateCycles(half: u16) u64 {
    if ((half & 0b11) != 0b11) {
        const quadrant = half & 0b11;
        const funct3 = (half >> 13) & 0x7;
        return switch (quadrant) {
            0b00 => if (funct3 == 0b010 or funct3 == 0b110) 2 else 1,
            0b01 => if (funct3 == 0b001 or funct3 == 0b101 or funct3 == 0b110 or funct3 == 0b111) 2 else 1,
            0b10 => if (funct3 == 0b010 or funct3 == 0b100 or funct3 == 0b110) 2 else 1,
            else => 1,
        };
    }
    // Loads/stores and control transfers require an additional pipeline cycle
    // on the small QingKe core. The remaining RV32E instructions are modeled
    // as single-cycle operations.
    const opcode = half & 0x7f;
    return switch (opcode) {
        0x03, 0x23, 0x63, 0x67, 0x6f => 2,
        else => 1,
    };
}

fn immI(inst: u32) i32 {
    return @as(i32, @bitCast(inst)) >> 20;
}

fn immS(inst: u32) i32 {
    const imm = ((inst >> 7) & 0x1f) | ((inst >> 20) & 0xfe0);
    return signExtend(@intCast(imm), 12);
}

fn immB(inst: u32) i32 {
    const imm = ((inst >> 7) & 0x1e) |
        ((inst >> 20) & 0x7e0) |
        ((inst << 4) & 0x800) |
        ((inst >> 19) & 0x1000);
    return signExtend(@intCast(imm), 13);
}

fn immJ(inst: u32) i32 {
    const imm = ((inst >> 20) & 0x7fe) |
        ((inst >> 9) & 0x800) |
        (inst & 0x000f_f000) |
        ((inst >> 11) & 0x100000);
    return signExtend(@intCast(imm), 21);
}

fn cJumpImm(inst: u16) i32 {
    const imm = ((inst >> 2) & 0x000e) |
        ((inst << 3) & 0x0020) |
        ((inst >> 1) & 0x0040) |
        ((inst << 1) & 0x0080) |
        ((inst >> 7) & 0x0010) |
        ((inst >> 1) & 0x0300) |
        ((inst << 2) & 0x0400) |
        ((inst >> 1) & 0x0800);
    return signExtend(@intCast(imm), 12);
}

fn cBranchImm(inst: u16) i32 {
    const imm = ((inst >> 2) & 0x0006) |
        ((inst >> 7) & 0x0018) |
        ((inst << 3) & 0x0020) |
        ((inst << 1) & 0x00c0) |
        ((inst >> 4) & 0x0100);
    return signExtend(@intCast(imm), 9);
}

fn cAddi16spImm(inst: u16) i32 {
    const imm = ((inst >> 2) & 0x10) |
        ((inst << 3) & 0x20) |
        ((inst << 1) & 0x40) |
        ((inst << 4) & 0x180) |
        ((inst >> 3) & 0x200);
    return signExtend(@intCast(imm), 10);
}

fn signExtend(value: i32, bits: u6) i32 {
    const shift: u6 = 32 - bits;
    return (value << @as(u5, @intCast(shift))) >> @as(u5, @intCast(shift));
}
