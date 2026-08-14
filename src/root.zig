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
};

test {
    _ = control;
    _ = data;
    _ = network;
    _ = proto;
    _ = util;
}
