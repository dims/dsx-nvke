#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# logs-watch.sh: one "kubectl logs" of a pod on a worker through EACH API server, each few
# seconds. The each-second call of the lab reads only /readyz of the shared address, so it does
# not see an API server whose proxy server has no agent. This watch does: such an API server
# answers the logs call with an error.
#
# One line for each call:  <UTC time> <API server address> <node name> ok|FAIL <ms> <first words of the answer>
# The list of the control plane nodes is read again in each round, through the shared address,
# so a node that joins or leaves during a replace is in the watch.
# It ends after <seconds>, or when the file <out file>.stop exists. It changes nothing.
# Usage: logs-watch.sh <kubeconfig> <out file> <pod> [interval s] [seconds] [namespace]
set -uo pipefail
export LC_ALL=C
KCFG=${1:?kubeconfig of the new cluster}
OUT=${2:?out file}
POD=${3:?a pod on a worker}
INTERVAL=${4:-5}
SECS=${5:-7200}
NSP=${6:-default}
KUBECTL=${KUBECTL:-/root/kata-cp/bin/kubectl}
end=$(( $(date +%s) + SECS ))
list=""
: >>"$OUT"
while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$OUT.stop" ]; do
  new=$("$KUBECTL" --kubeconfig "$KCFG" --request-timeout=5s get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  if [ -n "$new" ]; then list=$new; else echo "$(date -u +%FT%TZ) - - FAIL 0 the list of the control plane nodes did not come" >>"$OUT"; fi
  while read -r ip name; do
    [ -n "$ip" ] || continue
    t0=$(date +%s%3N)
    raw=$(timeout 10 "$KUBECTL" --kubeconfig "$KCFG" --server "https://$ip:6443" --request-timeout=6s -n "$NSP" logs "$POD" --tail=1 2>&1; echo "__rc=$?")
    rc=${raw##*__rc=}
    ans=$(printf '%s' "${raw%__rc=*}" | tail -1 | tr -d '\r' | cut -c1-110)
    ms=$(( $(date +%s%3N) - t0 ))
    if [ "$rc" = 0 ]; then st=ok; else st=FAIL; fi
    echo "$(date -u +%FT%TZ) $ip $name $st $ms $ans" >>"$OUT"
  done <<<"$list"
  sleep "$INTERVAL"
done
if [ -e "$OUT.stop" ]; then unlink "$OUT.stop"; fi
echo "$(date -u +%FT%TZ) - - END 0 the watch ended" >>"$OUT"
