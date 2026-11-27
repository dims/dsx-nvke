#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The collector of the gate lines of the NVKE agent, on the machine. Each 3 s it reads the last
# 30 s of the agent journal of each control plane pod of the cluster and adds each new line about
# the health gate to the out file, as "<pod> <JSON line of the agent>". A node that a rollout tears
# down takes its journal with it, so the lines must be read while the pod exists.
# Reads only. Usage (detached): setsid agent-gate-watch.sh <out file> [seconds]
# Stop: touch <out file>.stop
set -u
OUT=${1:?out file}
SECS=${2:-10800}
NS=${NS:-d}
STOP=$OUT.stop
KC=(/root/kata-cp/bin/kubectl --kubeconfig /root/kata-cp/secrets/kubeconfig)
PAT='control plane endpoint|endpoint gate|remote VIP socket|quiet window|kube-vip is not configured|graceful shutdown'
if [ -e "$STOP" ]; then unlink "$STOP"; fi
end=$(( $(date +%s) + SECS ))
declare -A seen=()
while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$STOP" ]; do
  for p in $("${KC[@]}" -n "$NS" get pods -l cluster.x-k8s.io/control-plane -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ -z "${seen[$p $line]:-}" ]; then seen[$p $line]=1; echo "$p $line" >>"$OUT"; fi
    done < <(timeout 10 "${KC[@]}" -n "$NS" exec "$p" -- journalctl --no-pager -u nvke-agent --since "-30s" -o cat 2>/dev/null | grep -E "$PAT" | cut -c1-900)
  done
  sleep 3
done
