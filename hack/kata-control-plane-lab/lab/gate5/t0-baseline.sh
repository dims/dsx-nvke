#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, control run: the loops with no action. It gives the numbers of a quiet system, and
# it proves that the harness works before a test restarts something.
#
#   t0-baseline.sh <run>            logs in /scratch/kata-cp/logs/gate5/t0-baseline-<run>/
#   SECONDS_QUIET=60                how long the loops run
#
# What changes: only the units of the harness start and stop (g5-readyz and g5-k8s in the kind
# node, g5-guest in each guest), with their files in /run/g5.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

init_run "${TEST:-t0-baseline}" "${1:?run}"
preflight
state before identity
loops_start
sleep "${SECONDS_QUIET:-60}"
loops_stop
state after identity
compare before after || true
"$HERE/analyze.sh" "$OUT"
result
