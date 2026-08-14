#!/usr/bin/env bash
# Demo local de los 6 nodos.
#
#   1. Levanta los 6 planos de control; cada uno converge, escribe su
#      nodo_tabla_enrutamiento.csv y termina.
#   2. Levanta los planos de datos de B..F.
#   3. Inyecta un AUTH desde A (5051) hacia D (5054) y sigue los reenvios.
#
# Cada nodo corre en su propio directorio run/<puerto>/ para que el archivo
# conserve el nombre exacto que pide el enunciado.
set -euo pipefail

cd "$(dirname "$0")/.."
PORTS=(5051 5052 5053 5054 5055 5056)
BIN=zig-out/bin/link_state_routing

zig build

rm -rf run
for p in "${PORTS[@]}"; do mkdir -p "run/$p"; done

echo "== 1. Plano de control =="
control_pids=()
for p in "${PORTS[@]}"; do
  "$BIN" \
    --plane_type Control \
    --host 127.0.0.1 --port "$p" \
    --nodes_neighbors_path "data/neighbors_$p.txt" \
    --routing_table_path "run/$p/nodo_tabla_enrutamiento.csv" \
    >"run/$p/control.log" 2>&1 &
  control_pids+=($!)
done
for pid in "${control_pids[@]}"; do wait "$pid"; done

for p in "${PORTS[@]}"; do
  echo "--- tabla del nodo 127.0.0.1:$p ---"
  cat "run/$p/nodo_tabla_enrutamiento.csv"
done

echo
echo "== 2. Plano de datos (5052..5056) =="
data_pids=()
for p in 5052 5053 5054 5055 5056; do
  "$BIN" \
    --plane_type Data \
    --host 127.0.0.1 --port "$p" \
    --nodes_neighbors_path "data/neighbors_$p.txt" \
    --routing_table_path "run/$p/nodo_tabla_enrutamiento.csv" \
    >"run/$p/data.log" 2>&1 &
  data_pids+=($!)
done
sleep 2

echo "== 3. Inyectando AUTH de 5051 hacia 5054 =="
"$BIN" \
  --plane_type Data \
  --host 127.0.0.1 --port 5051 \
  --nodes_neighbors_path data/neighbors_5051.txt \
  --routing_table_path run/5051/nodo_tabla_enrutamiento.csv \
  --send data/msg_auth.json 2>&1 | sed 's/^/[5051] /'

sleep 2
for p in 5052 5053 5054 5055 5056; do
  sed "s/^/[$p] /" "run/$p/data.log" | grep -E 'REENVIADO|ENTREGADO|sin ruta' || true
done

kill "${data_pids[@]}" 2>/dev/null || true
wait 2>/dev/null || true
echo "Listo. Logs completos en run/<puerto>/."
