#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# After T4: a new pod for the Machine of the node that ran kubeadm init (the image for pods with the
# real data of NVKE), then the pass rules again, and pod traffic with new test pods.
# Usage (detached): setsid nohup p2-image/test/t4-replace.sh <label> >logs/p2/<label>-replace.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
export LOG_DIR=$W/logs/p2/$label
cd "$W/p2-image/test" || exit 1
echo "== $(utc) replace in $label"
./t4.sh replace
echo "replace exit code: $?"
./t4.sh check after-replace
echo "check exit code: $?"
./t4.sh endpoint after-replace
echo "endpoint exit code: $?"
./t4.sh etcd after-replace
echo "etcd exit code: $?"
# The test pod on the replaced node does not start again by itself (block D). Use new test pods.
via=$(awk '$1=="a" {print $2}' "$LOG_DIR/pods.txt")
docker exec kata-bb-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf -n p2c exec "$via" -- \
  kubectl --kubeconfig /etc/kubernetes/admin.conf -n default delete pod p1-t-a p1-t-b p1-t-c --wait=true --timeout=120s
./t4.sh traffic after-replace
echo "== $(utc) NVKE view after the replace"; ./t4.sh poll
echo "== $(utc) end of the replace in $label"
