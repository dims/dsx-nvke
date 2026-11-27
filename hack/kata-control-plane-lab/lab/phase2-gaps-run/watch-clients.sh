#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Clients with a long-lived connection through the shared address, on the machine: each client is
# one "kubectl get configmaps --watch" on the new cluster. When its connection ends, the client
# writes one line and connects again after 1 s. For pass rule 4: the clients that the agent
# closes come back through the Service at once.
# Usage: watch-clients.sh start <kubeconfig> <out dir> [count]     (detached, leader of its own process group)
#        watch-clients.sh stop <out dir>
set -u
case "${1:-}" in
  start)
    KCFG=${2:?kubeconfig}; D=${3:?out dir}; N=${4:-12}
    mkdir -p "$D"
    if [ -e "$D/stop" ]; then unlink "$D/stop"; fi
    echo $$ >"$D/pgid"
    for i in $(seq 1 "$N"); do
      (
        while [ ! -e "$D/stop" ]; do
          t0=$(date +%s.%3N)
          echo "$(date -u +%FT%T.%3NZ) client $i connects" >>"$D/clients.txt"
          /root/kata-cp/bin/kubectl --kubeconfig "$KCFG" -n default get configmaps --watch --request-timeout=0 >/dev/null 2>"$D/client-$i.err"
          rc=$?
          echo "$(date -u +%FT%T.%3NZ) client $i connection ended after $(echo "$(date +%s.%3N) $t0" | awk '{printf "%.1f", $1 - $2}') s (exit code $rc): $(tail -1 "$D/client-$i.err" | cut -c1-160)" >>"$D/clients.txt"
          sleep 1
        done
      ) &
    done
    wait
    ;;
  stop)
    D=${2:?out dir}
    touch "$D/stop"
    if [ -s "$D/pgid" ]; then kill -TERM -- "-$(cat "$D/pgid")" 2>/dev/null || true; fi
    echo "clients stopped. Lines: $(grep -c . "$D/clients.txt" 2>/dev/null || true), connections that ended: $(grep -c 'connection ended' "$D/clients.txt" 2>/dev/null || true)"
    ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
