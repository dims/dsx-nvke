#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, test 1: restart containerd in the kind node while the three replicas run.
#
#   t1-containerd.sh <run>          logs in /scratch/kata-cp/logs/gate5/t1-containerd-<run>/
#   TEST=<name> t1-containerd.sh <run>   another name for the log folder (for a run in a special
#                                   state, for example after an upgrade)
#
# What changes: one "systemctl restart containerd" in the kind node. It acts on each pod of the
# node. The units of the harness start and stop. Nothing else.
#
# Steps: state before, loops, 20 s of baseline, the restart (as a systemd unit of the node),
# 45 s more, state after, comparison, numbers, journals.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

init_run "${TEST:-t1-containerd}" "${1:?run}"
preflight
state before identity
loops_start
sleep "$BASELINE"

say "action: systemctl restart containerd (in the kind node)"
start_action action-containerd.sh 3
wait_action 10 120 || echo "FAIL: the action did not run"
sleep "$AFTER"

loops_stop
state after identity
compare before after || true
"$HERE/analyze.sh" "$OUT"
diag action-start
say "containerd down time, from its journal"
grep -E 'Stopping containerd|Stopped containerd|Starting containerd|Started containerd|containerd successfully booted' "$OUT/diag/containerd-journal.txt" | cut -c1-200
sleep 1
result
