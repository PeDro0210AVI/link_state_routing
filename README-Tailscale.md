# Cómo levantar tu nodo y conectarte con las otras parejas

Guía operativa para la prueba de 6 nodos sobre Tailscale. Compartir esta página con las 3 parejas.

---

## ⚠️ La regla que rompe todo si se ignora

**Cada nodo DEBE pasar `--id` con su IP de Tailscale.**

Sin `--id`, el nodo se anuncia como `127.0.0.1:<puerto>`. Eso rompe la red de dos formas:

1. `127.0.0.1` no es alcanzable desde otra máquina, así que nadie puede rutear hacia vos.
2. Todos los que omitan el flag se anuncian con el **mismo** identificador y se pisan entre sí en la
   base de datos de estado de enlace.

Esto ya pasó en la primera prueba. Un nodo se conectó y mandó:

```
LSA aceptado origin=127.0.0.1:8080 seq=1 ttl=8 via=127.0.0.1:8080
```

El LSA llegó bien, pero es inservible: anuncia una identidad que nadie puede alcanzar. Las tablas
salen vacías o con rutas rotas.

**Correcto:** `--id 100.x.y.z --host 100.x.y.z`

---

## 1. Tailscale

```bash
tailscale up
tailscale ip -4      # tu IP: 100.x.y.z
```

Anotá tu IP y compartila con el grupo. Cada persona es un nodo.

### Nodos del tailnet actual

| IP | Máquina | Usuario |
|---|---|---|
| `100.73.120.71` | macbook-pro-de-javier-2 | JavierBenitez112 |
| `100.121.247.58` | macbook-air-2 | Brariv |
| `100.89.143.106` | pcerda2 | jlope384 |
| `100.122.161.94` | pedropc | pedroruben0210 |

**Puerto acordado: `5051`** para todos. Como cada nodo tiene IP propia, no hay conflicto.

---

## 2. Compilar

```bash
zig build          # requiere Zig 0.16
```

---

## 3. Archivo de vecinos

Creá `vecinos.txt` con **solo tus vecinos directos** según la topología acordada — no todo el
tailnet. Una línea por vecino, formato `id,host,puerto`:

```
100.122.161.94,100.122.161.94,5051
100.89.143.106,100.89.143.106,5051
```

Las líneas vacías y las que empiezan con `#` se ignoran, así que podés comentar un vecino para
simular que su enlace se cayó.

---

## 4. Levantar el plano de control

Los 6 corren esto **al mismo tiempo** (coordinar por chat: "arrancamos en 1 minuto").

```bash
zig-out/bin/link_state_routing \
  --plane_type Control \
  --id   100.x.y.z \
  --host 100.x.y.z \
  --port 5051 \
  --nodes_neighbors_path vecinos.txt \
  --routing_table_path nodo_tabla_enrutamiento.csv \
  --hello_attempts 600 --hello_retry_ms 500 \
  --lsa_rounds 3 --round_delay_ms 2000 --stable_ms 5000
```

`--hello_attempts 600` × `--hello_retry_ms 500` = espera hasta **5 minutos** por vecino en cada
ronda. Sin eso el default se rinde a los ~50 segundos y no da tiempo a que todos arranquen.

Cuando converge escribe la tabla y **termina**. Deberías ver:

```
Convergencia: 6 nodos en la LSDB tras ... ms
Tabla escrita en nodo_tabla_enrutamiento.csv
```

Si dice menos de 6 nodos, alguien no llegó: revisar la sección de diagnóstico.

---

## 5. Levantar el plano de datos

Ya con la tabla escrita, los 6 corren:

```bash
zig-out/bin/link_state_routing \
  --plane_type Data \
  --id   100.x.y.z \
  --host 100.x.y.z \
  --port 5051 \
  --routing_table_path nodo_tabla_enrutamiento.csv
```

Este **queda escuchando** hasta que lo cortes con Ctrl-C.

### Mandar un mensaje

`msg.json`, con IPs de Tailscale en `origin` y `destination`:

```json
{"type":"AUTH","origin":"100.73.120.71","destination":"100.122.161.94","payload":{"user":"jb","pin":"1234"}}
```

En otra terminal:

```bash
zig-out/bin/link_state_routing \
  --plane_type Data --id 100.x.y.z --host 100.x.y.z --port 5052 \
  --routing_table_path nodo_tabla_enrutamiento.csv \
  --send msg.json
```

> Usá un puerto distinto (`5052`) para el inyector: tu plano de datos ya tiene tomado el 5051.

Los tipos válidos son `AUTH`, `WITHDRAW`, `ERROR` y `LOGOUT`, según lo acordado.

---

## 6. Flujo del programa

