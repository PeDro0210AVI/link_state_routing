//! Transporte: una conexion TCP por mensaje, una linea JSON por conexion.
//!
//! El acuerdo entre las 3 parejas define JSON plano en el cable. NO se aplica
//! CRC32 ni Hamming aqui: `error_detection/` es codigo del laboratorio 2 y se
//! queda fuera de la ruta del cable para no romper la interoperabilidad.

pub const std = @import("std");

const net = std.Io.net;

const Io = std.Io;
const Stream = net.Stream;

pub fn set_stream(port: u16, host: []const u8, io: Io) !Stream {
    const peer = try net.IpAddress.parseIp4(host, port);
    return peer.connect(io, .{ .mode = .stream });
}

/// Serializa `msg` como JSON y lo escribe como una linea terminada en '\n'.
pub fn sendMessage(io: Io, stream: *Stream, msg: anytype) !void {
    var write_buf: [4096]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    const w = &stream_writer.interface;
    try std.json.Stringify.value(msg, .{}, w);
    try w.writeAll("\n");
    try w.flush();
}

/// Reenvia una linea ya serializada tal cual. El plano de datos la usa para no
/// re-serializar el paquete: el `payload` es opaco a los routers intermedios.
pub fn sendRaw(io: Io, stream: *Stream, line: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    const w = &stream_writer.interface;
    try w.writeAll(line);
    try w.writeAll("\n");
    try w.flush();
}

/// Lee una linea y la duplica en `allocator` (el buffer del reader es local).
pub fn recvLine(io: Io, stream: *Stream, allocator: std.mem.Allocator) ![]u8 {
    var reader_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &reader_buf);
    const raw = try stream_reader.interface.takeDelimiterInclusive('\n');
    return allocator.dupe(u8, std.mem.trim(u8, raw, "\r\n"));
}

/// `ignore_unknown_fields` es deliberado: las otras implementaciones pueden
/// mandar campos extra y eso no debe tumbar el nodo.
pub fn parse(comptime T: type, allocator: std.mem.Allocator, line: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn recvMessage(io: Io, stream: *Stream, allocator: std.mem.Allocator, comptime T: type) !T {
    const line = try recvLine(io, stream, allocator);
    return parse(T, allocator, line);
}
