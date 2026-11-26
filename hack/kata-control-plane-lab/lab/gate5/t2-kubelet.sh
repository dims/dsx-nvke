#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, test 2: restart the kubelet in the kind node while the three replicas run.
#
#   t2-kubelet.sh <run>             logs in /scratch/kata-cp/logs/gate5/t2-kubelet-<run>/
#
# What changes: one "systemctl restart kubelet" in the kind node. It acts on each pod of the
# node. The units of the harness start and stop. Nothing else.
#
# The kubelet of a kind node does not start while the root cgroup of the node holds a process.
# On the running node a "docker exec" process is in /init.scope and not in the root cgroup
# (measured on 2026-11-26), so a "docker exec" does not block the kubelet now. The restart
# still runs as a systemd unit of the node, and this script starts no "docker exec" for 30 s
# around it, so that the harness cannot be the cause of a slow start. If the root cgroup holds
# a process for 20 s, the action stops with the line ABORT and the kubelet is not touched.
#
# What to look at: the pod readiness and the endpoints of the shared Service (k8s.log). A new
# kubelet has no probe result for a container. If it reports the pods as not ready for a
# moment, the shared address loses its endpoints, and the addresses of the replicas do not
# (their Services publish addresses that are not ready).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

init_run "${TEST:-t2-kubelet}" "${1:?run}"
preflight
state before identity
loops_start
sleep "$BASELINE"

say "action: systemctl restart kubelet (in the kind node)"
start_action action-kubelet.sh 5
wait_action 30 180 || echo "FAIL: the action did not run"
sleep "$AFTER"

loops_stop
state after identity
# The kubelet reports the readiness again after its start, so the time of the Ready condition
# can change. The analysis shows each change of the readiness.
compare before after '^ready_since$' || true
"$HERE/analyze.sh" "$OUT"
diag action-start
say "kubelet stop and start, from its journal"
grep -E 'Stopping kubelet|Stopped kubelet|Started kubelet|Failed with result|ERROR: this script needs' "$OUT/diag/kubelet-journal.txt" | cut -c1-200
say "readiness of the node pods and the endpoints of the shared Service during the run"
grep -E ' (pods|eps) changed' "$OUT/analysis.txt" | cut -c1-400 || true
echo "Ready condition before: $(grep ready_since "$OUT/state-before/kv.txt" | tr '\n' ' ')"
echo "Ready condition after:  $(grep ready_since "$OUT/state-after/kv.txt" | tr '\n' ' ')"
sleep 1
result
