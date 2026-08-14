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

/// Manda un HELLO y espera la respuesta en el mismo socket. Devuelve el RTT en
/// milisegundos, que es el costo del enlace.
pub fn probeNeighbor(
    io: std.Io,
    allocator: std.mem.Allocator,
    me: []const u8,
    neighbor: lib.NodeInfo,
) !i64 {
    // Arena de vida corta: la respuesta se descarta, solo interesa el RTT.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var stream = try network.set_stream(neighbor.port, neighbor.host, io);
    defer stream.close(io);

    const start = lib.util.nowMs(io);
    try network.sendMessage(io, &stream, proto.Hello{ .from = me });
    _ = try network.recvMessage(io, &stream, arena_state.allocator(), proto.Hello);
    const rtt = lib.util.nowMs(io) - start;

    return if (rtt < MIN_COST) MIN_COST else rtt;
}

/// Sondea todos los vecinos y arma el mapa `links` del LSA. Un vecino que no
/// responde tras `attempts` intentos queda fuera del LSA: enlace caido.
pub fn probeAll(
    io: std.Io,
    allocator: std.mem.Allocator,
    me: []const u8,
    neighbors: []const lib.NodeInfo,
    attempts: u32,
    retry_delay_ms: u64,
) !proto.LinkMap {
    var links: proto.LinkMap = .{};
    errdefer links.map.deinit(allocator);

    for (neighbors) |neighbor| {
        var attempt: u32 = 0;
        while (attempt < attempts) : (attempt += 1) {
            if (probeNeighbor(io, allocator, me, neighbor)) |cost| {
                try links.map.put(allocator, try allocator.dupe(u8, neighbor.id), cost);
                std.debug.print("HELLO ok  {s} -> {s} (costo {d} ms)\n", .{ me, neighbor.id, cost });
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
