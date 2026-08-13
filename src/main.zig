const lib = @import("link_state_routing");
pub const cli = @import("cli");
pub const std = @import("std");
pub const builtin = @import("builtin");
pub const ArrayList = std.ArrayList;

var cli_config = struct {
    routing_table_path: []const u8 = "data/routing_table.csv",
    nodes_neighbors_path: []const u8 = "data/neighbors_ips.txt",
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    plane_type: []const u8 = "Control",
}{};

pub fn main(init: std.process.Init) !void {
    var r = cli.AppRunner.init(&init);
    defer r.deinit();
    const app = cli.App{
        .command = cli.Command{
            .name = "node",
            .options = try r.allocOptions(&.{ .{
                .long_name = "routing_table_path",
                .help = "Path routings references",
                .value_ref = r.mkRef(&cli_config.routing_table_path),
            }, .{
                .long_name = "nodes_neighbors_path",
                .help = "path with NodeInfo for each neighbor",
                .value_ref = r.mkRef(&cli_config.nodes_neighbors_path),
            }, .{
                .long_name = "host",
                .help = "Node Host",
                .value_ref = r.mkRef(&cli_config.host),
            }, .{
                .long_name = "port",
                .help = "Node port",
                .value_ref = r.mkRef(&cli_config.port),
            }, .{
                .long_name = "plane_type",
                .help = "type of plane the node is working one",
                .value_ref = r.mkRef(&cli_config.plane_type),
            } }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = run },
            },
        },
    };
    return r.run(&app);
}

pub fn run() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer switch (builtin.mode) {
        .Debug => std.debug.assert(debug_allocator.deinit() == .ok),
        .ReleaseFast, .ReleaseSmall, .ReleaseSafe => {},
    };
    const allocator = switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall, .ReleaseSafe => std.heap.smp_allocator,
    };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Setup server
    const loopback = try std.Io.net.IpAddress.parseIp4(cli_config.host, cli_config.port);
    var server = try loopback.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print("Node listening on {s}:{d}\n", .{ cli_config.host, cli_config.port });
    // Spawn server thread
    _ = try std.Thread.spawn(.{}, serverLoop, .{ &server, io });
    // Connect to neighbors with timeout
    var streams = std.ArrayList(std.Io.net.Stream).empty;
    defer streams.deinit(arena);
    const structure_hosts_list = try lib.util.get_hosts_from_neighbors_path(io, arena, cli_config.nodes_neighbors_path);
    for (structure_hosts_list.items, 0..) |host_info, idx| {
        const host = host_info.@"0";
        const port = host_info.@"1";
        const thread = try std.Thread.spawn(.{}, connectWithTimeout, .{ host, port, io, arena, &streams, idx + 1 });
        thread.join();
    }
    std.debug.print("Connected to {d}/{d} neighbors\n", .{ streams.items.len, structure_hosts_list.items.len });
    // Parse plane type
    const upper_raw_plane_type = try lib.util.allocUpperString(arena, cli_config.plane_type);
    const plane_type = try lib.util.from_u8_array_in_to_plane_type_enums(upper_raw_plane_type);
    // Run based on plane type
    switch (plane_type) {
        lib.PlaneType.Control => {
            std.debug.print("Running as Control Plane\n", .{});
            // TODO: Build router with LSA
            //try lib.router.buildRouter(arena, structure_hosts_list.items, &streams);
            while (true) {
                // Control plane loop
            }
        },
        lib.PlaneType.Data => {
            std.debug.print("Running as Data Plane\n", .{});
            while (true) {
                // Data plane loop
            }
        },
    }
}

fn serverLoop(server: *std.Io.net.Server, io: std.Io) void {
    std.debug.print("Server accepting connections...\n", .{});
    while (true) {
        const connection = server.accept(io) catch continue;
        defer connection.close(io);
        std.debug.print("Accepted connection from neighbor\n", .{});
    }
}

fn connectWithTimeout(host: []const u8, port: u16, io: std.Io, allocator: std.mem.Allocator, streams: *std.ArrayList(std.Io.net.Stream), neighbor_id: usize) void {
    std.debug.print("Connecting to neighbor {d}: {s}:{d} (timeout: 20s)\n", .{ neighbor_id, host, port });

    const max_attempts = 40; // 40 attempts
    var attempt: u32 = 0;

    while (attempt < max_attempts) {
        attempt += 1;

        if (lib.network.set_stream(port, host, io)) |stream| {
            std.debug.print("✓ Connected to neighbor {d} on attempt {d}\n", .{ neighbor_id, attempt });
            streams.append(allocator, stream) catch return;
            return;
        } else |_| {
            // Busy loop delay (no sleep available in Zig 0.16)
            var i: u32 = 0;
            while (i < 10000000) : (i += 1) {}
        }
    }

    std.debug.print("✗ Failed to connect to neighbor {d} after {d} attempts\n", .{ neighbor_id, max_attempts });
}
