#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The watch of the pods of the cluster and of the EndpointSlice of the shared Service (cp-api), on
# the machine. Two kubectl watches on the host cluster. One line for each change, with the time
# (UTC, milliseconds) at which the event came:
#   <time> pod <name> ip=<pod IP> ready=<True|False> since=<lastTransitionTime of Ready> del=<deletionTimestamp or ->
#   <time> eps <slice> ready=[<pod>@<ip>,...] notready=[<pod>@<ip>,...]
# Usage (detached, as the leader of its own process group): setsid ep-watch.sh <out file> [seconds]
# Stop: kill -TERM -- -<pid>   (the process group)
set -u
OUT=${1:?out file}
SECS=${2:-10800}
NS=${NS:-d}
KC=(/root/kata-cp/bin/kubectl --kubeconfig /root/kata-cp/secrets/kubeconfig)
T='(now as $n | ($n | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "." + ((("000" + (((($n * 1000) | floor) % 1000) | tostring)))[-3:]) + "Z")'
end=$(( $(date +%s) + SECS ))
echo $$ >"$OUT.pgid"
echo "$(date -u +%FT%T.%3NZ) watch start" >>"$OUT"
(
  while [ "$(date +%s)" -lt "$end" ]; do
    timeout $(( end - $(date +%s) + 1 )) "${KC[@]}" -n "$NS" get pods --watch -o json 2>/dev/null |
      jq --unbuffered -r "$T"' + " pod \(.metadata.name) ip=\(.status.podIP // "-") ready=\(((.status.conditions // []) | map(select(.type=="Ready")) | .[0].status) // "none") since=\(((.status.conditions // []) | map(select(.type=="Ready")) | .[0].lastTransitionTime) // "-") del=\(.metadata.deletionTimestamp // "-")"' |
      awk '{k=$3; v=$4 " " $5 " " $6 " " $7; if (last[k] != v) {print; fflush(); last[k]=v}}' >>"$OUT"
    sleep 1
  done
) &
(
  while [ "$(date +%s)" -lt "$end" ]; do
    timeout $(( end - $(date +%s) + 1 )) "${KC[@]}" -n "$NS" get endpointslices -l kubernetes.io/service-name=cp-api --watch -o json 2>/dev/null |
      jq --unbuffered -r "$T"' + " eps \(.metadata.name) ready=[\([(.endpoints // [])[] | select(.conditions.ready == true) | "\(.targetRef.name // "-")@\(.addresses[0])"] | sort | join(","))] notready=[\([(.endpoints // [])[] | select(.conditions.ready != true) | "\(.targetRef.name // "-")@\(.addresses[0])"] | sort | join(","))]"' |
      awk '{v=$4 " " $5; if (last != v) {print; fflush(); last=v}}' >>"$OUT"
    sleep 1
  done
) &
wait
