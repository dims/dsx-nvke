#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# W5, second part. State at the start: two pools (workers with one node, workers-b with one node),
# because a lab fault of the first chain made the second pool before the first was deleted.
# 1. Record the cluster with two workers (placement, storage, traffic).
# 2. W5b: DELETE of the pool workers-b with its node.
# 3. The name of a deleted pool again, with no node, and the delete of an empty pool.
# 4. The record of the cluster that stays up: three control plane nodes and one worker (pool workers).
# Usage (detached): setsid nohup p2-worker/p2s8-w5b.sh <label> >logs/p2s8/<label>-w5b.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s8/$label DISK_LOG=$W/logs/p2s8/disk.txt
cd "$W/p2-worker" || exit 1
echo "== $(utc) W5 second part in $label"
./run.sh wait-good 5 600; echo "wait-good 5 exit code: $?"
WORKER_INDEX=1 ./run.sh w1 second-worker; echo "w1 second-worker exit code: $?"
"$W/p2-provider/storage.sh" status | tail -14
WAIT=1 "$W/p2-replace/disk.sh" "$label traffic two-workers"
WORKER_INDEX=1 ./run.sh w2 two-workers; echo "w2 two-workers exit code: $?"
./run.sh pool-delete w5b; echo "pool-delete w5b exit code: $?"
./run.sh pool-post workers-b wk 0; rc=$?; echo "pool-post with the name of the deleted pool, no node: exit code $rc"
if [ "$rc" = 0 ]; then ./run.sh pool-delete w5c; echo "pool-delete w5c (empty pool) exit code: $?"; fi
# The pool that stays.
env -u LOG_DIR "$W/d/stack/api.sh" get "/api/nodePools?clusterID=$(cat "$LOG_DIR/cluster-id.txt")" | sed '$d' | jq -r '(.nodePools // .)[] | select(.name=="workers") | .id' >"$LOG_DIR/pool-id.txt"
echo workers >"$LOG_DIR/pool-name.txt"
echo "the pool that stays: $(cat "$LOG_DIR/pool-name.txt") $(cat "$LOG_DIR/pool-id.txt")"
./run.sh w1 final; echo "w1 final exit code: $?"
./run.sh w2 final; echo "w2 final exit code: $?"
echo "== $(utc) end of W5 second part in $label"
