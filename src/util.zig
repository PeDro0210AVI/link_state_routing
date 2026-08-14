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

/// Punto unico de espera. Si el nombre de la API de sleep cambia entre
/// versiones de Zig 0.16, este es el unico lugar a tocar.
pub fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Reloj monotono en milisegundos, para medir el RTT del HELLO.
pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Lee el archivo completo a memoria. Envuelve el patron de `std.Io.Dir` que ya
/// usa el resto del proyecto.
pub fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch break;
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

/// Formato del archivo de vecinos, una linea por vecino. Se aceptan dos formas:
///   `id,host,port`   -- explicita, la que hay que usar sobre Tailscale
///   `host:port`      -- compatible con `data/neighbors_ips.txt`; el id queda
///                       como "host:port", que es lo que distingue nodos
///                       cuando los 6 corren en 127.0.0.1
pub fn parseNeighborLine(allocator: std.mem.Allocator, raw: []const u8) !?lib.NodeInfo {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    if (std.mem.indexOfScalar(u8, trimmed, ',')) |_| {
        var it = std.mem.splitScalar(u8, trimmed, ',');
        const id = std.mem.trim(u8, it.next() orelse return error.InvalidFormat, " \t");
        const host = std.mem.trim(u8, it.next() orelse return error.InvalidFormat, " \t");
        const port_str = std.mem.trim(u8, it.next() orelse return error.InvalidFormat, " \t");
        return .{
            .id = try allocator.dupe(u8, id),
            .host = try allocator.dupe(u8, host),
            .port = std.fmt.parseUnsigned(u16, port_str, 10) catch return error.InvalidPort,
        };
    }

    const colon_pos = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return error.InvalidFormat;
    const host = trimmed[0..colon_pos];
    const port_str = trimmed[colon_pos + 1 ..];
    return .{
        .id = try allocator.dupe(u8, trimmed),
        .host = try allocator.dupe(u8, host),
        .port = std.fmt.parseUnsigned(u16, port_str, 10) catch return error.InvalidPort,
    };
}

pub fn get_neighbors_from_path(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.ArrayList(lib.NodeInfo) {
    var neighbors: std.ArrayList(lib.NodeInfo) = .empty;

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.debug.print("Failed to open file {s}: {}\n", .{ path, err });
        return err;
    };
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;

    while (reader.takeDelimiterInclusive('\n')) |line| {
        if (try parseNeighborLine(allocator, line)) |n| try neighbors.append(allocator, n);
    } else |_| {}

    return neighbors;
}

test "parseNeighborLine acepta host:port y no se come el ultimo digito" {
    const allocator = std.testing.allocator;
    const n = (try parseNeighborLine(allocator, "127.0.0.1:5051")).?;
    defer allocator.free(n.id);
    defer allocator.free(n.host);
    try std.testing.expectEqual(@as(u16, 5051), n.port);
    try std.testing.expectEqualStrings("127.0.0.1", n.host);
    try std.testing.expectEqualStrings("127.0.0.1:5051", n.id);
}

test "parseNeighborLine acepta id,host,port" {
    const allocator = std.testing.allocator;
    const n = (try parseNeighborLine(allocator, "100.64.0.2, 100.64.0.2, 5051\n")).?;
    defer allocator.free(n.id);
    defer allocator.free(n.host);
    try std.testing.expectEqualStrings("100.64.0.2", n.id);
    try std.testing.expectEqual(@as(u16, 5051), n.port);
}

test "parseNeighborLine ignora vacias y comentarios" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try parseNeighborLine(allocator, "   \n") == null);
    try std.testing.expect(try parseNeighborLine(allocator, "# vecino caido\n") == null);
}
