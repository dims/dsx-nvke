#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2, part 2: the sample loop. It runs in the kind node, so the host opens no TCP connection.
# Usage: sampler.sh <output folder> <namespace> <interval seconds> <pod=server URL> ...
# Each interval it runs sample-once.sh in each pod and adds the cgroup of the pod in the kind node.
# It stops when the file <output folder>/stop exists.
OUT=$1
NS=$2
INTERVAL=$3
shift 3
KC="kubectl --kubeconfig /etc/kubernetes/admin.conf"
HERE=$(dirname "$0")
mkdir -p "$OUT"
rm -f "$OUT/stop"

declare -A CG
for pair in "$@"; do
  pod=${pair%%=*}
  uid=$($KC -n "$NS" get pod "$pod" -o jsonpath='{.metadata.uid}')
  CG[$pod]=$(find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name "*pod${uid//-/_}.slice" | head -1)
  echo "pod $pod uid $uid cgroup ${CG[$pod]}" >>"$OUT/pods.txt"
done

n=0
while [ ! -e "$OUT/stop" ]; do
  begin=$(date +%s)
  for pair in "$@"; do
    pod=${pair%%=*}
    server=${pair#*=}
    cg=${CG[$pod]}
    {
      echo "### sample $n pod $pod"
      $KC -n "$NS" exec -i "$pod" -- env SERVER="$server" bash -s <"$HERE/sample-once.sh"
      echo "### podcgroup $(date +%s.%N)"
      echo "memory.current $(cat "$cg/memory.current")"
      echo "memory.peak $(cat "$cg/memory.peak")"
      echo "memory.max $(cat "$cg/memory.max")"
      echo "memory.events $(tr '\n' ' ' <"$cg/memory.events")"
      echo "memory.stat $(grep -E '^(anon|file|shmem|kernel|file_dirty|file_writeback) ' "$cg/memory.stat" | tr '\n' ' ')"
      echo "cpu.stat $(grep -E '^(usage_usec|nr_throttled|throttled_usec) ' "$cg/cpu.stat" | tr '\n' ' ')"
      echo "### nodeload $(cat /proc/loadavg)"
      echo "### done"
    } >"$OUT/$pod.$(printf %04d $n).txt" 2>&1 &
  done
  wait
  n=$((n + 1))
  while [ $(($(date +%s) - begin)) -lt "$INTERVAL" ] && [ ! -e "$OUT/stop" ]; do sleep 1; done
done
echo "stopped after $n samples" >>"$OUT/pods.txt"
