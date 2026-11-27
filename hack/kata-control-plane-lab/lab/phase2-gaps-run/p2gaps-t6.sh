#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Pass rules 5 and 6 (and rule 3 a second time): the rollout of the three control plane nodes to
# another image through the NVKE API, with NO operator step. The surge node of the full failure
# domain is pending. After 15 minutes NVKE must remove it, mark the domain and place a new node in
# another domain, and the rollout must end by itself. A rollout can meet a full domain two times,
# so the limit is 90 minutes.
# Usage (detached): [IMG=<image>] [RLABEL=r2] setsid nohup p2-gaps/p2gaps-t6.sh <label> >logs/p2gaps/<label>-t6.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2gaps/$label DISK_LOG=$W/logs/p2gaps/disk.txt
export ROLLOUT_LIMIT=${ROLLOUT_LIMIT:-5400}
IMG=${IMG:-docker.io/library/nvke-node-podvm:bcc4376f-p6}
RLABEL=${RLABEL:-r2}
cd "$W/p2-gaps" || exit 1
exec </dev/null
echo "== $(utc) pass rules 5 and 6 in $label: rollout $RLABEL to ${IMG##*:}, no operator step"
pgrep -f "storage-loop[.]sh" >/dev/null || (setsid nohup "$W/p2-replace/storage-loop.sh" >>"$W/logs/p2gaps/storage-loop.out" 2>&1 &)
./run.sh gate-facts "before-$RLABEL"; echo "gate-facts exit code: $?"
./run.sh cp-rollout "$RLABEL" "$IMG"; echo "cp-rollout exit code: $?"
./run.sh gap2-check "$RLABEL" wait; echo "gap2-check exit code: $?"
./run.sh health "after-$RLABEL"; echo "health exit code: $?"
./run.sh w2 "after-$RLABEL"; echo "w2 exit code: $?"
./run.sh gate-facts "after-$RLABEL"; echo "gate-facts exit code: $?"
echo "== $(utc) end of pass rules 5 and 6 in $label"
