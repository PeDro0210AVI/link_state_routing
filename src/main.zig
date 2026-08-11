const link_state_routing = @import("link_state_routing");
pub const cli = @import("cli");

pub const std = @import("std");
pub const builtin = @import("builtin");

var cli_config = struct {
    routing_table_path: []const u8 = "data/routing_table.csv",
}{};

pub fn main(init: std.process.Init) !void {
    var r = cli.AppRunner.init(&init);
    defer r.deinit();

    const app = cli.App{
        .command = cli.Command{
            .name = "server",
            .options = try r.allocOptions(&.{
                .{
                    .long_name = "routing_table_path",
                    .help = "Routing table of network topology",
                    .value_ref = r.mkRef(&cli_config.routing_table_path),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = run },
            },
        },
    };

    return r.run(&app);
}

fn run() !void {
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
}
