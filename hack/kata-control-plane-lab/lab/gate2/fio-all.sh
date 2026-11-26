#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2, part 1: three rounds. Each round runs each place one time, one at a time.
# The rounds mix the places in time, so a load from outside does not hit all runs of one place.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLACES=${PLACES:-"host-loop runc-block kata-block kata-virtiofs kata-nodirect-block kata-go-block host-scratch runc-emptydir"}
ROUNDS=${ROUNDS:-"1 2 3"}
for run in $ROUNDS; do
  for place in $PLACES; do
    "$HERE/fio-run.sh" "$place" "$run" 2>&1 | grep -v 'Operation forced' || echo "$place run $run FAILED"
  done
done
echo "ALL DONE $(date -u +%FT%TZ)"