Qué hace el binario desde que arranca hasta que entrega un mensaje. Sirve para leer los logs
durante la corrida en grupo.

### 6.1 Arranque (común a los dos planos)

```
main()
 └─ parsear flags
 └─ id = --id  (si viene vacío: "host:puerto")
 └─ leer vecinos.txt  ->  [{id, host, puerto}, ...]
 └─ crear LSDB vacía (protegida por mutex)
 └─ bind + listen en host:puerto
 └─ lanzar HILO SERVIDOR  ────────────┐
 └─ según --plane_type:               │  corre en paralelo
      Control -> runControlPlane()    │  todo el tiempo
      Data    -> runDataPlane()       │
```

El log `Nodo <id> escuchando en <host>:<puerto> (Control)` confirma este punto.

### 6.2 Hilo servidor (siempre activo)

Acepta conexiones y **lanza un hilo por cada una**. Sin eso, inundar un LSA bloquearía los HELLO
entrantes y los vecinos te marcarían como caído.

```
accept()  ->  hilo nuevo
   └─ leer UNA línea JSON
   └─ mirar el campo "type"
        "HELLO" -> responder {"type":"HELLO","from":<mi id>}   (deja medir el RTT)
        "LSA"   -> manejarLsa()                                 (ver 6.4)
        otro    -> plano de datos: rutear (ver 6.6)
   └─ cerrar
```

Cada mensaje es **una conexión TCP independiente**: connect, una línea, close.

### 6.3 Plano de control: rondas

Se repite `--lsa_rounds` veces (3 por defecto):

```
1. SONDEAR VECINOS  (neighbor_cost.zig)
   por cada vecino:
      connect -> {"type":"HELLO","from":<yo>} -> esperar respuesta -> close
      costo = RTT en ms  (mínimo 1)
      si no responde tras --hello_attempts: se OMITE del LSA (enlace caído)
   resultado: links = {"<ip_vecino>": costo, ...}

2. CONSTRUIR EL LSA PROPIO  (lsa.zig)
   seq++                                    <- nunca se reinicia
   {"type":"LSA","origin":<yo>,"seq":N,"ttl":8,"links":{...},"from":<yo>}

3. GUARDARLO EN LA LSDB PROPIA

4. INUNDARLO a todos los vecinos            <- log: "LSA propio seq=N inundado"

5. esperar --round_delay_ms
```

Se repite porque los vecinos arrancan en momentos distintos: cada ronda vuelve a medir y a
anunciar, así los que llegaron tarde igual se enteran.

### 6.4 Recepción de un LSA ajeno (flooding)

Ocurre en el hilo servidor, en paralelo con las rondas:

```
llega un LSA
 ├─ ttl <= 0 ?                        -> DESCARTAR
 ├─ origin == yo ?                    -> ignorar (es mi propio LSA de vuelta)
 ├─ seq <= el guardado para ese origin?-> DESCARTAR y NO reenviar   <- corta los ciclos
 └─ si no:
      guardar en la LSDB   (version++  -> alimenta la convergencia)
      ttl = ttl - 1
      from = yo                        <- origin y seq NO se tocan
      reenviar a todos los vecinos MENOS aquel de quien vino
```

Log: `LSA aceptado origin=X seq=N ttl=T via=Y`. Si `origin` ≠ `via`, ese LSA fue **retransmitido**:
es la prueba de que el flooding funciona.

### 6.5 Convergencia, Dijkstra y tabla

```
esperar hasta que la LSDB no cambie por --stable_ms
     (o hasta agotar --converge_timeout_ms)
  -> log: "Convergencia: N nodos en la LSDB tras M ms"

reconstruir el GRAFO desde la LSDB
     cada LSA aporta las aristas de su origin

DIJKSTRA desde mi id  (spf.zig)
     por cada destino: costo mínimo + PRIMER SALTO
     el primer salto se hereda: si vengo de la raíz, soy yo; si no, el del predecesor

ESCRIBIR nodo_tabla_enrutamiento.csv
     destino,siguiente_salto,costo,ip,puerto
     ip y puerto salen del archivo de vecinos: el primer salto
     siempre es un vecino directo

TERMINAR el proceso
```

El proceso sale sin desenrollar, a propósito: el hilo servidor sigue bloqueado en `accept()` sobre
el socket y cerrarlo desde el hilo principal lo hacía entrar en panic.

### 6.6 Plano de datos

```
cargar nodo_tabla_enrutamiento.csv  ->  destino -> {siguiente_salto, ip, puerto}

llega un mensaje:
 ├─ leer SOLO el campo "destination"      <- el payload no se toca ni se deserializa
 ├─ destination == yo ?
 │     SÍ  -> ENTREGADO: imprimir type, origin y payload
 │     NO  -> buscar el destino en la tabla
 │            ├─ sin ruta -> descartar con log
 │            └─ con ruta -> connect a su ip:puerto
 │                           reenviar la línea BYTE POR BYTE
 │                           close                  <- log: "REENVIADO"
```

