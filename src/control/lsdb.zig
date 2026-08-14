//! Base de datos de estado de enlace.
//!
//! Regla de ciclos del acuerdo: se guarda el ultimo "seq" por cada "origin";
//! un LSA con seq menor o igual al guardado se descarta y no se reenvia.

const std = @import("std");

pub const Links = std.StringArrayHashMapUnmanaged(i64);
pub const Graph = std.StringArrayHashMapUnmanaged(Links);

pub const Entry = struct {
    seq: i64,
    links: Links,
};

pub const Lsdb = struct {
    allocator: std.mem.Allocator,
    /// En Zig 0.16 el mutex vive en std.Io y necesita el `io` en cada
    /// lock/unlock, por eso se guarda aqui.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// Se incrementa con cada cambio aceptado. El plano de control detecta
    /// convergencia observando que deje de moverse.
    version: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Lsdb {
        return .{ .allocator = allocator, .io = io };
    }

    fn lock(self: *Lsdb) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Lsdb) void {
        self.mutex.unlock(self.io);
    }

    pub fn deinit(self: *Lsdb) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            freeLinks(self.allocator, &kv.value_ptr.links);
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    fn freeLinks(allocator: std.mem.Allocator, links: *Links) void {
        for (links.keys()) |k| allocator.free(k);
        links.deinit(allocator);
    }

    /// Devuelve true solo si el LSA es mas nuevo que el guardado, es decir,
    /// solo si hay que reenviarlo. Copia las llaves: el buffer del parse es
    /// de vida corta.
    pub fn insert(self: *Lsdb, origin: []const u8, seq: i64, links: anytype) !bool {
        self.lock();
        defer self.unlock();

        if (self.entries.get(origin)) |existing| {
            if (seq <= existing.seq) return false;
        }

        var copy: Links = .empty;
        errdefer freeLinks(self.allocator, &copy);
        var it = links.iterator();
        while (it.next()) |kv| {
            // El cable puede traer el costo como flotante; adentro se trabaja
            // con enteros. Se redondea con piso 1 para no crear aristas de
            // costo 0, que dejarian a Dijkstra sin poder distinguir rutas.
            const raw = kv.value_ptr.*;
            const cost: i64 = switch (@typeInfo(@TypeOf(raw))) {
                .float => blk: {
                    const r = @round(raw);
                    break :blk if (r < 1) 1 else @as(i64, @intFromFloat(r));
                },
                else => raw,
            };
            try copy.put(self.allocator, try self.allocator.dupe(u8, kv.key_ptr.*), cost);
        }

        const gop = try self.entries.getOrPut(self.allocator, origin);
        if (gop.found_existing) {
            freeLinks(self.allocator, &gop.value_ptr.links);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, origin);
        }
        gop.value_ptr.* = .{ .seq = seq, .links = copy };
        self.version += 1;
        return true;
    }

    pub fn currentVersion(self: *Lsdb) u64 {
        self.lock();
        defer self.unlock();
        return self.version;
    }

    pub fn originCount(self: *Lsdb) usize {
        self.lock();
        defer self.unlock();
        return self.entries.count();
    }

    /// Copia profunda del grafo en `arena`, para correr Dijkstra sin sostener
    /// el lock. Con 6 nodos el costo de copiar es irrelevante.
    pub fn snapshot(self: *Lsdb, arena: std.mem.Allocator) !Graph {
        self.lock();
        defer self.unlock();

        var graph: Graph = .empty;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            var links: Links = .empty;
            var lit = kv.value_ptr.links.iterator();
            while (lit.next()) |lkv| {
                try links.put(arena, try arena.dupe(u8, lkv.key_ptr.*), lkv.value_ptr.*);
            }
            try graph.put(arena, try arena.dupe(u8, kv.key_ptr.*), links);
        }
        return graph;
    }
};

test "insert acepta seq mayor y rechaza menor o igual" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var db = Lsdb.init(allocator, threaded.io());
    defer db.deinit();

    var links: Links = .empty;
    defer links.deinit(allocator);
    try links.put(allocator, "10.0.0.2", 5);

    try std.testing.expect(try db.insert("10.0.0.1", 1, links));
    try std.testing.expect(!try db.insert("10.0.0.1", 1, links)); // igual -> descartar
    try std.testing.expect(!try db.insert("10.0.0.1", 0, links)); // menor -> descartar
    try std.testing.expect(try db.insert("10.0.0.1", 2, links)); // mayor -> aceptar
    try std.testing.expectEqual(@as(usize, 1), db.originCount());
}
