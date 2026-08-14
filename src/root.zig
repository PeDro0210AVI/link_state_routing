pub const std = @import("std");
pub const builtin = @import("builtin");

pub const control = @import("control/root.zig");
pub const data = @import("data/root.zig");
pub const network = @import("network.zig");
pub const proto = @import("proto.zig");
pub const util = @import("util.zig");

pub const PlaneType = enum { Control, Data };

/// Un vecino directo. `id` es el identificador que viaja en el cable
/// ("from"/"origin"/claves de "links"); `host`/`port` son como alcanzarlo.
pub const NodeInfo = struct {
    id: []const u8,
    host: []const u8,
    port: u16,
    /// Identidad que el vecino declara en el `from` de su HELLO. Es la que usa
    /// como `origin` en sus LSAs, asi que es la unica con la que el grafo cierra.
    /// Vacia hasta que responda el primer HELLO; entonces manda sobre `id`.
    announced_id: []const u8 = "",

    /// El nombre con el que este vecino aparece en el grafo.
    pub fn graphId(self: NodeInfo) []const u8 {
        return if (self.announced_id.len > 0) self.announced_id else self.id;
    }
};

test {
    _ = control;
    _ = data;
    _ = network;
    _ = proto;
    _ = util;
}