`origin` y `destination` nunca se modifican: identifican al ATM y al banco, no a los routers
intermedios. Con `--send` el nodo inyecta un mensaje por este mismo camino y termina.

### 6.7 El recorrido completo, de punta a punta

```
   [Control]  HELLO ─> vecinos ─> costos ─> LSA ─> flooding ─> LSDB
                                                                │
                                                            Dijkstra
                                                                │
                                                nodo_tabla_enrutamiento.csv
                                                                │
   [Datos]    mensaje ─> leer "destination" ─> buscar en la tabla ─> reenviar
                                                                │
                                                          ENTREGADO
```

---

## 7. Diagnóstico

Correr **en este orden**. El primero que falle es la causa.

```bash
tailscale status                  # ¿el peer aparece y está online?
tailscale ping 100.x.y.z          # ¿hay ruta? deberías ver "pong"
nc -z -G 3 100.x.y.z 5051         # ¿su nodo está escuchando?
```

| Síntoma | Causa | Qué hacer |
|---|---|---|
| `tailscale ping` no responde | El peer no tiene Tailscale arriba | Que corra `tailscale up` |
| `nc` da cerrado | Su nodo no está corriendo, o usa otro puerto | Que levante el suyo en 5051 |
| `HELLO sin respuesta ... enlace caido` | No pudiste alcanzarlo en toda la ronda | Ver las dos filas de arriba |
| `LSA aceptado origin=127.0.0.1:...` | **Ese nodo olvidó `--id`** | Que lo relance con su IP de Tailscale |
| `Convergencia: N nodos` con N < 6 | Alguien no llegó a tiempo | Relanzar todos coordinados |
| Tabla escrita pero vacía | Ningún vecino respondió | Diagnóstico desde el principio |

### Firewall

En **macOS**, la primera conexión entrante puede abrir un diálogo *"¿Permitir conexiones
entrantes?"* → **Permitir**. En **Windows**, el Firewall de Windows suele pedir confirmación al
primer `listen`: permitir en redes privadas. En **Linux**, si hay `ufw` activo:

```bash
sudo ufw allow in on tailscale0 to any port 5051 proto tcp
```

### Verificar que estás escuchando

```bash
lsof -nP -iTCP:5051 -sTCP:LISTEN     # macOS / Linux
```

Debe mostrar tu IP de Tailscale, no `127.0.0.1`:

```
TCP 100.73.120.71:5051 (LISTEN)
```

---

## 8. Resumen de flags

| Flag | Para qué | Default |
|---|---|---|
| `--id` | Identidad en el protocolo. **Siempre tu IP de Tailscale** | `host:puerto` |
| `--host` | Dirección de bind. Tu IP de Tailscale limita el acceso al tailnet | `127.0.0.1` |
| `--port` | Puerto de escucha | `8080` |
| `--plane_type` | `Control` o `Data` | `Control` |
| `--nodes_neighbors_path` | Archivo de vecinos directos | `data/neighbors_ips.txt` |
| `--routing_table_path` | Dónde escribir/leer la tabla | `data/nodo_tabla_enrutamiento.csv` |
| `--send` | Plano de datos: JSON a inyectar | — |
| `--hello_attempts` | Reintentos de HELLO por vecino por ronda | `10` |
| `--hello_retry_ms` | Espera entre reintentos | `500` |
| `--lsa_rounds` | Cuántas veces re-sondear e inundar | `3` |
| `--round_delay_ms` | Espera entre rondas | `1500` |
| `--stable_ms` | Cuánto debe estar quieta la LSDB para converger | `2000` |
| `--converge_timeout_ms` | Techo total de espera | `20000` |

---

## 9. Cosas que conviene saber de antemano

- **El plano de control termina al converger.** No reconverge solo. Si alguien se cae o cambia la
  topología, hay que volver a correrlo en **todos** los nodos y regenerar las tablas.
- **Los costos son el RTT del HELLO en milisegundos.** Sobre Tailscale son reales (a `pedropc` se
  midieron ~80–99 ms), así que las tablas serán asimétricas: cada quien ve costos distintos. Eso es
  correcto y esperado.
- **Un enlace vía DERP es más lento que uno directo.** Si `tailscale status` dice `relay` en vez de
  `direct`, ese enlace va a tener costo más alto y las rutas van a esquivarlo.
- **El plano de datos no modifica los mensajes.** Los routers intermedios reenvían el JSON byte por
  byte: `origin` y `destination` siguen siendo el ATM y el banco, nunca los saltos intermedios.
