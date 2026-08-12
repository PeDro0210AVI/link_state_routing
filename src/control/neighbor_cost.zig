pub const control = @import("root");
pub const network = @import("../root.zig").network;

const std = @import("std");
const net = std.Io.net;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Stream = net.Stream;

fn HelloPackages() type {
    return struct { type: []const u8, from: []const u8 };
}

// returns the node label and it's cost
pub fn send_hello_to_neighbor(raw_node_ip: []const u8, io: std.Io, stream: *Stream, allocator: std.mem.Allocator) !std.StringHashMap(i64) {
    const hello_pkg: HelloPackages = .{ .type = "HELLO", .from = raw_node_ip };

    // for creating the costs
    const start = std.Io.Clock.now(.awake, io);

    try network.sendMessage(io, stream, hello_pkg);

    const node_hello_pkg = try network.recvMessage(io, stream, allocator, HelloPackages());

    const end = std.Io.Clock.now(.awake, io);
    const duration = start.durationTo(end);

    var node_entry = std.StringHashMap(i64).init(allocator);
    try node_entry.put(node_hello_pkg.from, duration.toMilliseconds());

    return node_entry;
}

pub fn find_neighbors_costs(raw_node_ip: []const u8, io: std.Io, streams: ArrayList(*Stream), allocator: std.mem.Allocator) !ArrayList(control.NodeRouter()) {
    var neigbors_costs: ArrayList(control.NodeRouter()) = .{};
    defer neigbors_costs.deinit(allocator);

    for (0..streams.items.len) |stream_idx| {
        try neigbors_costs.append(allocator, send_hello_to_neighbor(raw_node_ip, io, streams[stream_idx], allocator));
    }

    return neigbors_costs;
}
