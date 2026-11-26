#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Runs in the kind node. Prints one line each second with the memory numbers (MiB) of one cgroup
# and the name and RSS (MiB) of each process in it, until the stop file exists.
# Usage: mem-sampler.sh <cgroup folder> <stop file> [most lines]
cg=$1
stop=$2
max=${3:-1500}
i=0
while [ ! -e "$stop" ] && [ "$i" -lt "$max" ]; do
  i=$((i + 1))
  if [ ! -d "$cg" ]; then
    echo "$(date +%s) cgroup-gone"
    sleep 1
    continue
  fi
  cur=$(cat "$cg/memory.current" 2>/dev/null || echo 0)
  stat=$(awk '$1=="anon"||$1=="file"||$1=="shmem"||$1=="kernel"||$1=="pagetables"||$1=="sec_pagetables"||$1=="slab"||$1=="active_file"||$1=="inactive_file" {printf "%s=%d ", $1, $2/1048576}' "$cg/memory.stat" 2>/dev/null)
  ev=$(awk '$1=="max"||$1=="oom_kill" {printf "ev_%s=%s ", $1, $2}' "$cg/memory.events" 2>/dev/null)
  procs=""
  for p in $(find "$cg" -name cgroup.procs -exec cat {} + 2>/dev/null | sort -u); do
    [ -r "/proc/$p/status" ] || continue
    procs="$procs$(awk '/^Name:/{n=$2} /^VmRSS:/{r=$2} END{printf "%s:%d ", n, r/1024}' "/proc/$p/status" 2>/dev/null)"
  done
  echo "$(date +%s) current=$((cur / 1048576)) $stat$ev| $procs"
  sleep 1
done
