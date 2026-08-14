//! Formatos de paquete acordados entre las 3 parejas.
//! Ver "Propuesta de protocolo - Lab 3". Los nombres de campo son literales:
//! cambiarlos rompe la interoperabilidad con las otras implementaciones.

const std = @import("std");

pub const HELLO = "HELLO";
pub const LSA = "LSA";

/// { "type": "HELLO", "from": "<ip_origen>" }
pub const Hello = struct {
    type: []const u8 = HELLO,
    from: []const u8,
};

/// {"<ip_vecino>": <costo>, ...}  -- objeto de claves dinamicas, no un arreglo.
pub const LinkMap = std.json.ArrayHashMap(i64);

/// {
///   "type": "LSA", "origin": "<ip_creador>", "seq": <int>, "ttl": <int>,
///   "links": {"<ip_vecino>": <costo>, ...}, "from": "<ip_emisor_actual>"
/// }
pub const Lsa = struct {
    type: []const u8 = LSA,
    origin: []const u8,
    seq: u32,
    ttl: i32,
    links: LinkMap,
    from: []const u8,
};

/// {
///   "type": "AUTH" | "WITHDRAW" | "ERROR" | "LOGOUT",
///   "origin": "<ip_nodo_ATM>", "destination": "<ip_nodo_servidor>",
///   "payload": { ... }
/// }
/// `payload` es opaco para el enrutamiento: los routers intermedios no lo tocan.
pub const DataMsg = struct {
    type: []const u8,
    origin: []const u8,
    destination: []const u8,
    payload: std.json.Value = .null,
};

pub const ParseError = error{MissingType, MissingField};

/// Lee unicamente "type" para despachar, sin comprometerse a un struct.
/// `allocator` deberia ser un arena de vida corta: el string apunta al parse.
pub fn peekType(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{});
    const t = switch (v) {
        .object => |o| o.get("type") orelse return ParseError.MissingType,
        else => return ParseError.MissingType,
    };
    return switch (t) {
        .string => |s| s,
        else => ParseError.MissingType,
    };
}

/// Igual que peekType pero para "destination" (plano de datos: enrutar sin
/// deserializar el payload).
pub fn peekDestination(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{});
    const d = switch (v) {
        .object => |o| o.get("destination") orelse return ParseError.MissingField,
        else => return ParseError.MissingField,
    };
    return switch (d) {
        .string => |s| s,
        else => ParseError.MissingField,
    };
}

test "HELLO se serializa con los campos exactos del acuerdo" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(Hello{ .from = "10.0.0.1" }, .{}, &w);
    try std.testing.expectEqualStrings(
        \\{"type":"HELLO","from":"10.0.0.1"}
    , w.buffered());
}

test "LSA se serializa con links como objeto de claves dinamicas" {
    const allocator = std.testing.allocator;
    var links: LinkMap = .{};
    defer links.map.deinit(allocator);
    try links.map.put(allocator, "10.0.0.2", 7);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(Lsa{
        .origin = "10.0.0.1",
        .seq = 3,
        .ttl = 8,
        .links = links,
        .from = "10.0.0.1",
    }, .{}, &w);
    try std.testing.expectEqualStrings(
        \\{"type":"LSA","origin":"10.0.0.1","seq":3,"ttl":8,"links":{"10.0.0.2":7},"from":"10.0.0.1"}
    , w.buffered());
}

test "peekType y peekDestination despachan sin deserializar el payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line =
        \\{"type":"AUTH","origin":"10.0.0.1","destination":"10.0.0.9","payload":{"user":"a","pin":"1"}}
    ;
    try std.testing.expectEqualStrings("AUTH", try peekType(arena.allocator(), line));
    try std.testing.expectEqualStrings("10.0.0.9", try peekDestination(arena.allocator(), line));
}
