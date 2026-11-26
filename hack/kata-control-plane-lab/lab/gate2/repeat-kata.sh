#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2, part 2: more runs of the pass case. Each run makes a new Kata control plane node pod
# from empty devices, puts 756 fake nodes and the patch load on it, and takes one window.
# Usage: repeat-kata.sh <run number> ...
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE=/scratch/kata-cp/logs/gate2
for run in "$@"; do
  echo "== run $run: $(uptime)"
  LOG_DIR=$BASE/cp-kata-$run "$HERE/cp.sh" kata up >"$BASE/cp-kata-$run-up.out" 2>&1 || { echo "run $run: the node pod did not start"; exit 1; }
  grep -E 'RESULT|exit code' "$BASE/cp-kata-$run-up.out"
  TARGET=kata LOG_DIR=$BASE/etcd-kata-$run LEVELS=756 IDLE=20 INNER_CLEANUP=0 "$HERE/load.sh" run >"$BASE/etcd-kata-$run-run.out" 2>&1 || echo "run $run: the load test gave an error"
  LOG_DIR=$BASE/cp-kata-$run "$HERE/cp.sh" kata down >"$BASE/cp-kata-$run-down.out" 2>&1 || echo "run $run: the node pod did not stop"
  python3 "$HERE/analyze.py" "$BASE/etcd-kata-$run" w756 >"$BASE/etcd-kata-$run/analysis.txt" 2>&1
  grep -E 'WAL fsync|share above|p99 of each' "$BASE/etcd-kata-$run/analysis.txt"
  echo "== run $run done: $(uptime)"
done
echo "REPEAT DONE"
