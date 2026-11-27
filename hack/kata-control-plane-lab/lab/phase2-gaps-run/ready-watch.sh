#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The watch of the Ready condition of each Node of the new cluster. It runs on the machine (not on
# the workstation), detached, and makes one look each second: kubectl of the machine lists the
# Nodes through the shared address, with the kubeconfig of the cluster from the secrets folder.
# It writes one line for each change:
#   <time> node <name> <control-plane|worker> Ready=<status> was=<status before> reason=<reason> since=<lastTransitionTime>
#   <time> node <name> <role> gone was=<status before>
#   <time> api no answer        the list of the Nodes did not come in 3 s (one line when it starts)
#   <time> api answer           the list comes again
# Times are UTC. "was=absent" marks the first look at a Node (a new Node is not Ready at first).
# Usage (detached): ready-watch.sh <kubeconfig> <out file> [seconds]
# Stop: touch <out file>.stop
set -u
. /root/kata-cp/bin/env.sh
KC=${1:?kubeconfig}
OUT=${2:?out file}
SECS=${3:-10800}
STOP=$OUT.stop
if [ -e "$STOP" ]; then unlink "$STOP"; fi
end=$(( $(date +%s) + SECS ))
declare -A last=() role=()
api=""
now() { date -u +%FT%T.%3NZ; }
echo "$(now) watch start" >>"$OUT"
while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$STOP" ]; do
  t=$(now)
  list=$("$W/bin/kubectl" --kubeconfig "$KC" --request-timeout=3s get nodes -o json 2>/dev/null | jq -r '.items[] | [.metadata.name, (if ((.metadata.labels // {}) | has("node-role.kubernetes.io/control-plane")) then "control-plane" else "worker" end)] + (((.status.conditions // []) | map(select(.type=="Ready")) | .[0]) // {} | [(.status // "none"), (.reason // "-"), (.lastTransitionTime // "-")]) | @tsv' 2>/dev/null)
  if [ -n "$list" ]; then
    if [ "$api" != answer ]; then echo "$t api answer" >>"$OUT"; api=answer; fi
    seen=" "
    while IFS=$'\t' read -r name r st reason since; do
      [ -n "$name" ] || continue
      seen="$seen$name "
      role[$name]=$r
      if [ "${last[$name]:-absent}" != "$st" ]; then
        echo "$t node $name $r Ready=$st was=${last[$name]:-absent} reason=$reason since=$since" >>"$OUT"
        last[$name]=$st
      fi
    done <<<"$list"
    for name in "${!last[@]}"; do
      case "$seen" in
        *" $name "*) ;;
        *) echo "$t node $name ${role[$name]} gone was=${last[$name]}" >>"$OUT"; unset "last[$name]" ;;
      esac
    done
  else
    if [ "$api" != "no answer" ]; then echo "$t api no answer" >>"$OUT"; api="no answer"; fi
  fi
  sleep 1
done
echo "$(now) watch stop" >>"$OUT"
