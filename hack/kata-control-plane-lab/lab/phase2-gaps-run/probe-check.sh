#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Checks of the probe program podvm-endpoint-ready before it is in an image. The program comes
# through stdin of a shell in the guest, so no file is written into a guest.
#   1. in a control plane guest: 20 runs of the program as it will be in the image (exit code, time)
#   2. the same program with a gate file path that exists (/etc/hostname): exit code 1, no call
#   3. in the worker guest: the program with a target that never answers (a throwaway listener on
#      127.0.0.1) and a kill after 1 s, as the probe timeout does it. No process may be left.
# Usage: probe-check.sh <control plane pod> <worker pod>
set -u
CP=${1:?control plane pod}
WK=${2:?worker pod}
NS=${NS:-d}
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${OUT:-/root/kata-cp/logs/p2gaps/prep}
PORT=47612
mkdir -p "$OUT"
ki() { docker exec -i kata-bb-control-plane timeout 120 kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
k() { docker exec kata-bb-control-plane timeout 120 kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
. "$HERE/image/endpoint-gate.env"
sed "s|@GATE_FILE@|$GATE_FILE|" "$HERE/image/podvm-endpoint-ready.in" >"$OUT/podvm-endpoint-ready"
sed "s|@GATE_FILE@|/etc/hostname|" "$HERE/image/podvm-endpoint-ready.in" >"$OUT/podvm-endpoint-ready.closed"
sed -e "s|@GATE_FILE@|$GATE_FILE|" -e "s|https://127.0.0.1:6443/readyz|http://127.0.0.1:$PORT/|" -e 's|--max-time 2|--max-time 20|' "$HERE/image/podvm-endpoint-ready.in" >"$OUT/podvm-endpoint-ready.hang"
{
  echo "== probe check at $(date -u +%FT%TZ): program of $(wc -c <"$OUT/podvm-endpoint-ready") bytes, gate file $GATE_FILE"
  cat "$OUT/podvm-endpoint-ready"
  echo "== 1. $CP: the gate file exists: $(k -n "$NS" exec "$CP" -- sh -c "[ -e $GATE_FILE ] && echo yes || echo no"). 20 runs"
  { echo 'i=0; while [ $i -lt 20 ]; do i=$((i+1)); t0=$(date +%s%3N); sh -s <<"PROBE"'; cat "$OUT/podvm-endpoint-ready"; echo 'PROBE'; echo 'rc=$?; echo "run $i: exit code $rc, $(( $(date +%s%3N) - t0 )) ms"; done'; } >"$OUT/.probe-loop.sh"
  ki -n "$NS" exec -i "$CP" -- sh -s <"$OUT/.probe-loop.sh" | tee "$OUT/.probe-runs.txt" | awk '{t=$6+0; if (t > max) max=t; sum+=t; n++} END {printf "runs %d, mean %.0f ms, longest %d ms\n", n, sum/n, max}'
  echo "exit codes: $(awk '{print $5}' "$OUT/.probe-runs.txt" | tr -d ',' | sort | uniq -c | tr '\n' ' ')"
  echo "== 2. $CP: the same program with a gate file path that exists"
  ki -n "$NS" exec -i "$CP" -- sh -s <"$OUT/podvm-endpoint-ready.closed"; echo "exit code $? (rule: 1)"
  echo "== 3. $WK: a target that never answers, and a kill after 1 s"
  cat >"$OUT/.hang-listener.py" <<PY
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", $PORT)); s.listen(4); s.settimeout(12)
try:
    c, a = s.accept(); time.sleep(8)
except Exception as e:
    print("listener:", type(e).__name__)
PY
  ki -n "$NS" exec -i "$WK" -- timeout 20 python3 - <"$OUT/.hang-listener.py" &
  LP=$!
  sleep 2
  { echo 'timeout -s KILL 1 sh -s <<"PROBE"'; cat "$OUT/podvm-endpoint-ready.hang"; echo 'PROBE'; echo 'echo "exit code of the killed probe: $? (137 = killed)"'; } >"$OUT/.probe-kill.sh"
  ki -n "$NS" exec -i "$WK" -- sh -s <"$OUT/.probe-kill.sh"
  echo "processes of the probe left in $WK, seen from a new exec: curl $(k -n "$NS" exec "$WK" -- sh -c 'ps -eo args | grep -c "[c]url --silent --fail"'), sh -s $(k -n "$NS" exec "$WK" -- sh -c 'ps -eo args | grep -c "^[s]h -s$"')"
  wait "$LP" 2>/dev/null
  echo "python processes of the test left in $WK: $(k -n "$NS" exec "$WK" -- sh -c 'ps -eo args | grep -c "[p]ython3 -$"')"
} 2>&1 | tee "$OUT/probe-check.txt"
