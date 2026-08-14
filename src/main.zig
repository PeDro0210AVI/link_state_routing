const lib = @import("link_state_routing");
pub const cli = @import("cli");
pub const std = @import("std");
pub const builtin = @import("builtin");

const control = lib.control;
const data = lib.data;
const network = lib.network;
const proto = lib.proto;
const util = lib.util;
const Lsdb = control.lsdb.Lsdb;

var cli_config = struct {
    /// Identificador de este nodo tal como viaja en el cable ("from"/"origin").
    /// Vacio => se usa "host:port", que es lo que distingue los 6 nodos cuando
    /// corren todos en 127.0.0.1. Sobre Tailscale conviene la IP a secas.
    id: []const u8 = "",
    routing_table_path: []const u8 = "data/nodo_tabla_enrutamiento.csv",
    nodes_neighbors_path: []const u8 = "data/neighbors_ips.txt",
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    plane_type: []const u8 = "Control",
    /// Plano de datos: archivo JSON con un paquete a inyectar en la red.
    send: []const u8 = "",
    hello_attempts: u32 = 10,
    hello_retry_ms: u64 = 500,
    lsa_rounds: u32 = 3,
    round_delay_ms: u64 = 1500,
    converge_timeout_ms: u64 = 20000,
    stable_ms: u64 = 2000,
    /// 0 = costo por RTT medido. >0 = costo fijo por enlace.
    link_cost: i64 = 0,
}{};

const Node = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    id: []const u8,
    plane: lib.PlaneType,
    neighbors: []lib.NodeInfo,
    db: *Lsdb,
    table: data.Table,
};

