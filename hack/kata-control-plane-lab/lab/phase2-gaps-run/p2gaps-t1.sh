#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Pass rule 1: the forced certificate renewal (the operator start of the product page), with the
# call to the shared address each second and the watch of the Ready condition of each Node.
# Usage (detached): setsid nohup p2-gaps/p2gaps-t1.sh <label> >logs/p2gaps/<label>-t1.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2gaps/$label DISK_LOG=$W/logs/p2gaps/disk.txt
cd "$W/p2-gaps" || exit 1
exec </dev/null
echo "== $(utc) pass rule 1 in $label"
./run.sh gate-facts before-t1; rc=$?; echo "gate-facts exit code: $rc"
if [ "$rc" != 0 ]; then echo "== $(utc) the gate is not in place on each node. Stop"; exit 1; fi
./run.sh t1 t1; echo "t1 exit code: $?"
./run.sh health after-t1; echo "health exit code: $?"
./run.sh w2 after-t1; echo "w2 exit code: $?"
./run.sh facts after-t1 >/dev/null; echo "facts exit code: $?"
echo "== $(utc) end of pass rule 1 in $label"
