#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Copy the record of one run from the share to the log folder of the host, and print its main lines.
# Usage: collect.sh <label>
set -euo pipefail
label=${1:?label}
S=/scratch/kata-cp/vm-share/results/$label
L=/scratch/kata-cp/logs/vm-restart/runs
mkdir -p "$L"
cp -r "$S" "$L/"
D=$L/$label
echo "== $label: $(cat /scratch/kata-cp/vm-share/status/$label.done)"
cat "$D/before.txt" "$D/boot.txt"
echo "-- Docker record at the last clean shutdown"; cat "$D/docker-state-last-shutdown.txt"
echo "-- Docker record at boot, before Docker started"; cat "$D/docker-state-at-boot.txt"
echo "-- Docker inspect after"; jq -c '{Status: .State.Status, ExitCode: .State.ExitCode, StartedAt: .State.StartedAt, FinishedAt: .State.FinishedAt, RestartCount, RestartPolicy}' "$D/docker-inspect-after.json"
echo "-- times"; cat "$D/summary-times.txt"
echo "-- post"; grep -v '^$' "$D/post.out" | cut -c1-260
