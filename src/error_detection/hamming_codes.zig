const std = @import("std");

pub const HammingError = error{InvalidLength};

pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, data.len * 2);
    for (data, 0..) |byte, i| {
        const hi: u4 = @truncate(byte >> 4);
        const lo: u4 = @truncate(byte & 0x0F);
        out[i * 2] = 0x80 | encodeNibble(hi);
        out[i * 2 + 1] = 0x80 | encodeNibble(lo);
    }
    return out;
}

pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len % 2 != 0) return HammingError.InvalidLength;

    const out = try allocator.alloc(u8, encoded.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi_code: u7 = @truncate(encoded[i * 2] & 0x7F);
        const lo_code: u7 = @truncate(encoded[i * 2 + 1] & 0x7F);
        const hi = decodeNibble(hi_code);
        const lo = decodeNibble(lo_code);
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

fn encodeNibble(nibble: u4) u7 {
    const d1: u7 = (nibble >> 0) & 1;
    const d2: u7 = (nibble >> 1) & 1;
    const d3: u7 = (nibble >> 2) & 1;
    const d4: u7 = (nibble >> 3) & 1;

    const p1 = d1 ^ d2 ^ d4;
    const p2 = d1 ^ d3 ^ d4;
    const p3 = d2 ^ d3 ^ d4;

    var code: u7 = 0;
    code |= p1 << 0; // position 1
    code |= p2 << 1; // position 2
    code |= d1 << 2; // position 3
    code |= p3 << 3; // position 4
    code |= d2 << 4; // position 5
    code |= d3 << 5; // position 6
    code |= d4 << 6; // position 7
    return code;
}

fn decodeNibble(code_in: u7) u4 {
    var code = code_in;
    const p1 = (code >> 0) & 1;
    const p2 = (code >> 1) & 1;
    const d1 = (code >> 2) & 1;
    const p3 = (code >> 3) & 1;
    const d2 = (code >> 4) & 1;
    const d3 = (code >> 5) & 1;
    const d4 = (code >> 6) & 1;

    const c1 = p1 ^ d1 ^ d2 ^ d4;
    const c2 = p2 ^ d1 ^ d3 ^ d4;
    const c3 = p3 ^ d2 ^ d3 ^ d4;

    const syndrome: u3 = @intCast((c3 << 2) | (c2 << 1) | c1);
    if (syndrome != 0) {
        code ^= @as(u7, 1) << (syndrome - 1); // flip the faulty bit
    }

    const fd1 = (code >> 2) & 1;
    const fd2 = (code >> 4) & 1;
    const fd3 = (code >> 5) & 1;
    const fd4 = (code >> 6) & 1;
    return @intCast(fd1 | (fd2 << 1) | (fd3 << 2) | (fd4 << 3));
}
