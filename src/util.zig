const lib = @import("root.zig");
pub const std = @import("std");
const eql = @import("std").mem.eql;

pub const PlaneTypeError = error{InvalidOption};

pub fn from_u8_array_in_to_plane_type_enums(raw_plane_type: []const u8) !lib.PlaneType {
    if (eql(u8, raw_plane_type, "CONTROL"))
        return lib.PlaneType.Control;
    if (eql(u8, raw_plane_type, "DATA"))
        return lib.PlaneType.Data;
    return PlaneTypeError.InvalidOption;
}

pub fn allocUpperString(allocator: std.mem.Allocator, ascii_string: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, ascii_string.len);
    return std.ascii.upperString(result, ascii_string);
}

pub fn get_hosts_from_neighbors_path(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.ArrayList(struct { []const u8, u16 }) {
    var hosts = std.ArrayList(struct { []const u8, u16 }).empty;

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.debug.print("Failed to open file {s}: {}\n", .{ path, err });
        return err;
    };
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;

    while (reader.takeDelimiterInclusive('\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        const colon_pos = std.mem.lastIndexOf(u8, trimmed, ":") orelse {
            std.debug.print("Invalid format in line (no colon): {s}\n", .{trimmed});
            return error.InvalidFormat;
        };

        const host = try allocator.dupe(u8, trimmed[0..colon_pos]);

        const port_str = trimmed[colon_pos + 1 .. line.len - 1];
        std.debug.print("host: {s}, port: {s}\n", .{ host, port_str });

        const port = std.fmt.parseUnsigned(u16, port_str, 10) catch |err| {
            std.debug.print("Invalid port number: {s}, error: {}\n", .{ port_str, err });
            return error.InvalidPort;
        };

        try hosts.append(allocator, .{ host, port });
    } else |_| {}

    return hosts;
}
