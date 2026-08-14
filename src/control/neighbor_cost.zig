//! Descubrimiento de vecinos y costo de enlace via HELLO.
//!
//! El acuerdo define solo `{"type":"HELLO","from":"<ip_origen>"}` y dice que un
//! vecino que no responde en un tiempo X se considera caido. No fija el paquete
//! de respuesta, asi que respondemos un HELLO identico: no inventa campos.

const std = @import("std");
const lib = @import("../root.zig");

const network = lib.network;
const proto = lib.proto;

/// Costo minimo. En loopback el RTT redondea a 0 ms y entonces todas las rutas
/// empatan en 0 y Dijkstra deja de distinguirlas. El piso en 1 es la perilla de
/// calibracion para pruebas locales.
pub const MIN_COST: i64 = 1;

pub const Probe = struct {
    rtt: i64,
    /// El `from` que devolvio el vecino: su identidad real en el protocolo.
    /// Duplicado con el allocator del llamador.
    announced_id: []const u8,
};

/// Manda un HELLO y espera la respuesta en el mismo socket. Devuelve el RTT y
/// la identidad que el vecino declara.
pub fn probeNeighbor(
    io: std.Io,
    allocator: std.mem.Allocator,
    me: []const u8,
    neighbor: lib.NodeInfo,
) !Probe {
    // Arena de vida corta para el parse; lo que sobrevive se duplica al final.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var stream = try network.set_stream(neighbor.port, neighbor.host, io);
    defer stream.close(io);

    const start = lib.util.nowMs(io);
    try network.sendMessage(io, &stream, proto.Hello{ .from = me });
    const reply = try network.recvMessage(io, &stream, arena_state.allocator(), proto.Hello);
    const rtt = lib.util.nowMs(io) - start;

    return .{
        .rtt = if (rtt < MIN_COST) MIN_COST else rtt,
        .announced_id = try allocator.dupe(u8, reply.from),
    };
}

/// Sondea todos los vecinos y arma el mapa `links` del LSA. Un vecino que no
/// responde tras `attempts` intentos queda fuera del LSA: enlace caido.
pub fn probeAll(
    io: std.Io,
    allocator: std.mem.Allocator,
    me: []const u8,
    /// Mutable: al responder el HELLO se le graba al vecino su `announced_id`.
    neighbors: []lib.NodeInfo,
    attempts: u32,
    retry_delay_ms: u64,
    /// 0 => usar el RTT medido. >0 => costo fijo para todo enlace que responda.
    /// El enlace igual debe contestar el HELLO: uno caido sigue quedando fuera.
    fixed_cost: i64,
) !proto.LinkMap {
    var links: proto.LinkMap = .{};
    errdefer links.map.deinit(allocator);

    for (neighbors) |*neighbor| {
        var attempt: u32 = 0;
        while (attempt < attempts) : (attempt += 1) {
            if (probeNeighbor(io, allocator, me, neighbor.*)) |probe| {
                const cost = if (fixed_cost > 0) fixed_cost else probe.rtt;

                // El grafo se arma con la identidad que el vecino declara: es la
                // que usa como `origin` en sus LSAs. Si usaramos la de nuestro
                // archivo, su LSA quedaria archivado bajo otro nombre y el grafo
                // se partiria en dos, dejandonos sin rutas mas alla del vecino.
                if (probe.announced_id.len > 0) {
                    if (!std.mem.eql(u8, probe.announced_id, neighbor.id)) {
                        std.debug.print(
                            "AVISO: {s} esta configurado como \"{s}\" pero se anuncia como \"{s}\".\n" ++
                                "       Se usara el anunciado. Si es 127.0.0.1, ese vecino olvido --id\n" ++
                                "       y nadie podra rutear hacia el.\n",
                            .{ neighbor.host, neighbor.id, probe.announced_id },
                        );
                    }
                    neighbor.announced_id = probe.announced_id;
                }

                try links.map.put(allocator, try allocator.dupe(u8, neighbor.graphId()), @floatFromInt(cost));
                std.debug.print(
                    "HELLO ok  {s} -> {s} (costo {d}, rtt {d} ms)\n",
                    .{ me, neighbor.graphId(), cost, probe.rtt },
                );
                break;
            } else |err| {
                if (attempt + 1 == attempts) {
                    std.debug.print(
                        "HELLO sin respuesta de {s} tras {d} intentos ({}): enlace caido\n",
                        .{ neighbor.id, attempts, err },
                    );
                } else {
                    lib.util.sleepMs(io, retry_delay_ms);
                }
            }
        }
    }
    return links;
}
