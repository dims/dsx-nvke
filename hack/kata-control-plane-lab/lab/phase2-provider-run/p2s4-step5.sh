#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Step 5 in the cluster of one run: a lost pod (a node that is not the first node, then the first
# node), the pass rules and pod traffic after each, the reboot request of NVKE, and the delete
# through the NVKE API.
# Usage (detached): setsid nohup p2-provider/p2s4-step5.sh <label> >logs/p2s4/<label>-step5.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2s4/$label
cd "$W/p2-provider" || exit 1
new_test_pods() { # the test pod on a node with a new pod does not start again by itself (block D)
  local via
  via=$(awk '$1=="a" {print $2}' "$LOG_DIR/podmap.txt")
  docker exec kata-bb-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf -n d exec "$via" -- \
    kubectl --kubeconfig /etc/kubernetes/admin.conf -n default delete pod p1-t-a p1-t-b p1-t-c --ignore-not-found --wait=true --timeout=120s
}
after() { # <label>: the pass rules and pod traffic
  ./run.sh check "$1"; echo "check $1 exit code: $?"
  ./run.sh endpoint "$1"; echo "endpoint $1 exit code: $?"
  ./run.sh etcd "$1"; echo "etcd $1 exit code: $?"
  ./run.sh provider "$1"; echo "provider $1 exit code: $?"
  new_test_pods
  ./run.sh traffic "$1"
}
echo "== $(utc) step 5 in $label"
echo "== $(utc) point 5a: a lost pod, not the first node"
./run.sh lost-pod other; echo "lost-pod other exit code: $?"
after after-lost-other
echo "== $(utc) point 5b: a lost pod, the first node"
./run.sh lost-pod first; echo "lost-pod first exit code: $?"
after after-lost-first
echo "== $(utc) point 6: the reboot request of NVKE"
./run.sh reboot "${REBOOT_HOST:-b}"; echo "reboot exit code: $?"
echo "== $(utc) NVKE view"; ./run.sh poll
if [ "${STEP5_DELETE:-1}" = 1 ]; then
  echo "== $(utc) point 7: delete through the NVKE API"
  ./run.sh delete; echo "delete exit code: $?"
fi
echo "== $(utc) end of step 5 in $label"
