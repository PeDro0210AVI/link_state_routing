# Lab 3 — Link State Routing

Implementación en Zig del protocolo **Link State** para el laboratorio 3 de Redes (CC3067, UVG).
Cada nodo es un proceso independiente que se comunica por sockets TCP.

## Requisitos

- Zig **0.16** (`minimum_zig_version` en `build.zig.zon`).
- Con Nix: `nix develop` deja `zig`, `zls` y `lldb` en el PATH (`flake.nix`).
- Única dependencia: [`zig-cli`](https://github.com/sam701/zig-cli), que `zig build` baja sola.

```bash
zig build          # compila a zig-out/bin/link_state_routing
zig build test     # pruebas
```

## Arquitectura

Un solo binario, dos planos, seleccionados con `--plane_type`:

- **Control** (`src/control/`): manda HELLO a los vecinos, mide el costo de enlace, construye su
  LSA, lo inunda por *flooding*, arma el grafo de la red, corre Dijkstra y escribe
  `nodo_tabla_enrutamiento.csv`. Al converger, **termina**.
- **Datos** (`src/data/`): lee ese CSV y actúa como capa de red — extrae `destination`, busca la IP
  y el puerto del siguiente salto y abre una conexión por sockets para reenviar el paquete.

El transporte es **una conexión TCP por mensaje**: connect → una línea JSON → close.

## Formato del cable

JSON plano, un objeto por línea, según la *Propuesta de protocolo* acordada entre las 3 parejas.
Los cuatro formatos están en [`src/proto.zig`](src/proto.zig).

```jsonc
// HELLO
{"type":"HELLO","from":"<ip_origen>"}

// LSA
{"type":"LSA","origin":"<ip_creador>","seq":1,"ttl":8,
 "links":{"<ip_vecino>":<costo>},"from":"<ip_emisor_actual>"}

// Datos (ATM <-> servidor bancario)
{"type":"AUTH"|"WITHDRAW"|"ERROR"|"LOGOUT",
 "origin":"<ip_nodo_ATM>","destination":"<ip_nodo_servidor>","payload":{ }}
```

**No se aplica CRC32 ni Hamming en el cable.** Ese código (`src/error_detection/`) es del
laboratorio 2 y se conserva en el repo, pero el acuerdo entre las parejas define JSON plano:
agregarle framing rompería la interoperabilidad.

### Reglas de flooding

1. `ttl <= 0` → descartar.
2. `seq` menor o igual al último guardado para ese `origin` → descartar, no reenviar.
3. Si no: `ttl -= 1`, `from` = este nodo, y reenviar a todos los vecinos **excepto por donde llegó**.
   `origin` y `seq` no se modifican.

## Identidad de nodo

El id es un **string opaco** que viaja en `from` / `origin` / `destination` y en las claves de
`links`. Se controla con `--id`:

- Sobre **Tailscale**: la IP a secas (`--id 100.64.0.7`), tal como dice el enunciado.
- En **local**, los 6 nodos comparten `127.0.0.1`, así que el default es `host:port`
  (`127.0.0.1:5051`). No hay que pasar `--id`.

El CSV guarda `ip` y `puerto` en columnas separadas, así que ambos esquemas funcionan sin tocar
código.

## Archivos

**Vecinos** (`--nodes_neighbors_path`), una línea por vecino directo. Dos formas aceptadas:

```
id,host,puerto          # explícita, recomendada sobre Tailscale
host:puerto             # el id queda como "host:puerto"
```

Las líneas vacías y las que empiezan con `#` se ignoran.

**Tabla de ruteo** (`--routing_table_path`), la escribe el plano de control y la lee el de datos:

```
destino,siguiente_salto,costo,ip,puerto
```

## Uso

```bash
# Plano de control: converge, escribe la tabla y termina
zig-out/bin/link_state_routing \
  --plane_type Control --host 127.0.0.1 --port 5051 \
  --nodes_neighbors_path data/neighbors_5051.txt \
  --routing_table_path nodo_tabla_enrutamiento.csv
```

```bash
# Plano de datos: reenvía lo que llegue
zig-out/bin/link_state_routing \
  --plane_type Data --host 127.0.0.1 --port 5051 \
  --nodes_neighbors_path data/neighbors_5051.txt \
  --routing_table_path nodo_tabla_enrutamiento.csv
```

```bash
# Inyectar un mensaje y salir
zig-out/bin/link_state_routing \
  --plane_type Data --host 127.0.0.1 --port 5051 \
  --routing_table_path nodo_tabla_enrutamiento.csv \
  --send data/msg_auth.json
```

Otras opciones: `--id`, `--converge_timeout_ms`.

## Demo local de 6 nodos

```bash
./scripts/demo.sh
```

Topología de prueba (`data/neighbors_505*.txt`): anillo `A-B-C-D-E-F-A` con la cuerda `B-E`, en los
puertos 5051–5056. El script levanta los 6 planos de control, imprime las 6 tablas, levanta los
planos de datos e inyecta un `AUTH` de 5051 hacia 5054 para seguir los reenvíos salto a salto.
Cada nodo corre en `run/<puerto>/` para que el archivo conserve el nombre exacto del enunciado.

## Costo de enlace

El costo es el **RTT del HELLO en milisegundos**, con piso en 1: en loopback el RTT redondea a 0 y
todas las rutas empatarían, dejando a Dijkstra sin nada que distinguir. La constante está en
`src/control/neighbor_cost.zig` (`MIN_COST`) — es la perilla a mover si las pruebas locales dan
tablas inestables.
