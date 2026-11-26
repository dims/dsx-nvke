#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Record what Docker has on disk about its containers. Usage: record-docker-state.sh boot|shutdown
#   boot:     before Docker starts. The record shows what Docker finds after the restart.
#   shutdown: after Docker stopped at a clean shutdown. The record shows the exit code.
# The unit vm-restart-record.service calls it. It only reads the files of Docker.
set -u
STATE=/var/lib/vm-restart
mkdir -p /run/vm-restart "$STATE/docker-state"
case "${1:-}" in
  boot) out=/run/vm-restart/docker-state-at-boot.txt ;;
  shutdown) out=$STATE/docker-state/last-shutdown.txt ;;
  *) exit 1 ;;
esac
{
  echo "record $1 at $(date -u +%FT%T.%3NZ), $(cut -d' ' -f1 /proc/uptime) s after kernel boot, boot ID $(cat /proc/sys/kernel/random/boot_id)"
  for f in /var/lib/docker/containers/*/config.v2.json; do
    [ -f "$f" ] || continue
    jq -c '{Name, Running: .State.Running, Restarting: .State.Restarting, Dead: .State.Dead, Pid: .State.Pid, ExitCode: .State.ExitCode, StartedAt: .State.StartedAt, FinishedAt: .State.FinishedAt, RestartCount, HasBeenManuallyStopped}' "$f"
  done
} >"$out" 2>&1
[ "$1" = shutdown ] && sync "$out" "$STATE/docker-state"
exit 0
