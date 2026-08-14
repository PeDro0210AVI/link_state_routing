//! Plano de datos: capa de red sobre `nodo_tabla_enrutamiento.csv`.
//!
//! Al recibir un mensaje se extrae unicamente `destination`; si no es para este
//! nodo se busca la fila correspondiente, se obtiene la IP y el puerto, y se
//! abre una conexion por sockets para reenviarlo.
//!
//! El paquete se reenvia BYTE POR BYTE tal como llego: `payload` es opaco y
//! `origin`/`destination` son el ATM y el banco, no los routers intermedios.

const std = @import("std");
const lib = @import("../root.zig");
const router_table = @import("../control/router_table.zig");

const network = lib.network;
const proto = lib.proto;

pub const Table = std.StringArrayHashMapUnmanaged(router_table.Hop);

pub const Outcome = enum { delivered, forwarded, dropped };

/// Procesa una linea JSON recibida. `arena` es de vida corta (por conexion).
pub fn route(
    io: std.Io,
    arena: std.mem.Allocator,
    me: []const u8,
    table: Table,
    line: []const u8,
) Outcome {
    const destination = proto.peekDestination(arena, line) catch |err| {
        std.debug.print("datos: paquete ilegible ({}), descartado\n", .{err});
        return .dropped;
    };

    if (std.mem.eql(u8, destination, me)) {
        const msg = network.parse(proto.DataMsg, arena, line) catch {
            std.debug.print("ENTREGADO en {s} (payload no deserializable): {s}\n", .{ me, line });
            return .delivered;
        };
        std.debug.print(
            "ENTREGADO en {s} | type={s} origin={s}\n  payload: {f}\n",
            .{ me, msg.type, msg.origin, std.json.fmt(msg.payload, .{}) },
        );
        return .delivered;
    }

    const hop = table.get(destination) orelse {
        std.debug.print("datos: sin ruta hacia {s}, descartado\n", .{destination});
        return .dropped;
    };

    var stream = network.set_stream(hop.port, hop.host, io) catch |err| {
        std.debug.print("datos: no se pudo conectar al siguiente salto {s}: {}\n", .{ hop.next_hop, err });
        return .dropped;
    };
    defer stream.close(io);

    network.sendRaw(io, &stream, line) catch |err| {
        std.debug.print("datos: fallo reenviando a {s}: {}\n", .{ hop.next_hop, err });
        return .dropped;
    };

    std.debug.print("REENVIADO {s} -> {s} (destino final {s})\n", .{ me, hop.next_hop, destination });
    return .forwarded;
}

/// Inyecta un mensaje ya armado (archivo JSON) en la red desde este nodo.
pub fn inject(
    io: std.Io,
    arena: std.mem.Allocator,
    me: []const u8,
    table: Table,
    json_path: []const u8,
) !void {
    const raw = try lib.util.readFileAlloc(io, arena, json_path);
    const line = std.mem.trim(u8, raw, " \t\r\n");
    // Se valida antes de mandar para no inundar la red con basura.
    _ = try proto.peekDestination(arena, line);
    _ = route(io, arena, me, table, line);
}
