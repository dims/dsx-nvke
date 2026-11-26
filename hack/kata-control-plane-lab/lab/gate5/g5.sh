#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: pods continue through a host runtime restart. This script starts and stops the loops
# and takes the state before and after. The test scripts (t1 to t4) use the same functions
# from lib.sh.
#
# Usage: g5.sh <step> <run id> [arguments]      run id = <test>-<run>, logs in
#                                               /scratch/kata-cp/logs/gate5/<run id>/
#   Steps that only read:
#     preflight <run id>                 three ready replicas, no old unit of this harness
#     state <run id> <label> [identity]  state of the node and of each replica (state-<label>/)
#     compare <run id> <before> <after>  no value of a replica may differ
#     analyze <run id>                   numbers from the loop logs (analysis.txt)
#     diag <run id> [stamp]              journals of containerd and the kubelet, kernel log, events
#     summary                            the RESULT line and the main numbers of each run
#   Steps that start or stop units in the kind node and in the guests (no other change):
#     loops-start <run id>               units g5-readyz and g5-k8s in the node, g5-guest in each guest
#     loops-stop <run id>                stop the units and copy their logs
#     loops-stop-all                     stop each unit g5-* (after a run that broke off)
#     clean                              delete the files of the harness in /run/g5 (node and guests)
#   Steps that change the cluster (the test scripts call them):
#     replicas-down <run id>             scale the three StatefulSets to 0
#     replicas-up <run id> <class>       apply the StatefulSets with a class and wait
#     test-pod <run id> <class>          one small Kata pod with a class, then delete it
#
# The loops (see node/node-loops.sh and node/guest-sampler.sh):
#   - /readyz of the shared address and of each replica, each 0.5 s, from the kind node,
#   - pods, endpoints, node labels, handlers, units and Kata processes, each second,
#   - in each guest: a heartbeat each 0.2 s, the etcd status (leader, raft term, members) and
#     /readyz of the local API server each second.
# No loop runs on the host, and no loop uses "docker exec -d".
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

use_run() { # the folders of a run that exists or starts now. No tee of the output.
  RUN_ID=${1:?run id}
  OUT="$LOG_ROOT/$RUN_ID"
  ND="$ND_ROOT/$RUN_ID"
  mkdir -p "$OUT"
}

step=${1:-}
shift || true
case "$step" in
  preflight)
    use_run "$@"
    preflight
    ;;
  state)
    use_run "$1"
    state "${2:?label}" "${3:-}"
    ;;
  compare)
    use_run "$1"
    compare "${2:?before}" "${3:?after}"
    ;;
  analyze)
    use_run "$1"
    "$HERE/analyze.sh" "$OUT"
    ;;
  diag)
    use_run "$1"
    diag "${2:-action-start}"
    ;;
  loops-start)
    use_run "$1"
    loops_start
    ;;
  loops-stop)
    use_run "$1"
    loops_stop
    ;;
  loops-stop-all)
    for u in $(n systemctl list-units --all --no-legend 'g5-*' | awk '{print $1}'); do
      echo "stop $u in the node"
      n systemctl stop "$u" || true
    done
    for r in "${REPLICAS[@]}"; do pod "$r" systemctl stop g5-guest.service 2>/dev/null || true; done
    ;;
  clean)
    # Only files below /run/g5, which this harness made.
    n find "$ND_ROOT" -mindepth 1 -delete 2>/dev/null || true
    for r in "${REPLICAS[@]}"; do pod "$r" find "$GD" -mindepth 1 -delete 2>/dev/null || true; done
    ;;
  replicas-down)
    use_run "$1"
    replicas_down
    ;;
  replicas-up)
    use_run "$1"
    replicas_up "${2:?class}"
    ;;
  test-pod)
    use_run "$1"
    test_pod "${2:?class}"
    ;;
  summary)
    for d in "$LOG_ROOT"/*/; do
      [ -s "$d/run.log" ] || continue
      echo "-- $(basename "$d")"
      grep -h -E '^RESULT |^FAIL' "$d/run.log" | sort -u | sed 's/^/   /'
      grep -h -E '^(shared|a|b|c): [0-9]+ calls' "$d/analysis.txt" 2>/dev/null | sed 's/^/   /'
    done
    ;;
  *)
    sed -n '2,/^HERE=/p' "$0" | sed '$d'
    exit 1
    ;;
esac
