#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Pass rule 4 (PROPOSAL, it needs the image p8-nogate): the gate fails safe. The cluster of this
# run folder was made with the image p8-nogate: the probe program of each control plane pod does
# not read the gate file. The forced certificate renewal must not start on any node.
# After this test the cluster goes away with a DELETE through the NVKE API: a node of this cluster
# cannot leave the shared address, so a rollout or a node teardown of it would not pass its guard.
# Usage (detached): setsid nohup p2-gaps/p2gaps-t4.sh <label> >logs/p2gaps/<label>-t4.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2gaps/$label DISK_LOG=$W/logs/p2gaps/disk.txt
export GATE_LIMIT=${GATE_LIMIT:-1200}
cd "$W/p2-gaps" || exit 1
exec </dev/null
echo "== $(utc) pass rule 4 in $label"
./run.sh gate-facts before-t4; echo "gate-facts exit code: $? (the probe program of this cluster does not read the gate file)"
./run.sh t4 t4; echo "t4 exit code: $?"
./run.sh health after-t4; echo "health exit code: $?"
echo "== $(utc) end of pass rule 4 in $label"
