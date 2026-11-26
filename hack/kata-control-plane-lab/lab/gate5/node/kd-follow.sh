#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: follow the logs of each kata-deploy pod in kube-system, one file for each container.
# lib.sh runs this file as the systemd unit g5-kdlogs of the node around an uninstall. The pods
# of a cleanup Job and the pod of the DaemonSet go away at the end of an uninstall, and their
# logs go with them.
#
#   kd-follow.sh <output folder>
#
# Each 0.5 s it looks for containers (init containers too) that started, and it starts one
# "kubectl logs -f" for each. The unit stops with "systemctl stop".
set -u
D=$1
mkdir -p "$D"
K=(kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system --request-timeout=5s)
declare -A seen
JP='{range .items[*]}{.metadata.name}{"|"}{range .status.initContainerStatuses[*]}{.name}{"="}{.state.running.startedAt}{.state.terminated.reason}{";"}{end}{range .status.containerStatuses[*]}{.name}{"="}{.state.running.startedAt}{.state.terminated.reason}{";"}{end}{"\n"}{end}'
while :; do
  # A line of the list: <pod>|<container>=<start time or end reason>;... A container with an
  # empty value did not start yet.
  while read -r pod c; do
    [ -n "$pod" ] && [ -n "$c" ] || continue
    [ -z "${seen[$pod/$c]:-}" ] || continue
    seen[$pod/$c]=1
    kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system logs -f "$pod" -c "$c" --timestamps >"$D/$pod.$c.log" 2>&1 &
  done < <("${K[@]}" get pods -o jsonpath="$JP" 2>/dev/null | awk -F'|' '$1 ~ /^kata-deploy/ {n = split($2, a, ";"); for (i = 1; i <= n; i++) {split(a[i], b, "="); if (b[1] != "" && b[2] != "") print $1, b[1]}}')
  sleep 0.5
done
