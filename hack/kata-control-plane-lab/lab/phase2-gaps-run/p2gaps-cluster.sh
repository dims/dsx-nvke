#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# A new cluster for the gap tests through the NVKE API: three control plane nodes and one worker,
# with the image p6 (or IMG_CLUSTER). The cluster before it must be gone (run.sh delete with its
# run folder, then p2-provider/storage.sh reset).
# Usage (detached): [IMG_CLUSTER=<image>] [WORKER_COUNT=0] setsid nohup p2-gaps/p2gaps-cluster.sh <label> >logs/p2gaps/<label>-cluster.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2gaps/$label DISK_LOG=$W/logs/p2gaps/disk.txt
export IMG_CLUSTER=${IMG_CLUSTER:-docker.io/library/nvke-node-podvm:bcc4376f-p6}
export IMG_WORKER=${IMG_WORKER:-$IMG_CLUSTER}
WORKER_COUNT=${WORKER_COUNT:-1}
mkdir -p "$LOG_DIR"
cd "$W/p2-gaps" || exit 1
exec </dev/null
echo "== $(utc) new cluster in $label: image ${IMG_CLUSTER##*:}, $WORKER_COUNT worker"
"$W/p2-gaps/kernel/kernel-switch.sh" status
pgrep -f "storage-loop[.]sh" >/dev/null || (setsid nohup "$W/p2-replace/storage-loop.sh" >>"$W/logs/p2gaps/storage-loop.out" 2>&1 &)
WAIT=1 "$W/p2-replace/disk.sh" "$label new cluster"
./run.sh flow; rc=$?; echo "flow exit code: $rc"
if [ "$rc" != 0 ]; then echo "== $(utc) the flow did not pass. Look at the lines FAIL above before the next step. Stop of the chain in $label"; exit 1; fi
./run.sh wait-good 3 300; echo "wait-good exit code: $?"
if [ "$WORKER_COUNT" -gt 0 ]; then
  ./run.sh pool-post workers wk "$WORKER_COUNT"; echo "pool-post exit code: $?"
  ./run.sh pool-wait "$WORKER_COUNT" new; echo "pool-wait exit code: $?"
  ./run.sh w2 new; echo "w2 exit code: $?"
fi
./run.sh health new; echo "health exit code: $?"
./run.sh gate-facts new; echo "gate-facts exit code: $?"
./run.sh facts new >/dev/null; echo "facts exit code: $?"
echo "== $(utc) end of the new cluster in $label"
