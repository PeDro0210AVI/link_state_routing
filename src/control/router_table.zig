//! Escritura y lectura de `nodo_tabla_enrutamiento.csv`, el contrato entre el
//! plano de control y el plano de datos.
//!
//! Columnas: destino,siguiente_salto,costo,ip,puerto
//! El siguiente salto siempre es un vecino directo, asi que la ip y el puerto
//! salen del archivo de vecinos: no hace falta un directorio global.

const std = @import("std");
const lib = @import("../root.zig");
const spf = @import("spf.zig");

pub const HEADER = "destino,siguiente_salto,costo,ip,puerto";

pub const Hop = struct {
    next_hop: []const u8,
    cost: i64,
    host: []const u8,
    port: u16,
};

fn findNeighbor(neighbors: []const lib.NodeInfo, id: []const u8) ?lib.NodeInfo {
    for (neighbors) |n| {
        if (std.mem.eql(u8, n.id, id)) return n;
    }
    return null;
}

pub fn write(
    io: std.Io,
    path: []const u8,
    routes: []const spf.Route,
    neighbors: []const lib.NodeInfo,
) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    const w = &file_writer.interface;

    try w.print("{s}\n", .{HEADER});
    for (routes) |r| {
        const hop = findNeighbor(neighbors, r.next_hop) orelse {
            // No deberia pasar: el primer salto de Dijkstra es un vecino directo.
            std.debug.print("tabla: siguiente salto {s} no esta en vecinos, se omite\n", .{r.next_hop});
            continue;
        };
        try w.print("{s},{s},{d},{s},{d}\n", .{ r.dest, r.next_hop, r.cost, hop.host, hop.port });
    }
    try w.flush();
}

/// Carga la tabla para el plano de datos: destino -> siguiente salto alcanzable.
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.StringArrayHashMapUnmanaged(Hop) {
    var table: std.StringArrayHashMapUnmanaged(Hop) = .empty;
    errdefer table.deinit(allocator);

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const reader = &file_reader.interface;

    while (reader.takeDelimiterInclusive('\n')) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0 or std.mem.startsWith(u8, line, "destino")) continue;

        var it = std.mem.splitScalar(u8, line, ',');
        const dest = it.next() orelse continue;
        const next_hop = it.next() orelse continue;
        const cost_str = it.next() orelse continue;
        const host = it.next() orelse continue;
        const port_str = it.next() orelse continue;

        try table.put(allocator, try allocator.dupe(u8, dest), .{
            .next_hop = try allocator.dupe(u8, next_hop),
            .cost = std.fmt.parseInt(i64, cost_str, 10) catch continue,
            .host = try allocator.dupe(u8, host),
            .port = std.fmt.parseUnsigned(u16, port_str, 10) catch continue,
        });
    } else |_| {}

    return table;
}
