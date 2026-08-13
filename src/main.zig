const lib = @import("link_state_routing");
pub const cli = @import("cli");
pub const std = @import("std");
pub const builtin = @import("builtin");
pub const ArrayList = std.ArrayList;

var cli_config = struct {
    routing_table_path: []const u8 = "data/routing_table.csv",
    nodes_neighbors_path: []const u8 = "data/neighbors_ips.txt",
    host: []const u8 = "127.0.0.1",
    port: usize = 8080,
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

    var streams = std.ArrayList(std.Io.net.Stream).empty;
    defer streams.deinit(arena);

    var structure_hosts_list = lib.util.get_hosts_from_neighbors_path(io, arena, cli_config.nodes_neighbors_path) catch |err| {
        std.debug.print("Error reading neighbors: {}\n", .{err});
        return;
    };
    defer structure_hosts_list.deinit(arena);
    const structure_hosts = structure_hosts_list.items;

    for (0..structure_hosts.len) |structure_hosts_idx| {
        const host = structure_hosts[structure_hosts_idx].@"0";
        const port = structure_hosts[structure_hosts_idx].@"1";

        std.debug.print("port: {d}, host: {s}\n", .{ port, host });

        try streams.append(arena, lib.network.set_stream(port, host, io) catch {
            std.debug.print("Skipping failed connection to {s}:{d}\n", .{ host, port });
            continue;
        });
    }

    const upper_raw_plane_type = lib.util.allocUpperString(arena, cli_config.plane_type) catch |err| {
        std.debug.print("Error processing plane type: {}\n", .{err});
        return;
    };

    const plane_type = try lib.util.from_u8_array_in_to_plane_type_enums(upper_raw_plane_type);
    switch (plane_type) {
        lib.PlaneType.Control => {
            std.debug.print("Running as Control Plane\n", .{});
        },
        lib.PlaneType.Data => {
            std.debug.print("Running as Data Plane\n", .{});
            while (true) {}
        },
    }
}
