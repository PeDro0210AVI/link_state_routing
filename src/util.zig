const lib = @import("root.zig");

pub const std = @import("std");

const eql = @import("std").mem.eql;

pub const PlaneTypeError = error{InvalidOption};

pub fn from_u8_array_in_to_plane_type_enums(raw_plane_type: []const u8) !lib.PlaneType {
    if (eql([]const u8, raw_plane_type, "CONTROL"))
        return lib.PlaneType.Control;

    if (eql([]const u8, raw_plane_type, "DATA"))
        return lib.PlaneType.Data;

    return PlaneTypeError.InvalidOption;
}

pub fn allocUpperString(allocator: std.mem.Allocator, ascii_string: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, ascii_string.len);
    return std.ascii.upperString(result, ascii_string);
}

//TODO: parse for the hosts
pub fn get_hosts_from_neighbors_path() [].{ []const u8, usize } {}
