#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2: write the CPU counters and the load average of the machine each 30 seconds.
# The load average counts tasks that wait for the disk, so the tests raise it by themselves.
# The CPU counters show a build of another session. Stop the loop with: kill "$(cat <log>.pid)".
LOG=${1:-/scratch/kata-cp/logs/gate2/host-cpu.log}
echo $$ >"$LOG.pid"
while :; do
  echo "$(date +%s) $(head -1 /proc/stat) load $(cut -d' ' -f1-4 /proc/loadavg)" >>"$LOG"
  sleep 30
done
