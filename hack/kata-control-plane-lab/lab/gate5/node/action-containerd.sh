#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, test 1: restart containerd in the kind node. lib.sh runs this file as the systemd
# unit g5-action of the node.
#
#   action-containerd.sh <dir> [seconds to wait first]
#
# It writes <dir>/action.log (lines "<time> <name> <detail>") and then <dir>/action.done.
set -u
D=$1
L="$D/action.log"
st() { printf '%s %s\n' "$EPOCHREALTIME" "$*" >>"$L"; }
unit() { systemctl show "$1" -p MainPID -p NRestarts -p ActiveEnterTimestamp --value | tr '\n' ' '; }

sleep "${2:-3}"
st "info root cgroup processes: [$(grep -v '^0$' /sys/fs/cgroup/cgroup.procs | tr '\n' ' ')]"
st "info containerd before: $(unit containerd)"
st "info kubelet before: $(unit kubelet)"
st action-start systemctl restart containerd
systemctl restart containerd
st "action-returned rc=$?"
# The CRI socket answers again.
for _ in $(seq 1 300); do
  if crictl info >/dev/null 2>&1; then
    st cri-answers
    break
  fi
  sleep 0.2
done
st "info containerd after: $(unit containerd)"
st "info kubelet after: $(unit kubelet)"
touch "$D/action.done"
