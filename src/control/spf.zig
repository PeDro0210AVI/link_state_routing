//! Shortest Path First: Dijkstra sobre el grafo reconstruido de la LSDB.

const std = @import("std");
const lsdb = @import("lsdb.zig");

pub const Route = struct {
    dest: []const u8,
    next_hop: []const u8,
    cost: i64,
};

const INF = std.math.maxInt(i64);

/// Rutas mas cortas desde `me`. Los strings apuntan a `graph`, asi que el
/// arena que lo respalda debe seguir vivo mientras se use el resultado.
///
/// ponytail: seleccion O(V^2) en vez de un heap. Con 6 nodos es lo correcto;
/// si la topologia crece a cientos, cambiar a std.PriorityQueue.
pub fn shortestPaths(arena: std.mem.Allocator, graph: lsdb.Graph, me: []const u8) ![]Route {
    // Indice de nodos: origins del grafo mas todo destino mencionado en links.
    var index: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var git = graph.iterator();
    while (git.next()) |kv| {
        _ = try index.getOrPutValue(arena, kv.key_ptr.*, index.count());
        for (kv.value_ptr.keys()) |neighbor| {
            _ = try index.getOrPutValue(arena, neighbor, index.count());
        }
    }
    const me_idx = index.get(me) orelse return arena.alloc(Route, 0);

    const n = index.count();
    const ids = index.keys();

    const dist = try arena.alloc(i64, n);
    const first_hop = try arena.alloc(?usize, n);
    const done = try arena.alloc(bool, n);
    @memset(dist, INF);
    @memset(first_hop, null);
    @memset(done, false);
    dist[me_idx] = 0;

    while (true) {
        // Nodo no visitado con menor distancia.
        var u: ?usize = null;
        for (0..n) |i| {
            if (done[i] or dist[i] == INF) continue;
            if (u == null or dist[i] < dist[u.?]) u = i;
        }
        const cur = u orelse break;
        done[cur] = true;

        const links = graph.get(ids[cur]) orelse continue;
        var lit = links.iterator();
        while (lit.next()) |lkv| {
            const cost = lkv.value_ptr.*;
            if (cost < 0) continue; // enlace invalido: Dijkstra no admite negativos
            const v = index.get(lkv.key_ptr.*) orelse continue;
            if (done[v]) continue;
            const candidate = dist[cur] + cost;
            if (candidate < dist[v]) {
                dist[v] = candidate;
                // El primer salto de v es v mismo si venimos de la raiz;
                // si no, se hereda del predecesor.
                first_hop[v] = if (cur == me_idx) v else first_hop[cur];
            }
        }
    }

    var routes: std.ArrayList(Route) = .empty;
    for (0..n) |i| {
        if (i == me_idx or dist[i] == INF) continue;
        const hop = first_hop[i] orelse continue;
        try routes.append(arena, .{
            .dest = ids[i],
            .next_hop = ids[hop],
            .cost = dist[i],
        });
    }
    return routes.toOwnedSlice(arena);
}

fn testGraph(arena: std.mem.Allocator, edges: []const struct { []const u8, []const u8, i64 }) !lsdb.Graph {
    var g: lsdb.Graph = .empty;
    for (edges) |e| {
        const gop = try g.getOrPut(arena, e[0]);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.put(arena, e[1], e[2]);
    }
    return g;
}

test "Dijkstra prefiere el camino barato sobre el enlace directo caro" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A-B=1, B-C=1, A-C=10  => la ruta a C debe ir por B con costo 2.
    const g = try testGraph(arena, &.{
        .{ "A", "B", 1 }, .{ "B", "A", 1 },
        .{ "B", "C", 1 }, .{ "C", "B", 1 },
        .{ "A", "C", 10 }, .{ "C", "A", 10 },
    });

    const routes = try shortestPaths(arena, g, "A");
    var seen: usize = 0;
    for (routes) |r| {
        if (std.mem.eql(u8, r.dest, "C")) {
            try std.testing.expectEqualStrings("B", r.next_hop);
            try std.testing.expectEqual(@as(i64, 2), r.cost);
            seen += 1;
        }
        if (std.mem.eql(u8, r.dest, "B")) {
            try std.testing.expectEqualStrings("B", r.next_hop);
            try std.testing.expectEqual(@as(i64, 1), r.cost);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "Dijkstra sobre la topologia de 6 nodos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Anillo A-B-C-D-E-F-A con todos los enlaces en costo 1.
    const g = try testGraph(arena, &.{
        .{ "A", "B", 1 }, .{ "B", "A", 1 },
        .{ "B", "C", 1 }, .{ "C", "B", 1 },
        .{ "C", "D", 1 }, .{ "D", "C", 1 },
        .{ "D", "E", 1 }, .{ "E", "D", 1 },
        .{ "E", "F", 1 }, .{ "F", "E", 1 },
        .{ "F", "A", 1 }, .{ "A", "F", 1 },
    });

    const routes = try shortestPaths(arena, g, "A");
    try std.testing.expectEqual(@as(usize, 5), routes.len);
    for (routes) |r| {
        // D esta a 3 saltos por cualquiera de los dos lados del anillo.
        if (std.mem.eql(u8, r.dest, "D")) try std.testing.expectEqual(@as(i64, 3), r.cost);
        if (std.mem.eql(u8, r.dest, "C")) {
            try std.testing.expectEqualStrings("B", r.next_hop);
            try std.testing.expectEqual(@as(i64, 2), r.cost);
        }
        if (std.mem.eql(u8, r.dest, "E")) {
            try std.testing.expectEqualStrings("F", r.next_hop);
            try std.testing.expectEqual(@as(i64, 2), r.cost);
        }
    }
}
