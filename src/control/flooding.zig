//! Flooding de LSAs con la regla de ciclos acordada:
//!   1. ttl <= 0                      -> descartar
//!   2. seq <= el guardado por origin -> descartar, no reenviar
//!   3. si no, ttl -= 1, from = yo, y reenviar a todos los vecinos
//!      EXCEPTO por donde llego (el `from` del paquete recibido).
//! `origin` y `seq` nunca se tocan al reenviar.

const std = @import("std");
const lib = @import("../root.zig");
const Lsdb = @import("lsdb.zig").Lsdb;

const network = lib.network;
const proto = lib.proto;

/// Envia `lsa` a cada vecino, saltandose aquel cuyo id sea `skip_id`.
/// No propaga errores: un vecino caido no debe detener el flooding al resto.
pub fn flood(
    io: std.Io,
    neighbors: []const lib.NodeInfo,
    lsa: proto.Lsa,
    skip_id: ?[]const u8,
) void {
    for (neighbors) |neighbor| {
        if (skip_id) |skip| {
            if (std.mem.eql(u8, neighbor.id, skip)) continue;
        }
        var stream = network.set_stream(neighbor.port, neighbor.host, io) catch |err| {
            std.debug.print("flooding: no se pudo conectar a {s}: {}\n", .{ neighbor.id, err });
            continue;
        };
        defer stream.close(io);
        network.sendMessage(io, &stream, lsa) catch |err| {
            std.debug.print("flooding: fallo enviando a {s}: {}\n", .{ neighbor.id, err });
        };
    }
}

/// Procesa un LSA recibido. Devuelve true si se acepto (y por tanto se
/// reenvio), false si se descarto.
pub fn handleLsa(
    io: std.Io,
    db: *Lsdb,
    me: []const u8,
    neighbors: []const lib.NodeInfo,
    incoming: proto.Lsa,
) !bool {
    if (incoming.ttl <= 0) {
        std.debug.print("LSA de {s} descartado: ttl agotado\n", .{incoming.origin});
        return false;
    }
    // Nuestro propio LSA de vuelta: nada que aprender.
    if (std.mem.eql(u8, incoming.origin, me)) return false;

    if (!try db.insert(incoming.origin, incoming.seq, incoming.links.map)) {
        return false; // seq <= guardado
    }

    std.debug.print(
        "LSA aceptado origin={s} seq={d} ttl={d} via={s}\n",
        .{ incoming.origin, incoming.seq, incoming.ttl, incoming.from },
    );

    var out = incoming;
    out.ttl = incoming.ttl - 1;
    out.from = me;
    flood(io, neighbors, out, incoming.from);
    return true;
}
