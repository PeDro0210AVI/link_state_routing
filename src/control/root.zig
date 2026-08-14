const std = @import("std");

pub const neighbor_cost = @import("neighbor_cost.zig");
pub const lsa = @import("lsa.zig");
pub const flooding = @import("flooding.zig");
pub const lsdb = @import("lsdb.zig");
pub const spf = @import("spf.zig");
pub const router_table = @import("router_table.zig");

test {
    // Referencia explicita: sin esto los tests de los submodulos no se compilan.
    _ = neighbor_cost;
    _ = lsa;
    _ = flooding;
    _ = lsdb;
    _ = spf;
    _ = router_table;
}

/// Entrada final de la tabla de ruteo. Ver `router_table.zig` para el CSV.
pub const NodeRouter = struct {
    router_label: []const u8,
    cost: i64,
    next_jump: []const u8,
};
