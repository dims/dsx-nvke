#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Block D: the delete of the cluster of run 1 (API delete, then the two operator steps on the objects of
# that one cluster, as in delete.sh), then run 2 with the replace of the first node. The second cluster stays.
. /root/kata-cp/bin/env.sh
cd "$W"
echo "== $(utc) etcd of run 1: refused peer connections on each host"
for r in a b c; do echo "host $r: $(kubectl -n d exec cp-$r-0 -- sh -c 'crictl logs "$(crictl ps --name etcd -q | head -1)" 2>&1 | grep -c "rejected connection on peer endpoint"' 2>/dev/null)"; done
echo "== $(utc) delete of the cluster of run 1"
LOG_DIR=$W/logs/d/d-run-1 CLUSTER_NAME=kata-cp1 d/endpoint-run/delete.sh all >logs/d/d-run-1-delete.out 2>&1
echo "delete exit code: $?"
grep -E 'RESULT|FAIL|ERROR|HTTP 404|workflow' logs/d/d-run-1-delete.out | tail -6 | cut -c1-200
echo "== $(utc) run 2"
d/d-run.sh d-run-2 replace >logs/d/d-run-2.out 2>&1
echo "run 2 exit code: $?"
tail -3 logs/d/d-run-2.out | cut -c1-200
echo "== $(utc) D CHAIN DONE"
