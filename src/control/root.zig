const std = @import("std");

const ArrayList = std.ArrayList;

pub const neightbor_cost = @import("neighbor_cost.zig");
pub const lsa = @import("lsa.zig");
pub const flooding = @import("flooding.zig");
pub const lsdb = @import("lsdb.zig");
pub const spf = @import("spf.zig");
pub const router_lab = @import("router_table.zig");

// the final structure for each entry in the route table
pub fn NodeRouter() type {
    return struct { router_label: []const u8, costs: i96, next_jump: []const u8, path: std.SinglyLinkedList([]const u8) };
}