pub fn main(init: std.process.Init) !void {
    var r = cli.AppRunner.init(&init);
    defer r.deinit();
    const app = cli.App{
        .command = cli.Command{
            .name = "node",
            .options = try r.allocOptions(&.{
                .{
                    .long_name = "id",
                    .help = "Node id on the wire (default: host:port)",
                    .value_ref = r.mkRef(&cli_config.id),
                },
                .{
                    .long_name = "routing_table_path",
                    .help = "Path routings references",
                    .value_ref = r.mkRef(&cli_config.routing_table_path),
                },
                .{
                    .long_name = "nodes_neighbors_path",
                    .help = "path with NodeInfo for each neighbor",
                    .value_ref = r.mkRef(&cli_config.nodes_neighbors_path),
                },
                .{
                    .long_name = "host",
                    .help = "Node Host",
                    .value_ref = r.mkRef(&cli_config.host),
                },
                .{
                    .long_name = "port",
                    .help = "Node port",
                    .value_ref = r.mkRef(&cli_config.port),
                },
                .{
                    .long_name = "plane_type",
                    .help = "type of plane the node is working one",
                    .value_ref = r.mkRef(&cli_config.plane_type),
                },
                .{
                    .long_name = "send",
                    .help = "Data plane: JSON file with a packet to inject",
                    .value_ref = r.mkRef(&cli_config.send),
                },
                .{
                    .long_name = "converge_timeout_ms",
                    .help = "Control plane: give up waiting for convergence",
                    .value_ref = r.mkRef(&cli_config.converge_timeout_ms),
                },
                // Espera de los HELLO. Subir los intentos cuando los vecinos
                // arrancan en momentos distintos, como al coordinar con las
                // otras parejas: attempts * retry_ms es la espera maxima por
                // vecino en cada ronda.
                .{
                    .long_name = "hello_attempts",
                    .help = "HELLO retries per neighbor per round (default 10)",
                    .value_ref = r.mkRef(&cli_config.hello_attempts),
                },
                .{
                    .long_name = "hello_retry_ms",
                    .help = "Delay between HELLO retries (default 500)",
                    .value_ref = r.mkRef(&cli_config.hello_retry_ms),
                },
                .{
                    .long_name = "lsa_rounds",
                    .help = "How many times to re-probe and re-flood (default 3)",
                    .value_ref = r.mkRef(&cli_config.lsa_rounds),
                },
                .{
                    .long_name = "round_delay_ms",
                    .help = "Delay between LSA rounds (default 1500)",
                    .value_ref = r.mkRef(&cli_config.round_delay_ms),
                },
                .{
                    .long_name = "stable_ms",
                    .help = "LSDB must be unchanged this long to converge (default 2000)",
                    .value_ref = r.mkRef(&cli_config.stable_ms),
                },
                .{
                    .long_name = "link_cost",
                    .help = "Fixed cost per link; 0 = use measured RTT (default 0)",
                    .value_ref = r.mkRef(&cli_config.link_cost),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = run },
            },
        },
    };
    return r.run(&app);
}

pub fn run() !void {
    // smp_allocator: el hilo servidor y el hilo principal comparten allocator.
    const allocator = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const me = if (cli_config.id.len > 0)
        cli_config.id
    else
        try std.fmt.allocPrint(arena, "{s}:{d}", .{ cli_config.host, cli_config.port });

    const upper_raw_plane_type = try util.allocUpperString(arena, cli_config.plane_type);
    const plane = try util.from_u8_array_in_to_plane_type_enums(upper_raw_plane_type);

    const neighbors = try util.get_neighbors_from_path(io, arena, cli_config.nodes_neighbors_path);

    var db = Lsdb.init(allocator, io);
    defer db.deinit();

    var node = Node{
        .io = io,
        .allocator = allocator,
        .id = me,
        .plane = plane,
        .neighbors = neighbors.items,
        .db = &db,
        .table = .empty,
    };

    if (plane == .Data) {
        node.table = control.router_table.load(io, arena, cli_config.routing_table_path) catch |err| {
            std.debug.print(
                "No se pudo leer {s} ({}). Corre primero el plano de control.\n",
                .{ cli_config.routing_table_path, err },
            );
            return err;
        };
    }

    const address = try std.Io.net.IpAddress.parseIp4(cli_config.host, cli_config.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    // Sin `defer server.deinit(io)`: el hilo servidor esta bloqueado en accept()
    // sobre este socket, y cerrarlo desde aqui lo hace entrar en panic con BADF.
    // El proceso termina con process.exit mas abajo y el SO libera el socket.
    std.debug.print("Nodo {s} escuchando en {s}:{d} ({s})\n", .{
        me, cli_config.host, cli_config.port, @tagName(plane),
    });

    const server_thread = try std.Thread.spawn(.{}, serverLoop, .{ &node, &server });
    server_thread.detach();

    switch (plane) {
        .Control => try runControlPlane(&node),
        .Data => try runDataPlane(&node, arena),
    }

    // Termina sin desenrollar: el hilo servidor sigue detached sobre el socket.
    std.process.exit(0);
}

// ---------------------------------------------------------------- servidor

fn serverLoop(node: *Node, server: *std.Io.net.Server) void {
    while (true) {
        const conn = server.accept(node.io) catch continue;
        // Un hilo por conexion: si no, el flooding de un LSA bloquea los HELLO
        // que estan llegando y los vecinos nos marcan como caidos.
        const t = std.Thread.spawn(.{}, handleConnection, .{ node, conn }) catch {
            handleConnection(node, conn);
            continue;
        };
        t.detach();
    }
}

fn handleConnection(node: *Node, accepted: std.Io.net.Stream) void {
    var stream = accepted;
    defer stream.close(node.io);

    var arena_state = std.heap.ArenaAllocator.init(node.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = network.recvLine(node.io, &stream, arena) catch return;
    const msg_type = proto.peekType(arena, line) catch |err| {
        std.debug.print("paquete sin \"type\" ({}), descartado\n", .{err});
        return;
    };

    if (std.mem.eql(u8, msg_type, proto.HELLO)) {
        // El acuerdo no define paquete de respuesta: devolvemos un HELLO
        // identico para que el emisor pueda medir el RTT.
        network.sendMessage(node.io, &stream, proto.Hello{ .from = node.id }) catch {};
        return;
    }

    if (std.mem.eql(u8, msg_type, proto.LSA)) {
        const incoming = network.parse(proto.Lsa, arena, line) catch |err| {
            std.debug.print("LSA malformado ({}), descartado\n", .{err});
            return;
        };
        _ = control.flooding.handleLsa(node.io, node.db, node.id, node.neighbors, incoming) catch |err| {
            std.debug.print("error procesando LSA: {}\n", .{err});
        };
        return;
    }

    // Cualquier otro type es trafico de datos (AUTH/WITHDRAW/ERROR/LOGOUT).
    if (node.plane == .Data) {
        _ = data.route(node.io, arena, node.id, node.table, line);
    } else {
        std.debug.print("plano de control: se ignora paquete de datos type={s}\n", .{msg_type});
    }
}

// ----------------------------------------------------------- plano control

fn runControlPlane(node: *Node) !void {
    var seq: i64 = 0;

    var round: u32 = 0;
    while (round < cli_config.lsa_rounds) : (round += 1) {
        var links = try control.neighbor_cost.probeAll(
            node.io,
            node.allocator,
            node.id,
            node.neighbors,
            cli_config.hello_attempts,
            cli_config.hello_retry_ms,
            cli_config.link_cost,
        );
        defer {
            for (links.map.keys()) |k| node.allocator.free(k);
            links.map.deinit(node.allocator);
        }

        seq += 1;
        _ = try node.db.insert(node.id, seq, links.map);
        control.flooding.flood(node.io, node.neighbors, control.lsa.build(node.id, seq, links), null);
        std.debug.print("LSA propio seq={d} inundado a {d} vecinos\n", .{ seq, node.neighbors.len });

        // Tabla parcial tras cada ronda: el archivo refleja lo que se sabe
        // hasta ahora en vez de aparecer recien al final.
        writeTable(node, false) catch |err| {
            std.debug.print("no se pudo escribir la tabla parcial: {}\n", .{err});
        };

        util.sleepMs(node.io, cli_config.round_delay_ms);
    }

    // Convergencia: la LSDB deja de moverse durante `stable_ms`.
    const tick: u64 = 250;
    var last_version = node.db.currentVersion();
    var stable: u64 = 0;
    var waited: u64 = 0;
    while (stable < cli_config.stable_ms and waited < cli_config.converge_timeout_ms) {
        util.sleepMs(node.io, tick);
        waited += tick;
        const v = node.db.currentVersion();
        if (v == last_version) {
            stable += tick;
        } else {
            // Llego un LSA nuevo: reescribir con la informacion fresca.
            last_version = v;
            stable = 0;
            writeTable(node, false) catch |err| {
                std.debug.print("no se pudo actualizar la tabla: {}\n", .{err});
            };
        }
    }
    std.debug.print(
        "Convergencia: {d} nodos en la LSDB tras {d} ms\n",
        .{ node.db.originCount(), waited },
    );

    try writeTable(node, true);
}

/// Recalcula Dijkstra sobre la LSDB actual y reescribe el CSV. Se llama varias
/// veces durante la corrida, por eso escribe siempre el archivo completo: nunca
/// queda a medias. Solo la llama el hilo principal, asi que no hay carrera.
fn writeTable(node: *Node, final: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(node.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const graph = try node.db.snapshot(arena);
    const routes = try control.spf.shortestPaths(arena, graph, node.id);
    try control.router_table.write(node.io, cli_config.routing_table_path, routes, node.neighbors);

    if (final) {
        std.debug.print("Tabla escrita en {s}:\n{s}\n", .{ cli_config.routing_table_path, control.router_table.HEADER });
        for (routes) |r| {
            std.debug.print("  {s},{s},{d}\n", .{ r.dest, r.next_hop, r.cost });
        }
    } else {
        std.debug.print("  -> tabla parcial: {d} rutas conocidas\n", .{routes.len});
    }
}

// -------------------------------------------------------------- plano datos

fn runDataPlane(node: *Node, arena: std.mem.Allocator) !void {
    std.debug.print("Tabla cargada: {d} destinos\n", .{node.table.count()});

    if (cli_config.send.len > 0) {
        try data.inject(node.io, arena, node.id, node.table, cli_config.send);
        return;
    }

    // Solo reenvia; el trabajo ocurre en el hilo servidor.
    while (true) util.sleepMs(node.io, 1000);
}
