pub const std = @import("std");
pub const error_detection = @import("error_detection/root.zig");

const net = std.Io.net;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Stream = net.Stream;

pub fn set_stream(port: u16, host: []const u8, io: Io) !Stream {
    const peer = try net.IpAddress.parseIp4(host, port);

    const stream = try peer.connect(io, .{ .mode = .stream });

    return stream;
}

pub fn sendMessage(io: std.Io, stream: *Stream, msg: anytype) !void {
    var buf: [1024]u8 = undefined;
    var json_writer: std.Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(msg, .{}, &json_writer);
    var write_buf: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(json_writer.buffered());
    try stream_writer.interface.writeAll("\n");
    try stream_writer.interface.flush();
}

pub fn recvMessage(io: std.Io, stream: *Stream, allocator: std.mem.Allocator, comptime T: type) !T {
    var reader_buf: [1024]u8 = undefined;
    var stream_reader = stream.reader(io, &reader_buf);
    const raw = try stream_reader.interface.takeDelimiterInclusive('\n');
    //const encoded = std.mem.trimRight(u8, raw, "\n");
    const encoded = std.mem.trimEnd(u8, raw, "\n");

    const framed = try error_detection.hamming.decode(allocator, encoded);
    defer allocator.free(framed);

    const payload = try error_detection.crc32.verify(allocator, framed);
    defer allocator.free(payload);

    return std.json.parseFromSliceLeaky(T, allocator, payload, .{ .allocate = .alloc_always });
}
