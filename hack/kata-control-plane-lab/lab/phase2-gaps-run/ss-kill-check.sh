#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Check of the guest kernel: can "ss -K" close one established socket in a guest?
# A throwaway listener on a high port in one guest, a curl client in a kind node of another host
# node, then "ss -K" on that one socket, in the form that the NVKE agent uses. The client must see
# a reset. No socket of the cluster is touched: each filter names the test port.
# Nothing is written into the guest: the listener program comes through stdin.
# Usage: ss-kill-check.sh <guest pod> <client kind node> [port] [label]
set -u
POD=${1:?guest pod}
CLIENT=${2:?client kind node}
PORT=${3:-47611}
LABEL=${4:-check}
NS=${NS:-d}
OUT=${OUT:-/root/kata-cp/logs/p2gaps/prep}
mkdir -p "$OUT"
k() { docker exec kata-bb-control-plane timeout 90 kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
ki() { docker exec -i kata-bb-control-plane timeout 90 kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
g() { k -n "$NS" exec "$POD" -- "$@"; }
IP=$(k -n "$NS" get pod "$POD" -o jsonpath='{.status.podIP}')
cat >"$OUT/listener.py" <<PY
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", $PORT))
s.listen(4)
s.settimeout(30)
print("listener: listening on port $PORT", flush=True)
try:
    c, a = s.accept()
    print("listener: accepted a connection from %s:%d at %s" % (a[0], a[1], time.strftime("%H:%M:%S", time.gmtime())), flush=True)
    c.settimeout(25)
    while True:
        d = c.recv(4096)
        if not d:
            print("listener: the client closed the connection at %s" % time.strftime("%H:%M:%S", time.gmtime()), flush=True)
            break
        print("listener: got %d bytes" % len(d), flush=True)
except Exception as e:
    print("listener: %s %s at %s" % (type(e).__name__, e, time.strftime("%H:%M:%S", time.gmtime())), flush=True)
PY
{
  echo "== $LABEL: guest $POD (address on eth0 $IP), client in the kind node $CLIENT, port $PORT, at $(date -u +%FT%TZ)"
  echo "kernel of the guest: $(g uname -r) built $(g uname -v)"
  echo "port $PORT before the test: [$(g ss -Hltn "sport = :$PORT" 2>&1)]"
  ki -n "$NS" exec -i "$POD" -- timeout 60 python3 - <"$OUT/listener.py" >"$OUT/$LABEL-listener.out" 2>&1 &
  LPID=$!
  sleep 3
  echo "listening socket: [$(g ss -Hltn "sport = :$PORT" 2>&1)]"
  ( docker exec "$CLIENT" curl -sS --max-time 20 -o /dev/null -w 'client: curl got HTTP code %{http_code} after %{time_total} s\n' "http://$IP:$PORT/" >"$OUT/$LABEL-client.out" 2>&1; echo "client: curl exit code $? at $(date -u +%T)" >>"$OUT/$LABEL-client.out" ) &
  CPID=$!
  sleep 3
  echo "established sockets on the test port (the list form of the agent):"
  g ss -Htan state established src "$IP" sport = ":$PORT" 2>&1 | tee "$OUT/$LABEL-list-before.out"
  PEER=$(awk 'NR==1 {print $NF}' "$OUT/$LABEL-list-before.out")
  PEER_IP=${PEER%:*}
  PEER_PORT=${PEER##*:}
  echo "peer: $PEER_IP port $PEER_PORT"
  echo "ss -K at $(date -u +%T): ss -Ktan state established src $IP sport = :$PORT dst $PEER_IP dport = :$PEER_PORT"
  g ss -Ktan state established src "$IP" sport = ":$PORT" dst "$PEER_IP" dport = ":$PEER_PORT" 2>&1 | sed 's/^/  ss: /'
  echo "exit code of ss -K: ${PIPESTATUS[0]}"
  sleep 2
  echo "established sockets on the test port after ss -K: [$(g ss -Htan state established src "$IP" sport = ":$PORT" 2>&1)]"
  wait "$CPID" 2>/dev/null
  wait "$LPID" 2>/dev/null
  cat "$OUT/$LABEL-listener.out"
  cat "$OUT/$LABEL-client.out"
  echo "port $PORT after the test: [$(g ss -Hltn "sport = :$PORT" 2>&1)]"
  echo "python or timeout processes of the test that are left in the guest: $(g sh -c 'ps -eo args | grep -c "[p]ython3 -$"')"
  if grep -q -i 'reset by peer' "$OUT/$LABEL-client.out"; then echo "RESULT $LABEL: the client saw a reset. ss -K works in this guest"; else echo "RESULT $LABEL: the client saw no reset. ss -K does not close a socket in this guest"; fi
} 2>&1 | tee "$OUT/$LABEL.txt"
