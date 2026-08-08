const std = @import("std");

pub const Error = error{
    InvalidElfMagic,
    UnsupportedElfClass,
    UnsupportedEndian,
    UnsupportedMachine,
    SegmentOutOfRange,
};

const ElfHeader = extern struct {
    ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32,
    e_shoff: u32,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const ProgramHeader = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};

pub const Image = struct {
    entry: u32,
};

pub fn load(bytes: []const u8, flash: []u8, ram: []u8) !Image {
    if (bytes.len < @sizeOf(ElfHeader)) return error.EndOfStream;
    const header: ElfHeader = std.mem.bytesToValue(ElfHeader, bytes[0..@sizeOf(ElfHeader)]);
    if (!std.mem.eql(u8, header.ident[0..4], "\x7FELF")) return Error.InvalidElfMagic;
    if (header.ident[4] != 1) return Error.UnsupportedElfClass;
    if (header.ident[5] != 1) return Error.UnsupportedEndian;
    if (header.e_machine != 243) return Error.UnsupportedMachine;

    var i: usize = 0;
    while (i < header.e_phnum) : (i += 1) {
        const start = header.e_phoff + @as(u32, @intCast(i)) * header.e_phentsize;
        const end = start + @sizeOf(ProgramHeader);
        if (end > bytes.len) return error.EndOfStream;
        const ph = std.mem.bytesToValue(ProgramHeader, bytes[start..end]);
        if (ph.p_type != 1) continue;
        try loadSegment(bytes, ph, flash, ram);
    }

    return .{ .entry = header.e_entry };
}

fn loadSegment(bytes: []const u8, ph: ProgramHeader, flash: []u8, ram: []u8) !void {
    const source = bytes[ph.p_offset .. ph.p_offset + ph.p_filesz];

    // CH32V003 exposes flash both at its native 0x0800_0000 address and at
    // address zero.  Current ch32fun linker scripts use the zero-address
    // alias, including for the load address of initialized RAM data.
    if (flashOffset(ph.p_paddr, ph.p_memsz, flash.len)) |dst| {
        @memcpy(flash[dst .. dst + ph.p_filesz], source);
        @memset(flash[dst + ph.p_filesz .. dst + ph.p_memsz], 0);
        return;
    }

    if (ph.p_paddr >= 0x2000_0000 and ph.p_paddr + ph.p_memsz <= 0x2000_0000 + ram.len) {
        const dst = ph.p_paddr - 0x2000_0000;
        @memcpy(ram[dst .. dst + ph.p_filesz], source);
        @memset(ram[dst + ph.p_filesz .. dst + ph.p_memsz], 0);
        return;
    }

    return Error.SegmentOutOfRange;
}

fn flashOffset(address: u32, size: u32, flash_len: usize) ?usize {
    const offset = if (address < 0x0800_0000) address else address - 0x0800_0000;
    if (offset > flash_len or size > flash_len - offset) return null;
    return offset;
}

test "flash accepts native and zero-address alias segments" {
    try std.testing.expectEqual(@as(?usize, 0x1234), flashOffset(0x0000_1234, 4, 16 * 1024));
    try std.testing.expectEqual(@as(?usize, 0x1234), flashOffset(0x0800_1234, 4, 16 * 1024));
    try std.testing.expectEqual(@as(?usize, null), flashOffset(0x0000_4000, 1, 16 * 1024));
}
