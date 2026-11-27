#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# W2: traffic with the worker, the tunnels, calls of the API servers to a pod on the worker.
# Usage (detached): setsid nohup p2-worker/p2s8-w2.sh <label> [name] >logs/p2s8/<label>-w2.out 2>&1 &
label=${1:?label}
name=${2:-w2}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s8/$label DISK_LOG=$W/logs/p2s8/disk.txt
cd "$W/p2-worker" || exit 1
echo "== $(utc) W2 ($name) in $label"
WAIT=1 "$W/p2-replace/disk.sh" "$label traffic $name"
./run.sh w2 "$name"; echo "w2 exit code: $?"
echo "== $(utc) end of W2 ($name) in $label"
