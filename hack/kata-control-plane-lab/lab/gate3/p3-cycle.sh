#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 3, path 3: one cycle of the restart tests for a psat pod that runs already.
# Usage: p3-cycle.sh <pod> <class|runc> <cycle label> [absence seconds]
# Steps: container restart, new pod on the same data, new pod after an absence (default 200 s,
# longer than an agent SVID life of 2 minutes), new pod with empty data.
set -uo pipefail
cd /scratch/kata-cp/work/gate3
source ./lib.sh
POD=$1
CLASS=$2
C=$3
GONE=${4:-200}
short() { grep -E 'status of|RESTARTS|^psat|^nvke|entry:|SVID loaded|expired|Node attestation|reattest|SPIFFE ID:|exit code|gate3-pods|Serial' | grep -v 'gate3-host' | cut -c1-300; }
say "cycle $C: container restart"
k -n "$NS" exec "$POD" -- sh -c 'kill -TERM 1'
sleep 8
./p3.sh status "$POD" "$C-a-container-restart" | short
say "cycle $C: new pod on the same data"
./p3.sh del-pod "$POD"
./p3.sh up "$POD" "$CLASS" >/dev/null && sleep 6
./p3.sh status "$POD" "$C-b-new-pod-same-data" | short
say "cycle $C: new pod after an absence of $GONE s"
./p3.sh del-pod "$POD"
date -u +"deleted at %T"
sleep "$GONE"
date -u +"made again at %T"
./p3.sh up "$POD" "$CLASS" >/dev/null && sleep 8
./p3.sh status "$POD" "$C-c-new-pod-after-absence" | short
say "cycle $C: new pod with empty data"
./p3.sh del-pod "$POD"
./p3.sh del-claim "$POD"
./p3.sh up "$POD" "$CLASS" >/dev/null && sleep 8
./p3.sh status "$POD" "$C-d-new-pod-empty-data" | short
say "cycle $C: done"
