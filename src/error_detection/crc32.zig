const std = @import("std");

pub const CrcError = error{
    InvalidLength,
    CrcMismatch,
};

pub fn append(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const crc = std.hash.Crc32.hash(payload);

    const out = try allocator.alloc(u8, payload.len + 4);
    @memcpy(out[0..payload.len], payload);
    std.mem.writeInt(u32, out[payload.len..][0..4], crc, .big);
    return out;
}

pub fn verify(allocator: std.mem.Allocator, framed: []const u8) ![]u8 {
    if (framed.len < 4) return CrcError.InvalidLength;

    const payload = framed[0 .. framed.len - 4];
    const received_crc = std.mem.readInt(u32, framed[framed.len - 4 ..][0..4], .big);
    const computed_crc = std.hash.Crc32.hash(payload);
    if (received_crc != computed_crc) return CrcError.CrcMismatch;

    return allocator.dupe(u8, payload);
}
