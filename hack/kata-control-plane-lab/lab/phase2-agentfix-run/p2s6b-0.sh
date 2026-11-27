#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Before part A: delete the cluster of steps 6 and 7 through the NVKE API (nothing else), then make
# the volumes of the lab storage free again.
# Usage (detached): setsid nohup p2-agentfix/p2s6b-0.sh >logs/p2s6b/delete-old.out 2>&1 &
. /root/kata-cp/bin/env.sh
export DISK_LOG=$W/logs/p2s6b/disk.txt
echo "== $(utc) delete of the cluster of steps 6 and 7 through the NVKE API"
WAIT=1 "$W/p2-replace/disk.sh" "delete of the old cluster"
LOG_DIR=$W/logs/p2s6/run-1 "$W/p2-replace/run.sh" delete; echo "delete exit code: $?"
"$W/p2-provider/storage.sh" reset; echo "storage reset exit code: $?"
"$W/p2-provider/storage.sh" status
echo "== $(utc) end"
