#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# R2: a new pod for each Machine of the cluster (one after the other, the provider makes each pod
# again), then desired count 4. The new node must join by itself: /tmp is new in each node now.
# Then desired count 3.
# Usage (detached): setsid nohup p2-agentfix/p2s6b-r2.sh <label> >logs/p2s6b/<label>-r2.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s6b/$label LOST_WATCH=${LOST_WATCH:-150}
cd "$W/p2-agentfix" || exit 1
echo "== $(utc) R2 in $label"
WAIT=1 "$W/p2-replace/disk.sh" "$label R2 new pods"
./run.sh podmap
for r in $(awk '{print $1}' "$LOG_DIR/podmap.txt"); do
  ./run.sh lost-pod "$r"; echo "lost-pod $r exit code: $?"
done
./run.sh wait-good 3 600; echo "wait-good exit code: $?"
./run.sh after r2-new-pods; echo "after r2-new-pods exit code: $?"
./run.sh scale 4 r2-up; echo "scale r2-up exit code: $?"
./run.sh after r2-up; echo "after r2-up exit code: $?"
./run.sh fix-evidence r2-up >/dev/null
./run.sh scale 3 r2-down; echo "scale r2-down exit code: $?"
./run.sh after r2-down; echo "after r2-down exit code: $?"
echo "== $(utc) end of R2 in $label"
