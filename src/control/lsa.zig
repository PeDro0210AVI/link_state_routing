//! Construccion del LSA propio.

const std = @import("std");
const lib = @import("../root.zig");

const proto = lib.proto;

/// TTL inicial. Con 6 nodos, 8 saltos sobra; el dedup por `seq` es la defensa
/// principal contra ciclos y el TTL es el cinturon de seguridad del acuerdo.
pub const DEFAULT_TTL: i32 = 8;

pub fn build(me: []const u8, seq: i64, links: proto.LinkMap) proto.Lsa {
    return .{
        .origin = me,
        .seq = seq,
        .ttl = DEFAULT_TTL,
        .links = links,
        .from = me, // primer emisor: yo mismo
    };
}
