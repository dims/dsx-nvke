#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, test 3b: restart the kata-deploy DaemonSet, as the upstream test
# tests/functional/kata-deploy/kata-deploy-lifecycle.bats does (regression test of issue 12761).
# lib.sh runs this file as the systemd unit g5-action of the node.
#
#   action-ds-rollout.sh <dir> [seconds to wait first]
#
# It writes <dir>/action.log, the log of the old pod (kd-old-pod.log), the log of the new pod
# (kd-new-pod.log), and then <dir>/action.done.
set -u
D=$1
L="$D/action.log"
st() { printf '%s %s\n' "$EPOCHREALTIME" "$*" >>"$L"; }
unit() { systemctl show "$1" -p MainPID -p NRestarts -p ActiveEnterTimestamp --value | tr '\n' ' '; }
K=(kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system)

sleep "${2:-3}"
st "info containerd before: $(unit containerd)"
st "info kubelet before: $(unit kubelet)"
old=$("${K[@]}" get pods -l name=kata-deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
st "info old pod: $old"
if [ -z "$old" ]; then
  st "ABORT no pod of the DaemonSet kata-deploy"
  touch "$D/action.done"
  exit 1
fi
# Follow the log of the old pod until the pod ends. It shows what the pod does at SIGTERM.
"${K[@]}" logs -f "$old" --all-containers --timestamps >"$D/kd-old-pod.log" 2>&1 &

st action-start kubectl rollout restart daemonset/kata-deploy
"${K[@]}" rollout restart daemonset/kata-deploy >>"$D/rollout.log" 2>&1
st "action-returned rc=$?"
"${K[@]}" rollout status daemonset/kata-deploy --timeout=600s >>"$D/rollout.log" 2>&1
st "rollout-done rc=$?"
new=$("${K[@]}" get pods -l name=kata-deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
st "info new pod: $new"
"${K[@]}" logs "$new" --all-containers --timestamps >"$D/kd-new-pod.log" 2>&1
st "info containerd after: $(unit containerd)"
st "info kubelet after: $(unit kubelet)"
touch "$D/action.done"
