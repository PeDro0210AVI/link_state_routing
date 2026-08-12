pub const std = @import("std");
pub const builtin = @import("builtin");

pub const control = @import("control/root.zig");
pub const data = @import("control/root.zig");
pub const network = @import("network.zig");
pub const util = @import("util.zig");

pub const PlaneType = enum { Control, Data };

pub fn NodeInfo() type {
    return struct {
        host: []const u8,
        port: usize,
    };
}
