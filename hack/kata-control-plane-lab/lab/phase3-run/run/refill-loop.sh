#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# More worker starts for the test of the simulator fix: delete the oldest worker through the NVKE
# API while the pool count asks for it, so NVKE makes a new worker by itself. One record for each
# new worker (p3ab.sh starts), and the check that nothing is left of the old one.
# Usage (detached): refill-loop.sh <run> <count>
set -u
run=${1:?run}
count=${2:?count}
P=/root/kata-cp/p3/run/p3ab.sh
D=/root/kata-cp/logs/p3/$run
exec </dev/null
for i in $(seq 1 "$count"); do
  w=$(docker ps --filter label=nvidia.com/nico-containers.managed=true --format '{{.CreatedAt}}|{{.Label "nvidia.com/nico-containers.instance-name"}}' | sort | head -1 | cut -d'|' -f2)
  [ -n "$w" ] || { echo "no worker to delete"; exit 1; }
  grep -q " node=$w " "$D/starts.txt" || { echo "the worker $w has no start record. Stop"; exit 1; }
  echo "== $(date -u +%T) refill $i: delete $w (pressure: $(head -1 /proc/pressure/io | cut -d' ' -f2-3))"
  "$P" node-delete "$run" "$w" "refill-$i" || exit 1
  "$P" watch "$run" 600 5 "$w" | tail -1
  sleep 3
  "$P" starts "$run" | tail -1 | cut -c1-700
  "$P" gone-check "$run" "refill-$i" | grep -E 'RESULT|FAIL'
done
echo "== $(date -u +%T) refill loop done"
