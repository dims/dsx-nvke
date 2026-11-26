#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, test 2: restart the kubelet in the kind node. lib.sh runs this file as the systemd
# unit g5-action of the node.
#
#   action-kubelet.sh <dir> [seconds to wait first]
#
# The kubelet unit of a kind node does not start while the root cgroup of the node holds a
# process (ExecStartPre, /kind/bin/create-kubelet-cgroup-v2.sh). On the running node the root
# cgroup is empty, and a "docker exec" process is in /init.scope (measured on 2026-11-26).
# This script still reads the root cgroup first. It waits up to 20 s for an empty root cgroup,
# and it stops with the line ABORT when the cgroup stays in use. That rule is specific to a
# kind node.
#
# It writes <dir>/action.log (lines "<time> <name> <detail>") and then <dir>/action.done.
set -u
D=$1
L="$D/action.log"
st() { printf '%s %s\n' "$EPOCHREALTIME" "$*" >>"$L"; }
unit() { systemctl show "$1" -p MainPID -p NRestarts -p ActiveEnterTimestamp --value | tr '\n' ' '; }
K=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=3s)

sleep "${2:-3}"
p=x
for _ in $(seq 1 100); do
  p=$(grep -v '^0$' /sys/fs/cgroup/cgroup.procs | tr '\n' ' ')
  [ -z "$p" ] && break
  sleep 0.2
done
if [ -n "$p" ]; then
  for pid in $p; do st "info root cgroup process $pid: $(ps -o args= -p "$pid" 2>/dev/null | cut -c1-160)"; done
  st "ABORT the root cgroup of the node is not empty: [$p]. No restart."
  touch "$D/action.done"
  exit 1
fi
st "info root cgroup processes: []"
st "info containerd before: $(unit containerd)"
st "info kubelet before: $(unit kubelet)"
old=$(systemctl show kubelet -p MainPID --value)
st "info node lease before: $("${K[@]}" -n kube-node-lease get lease "$(hostname)" -o jsonpath='{.spec.renewTime}' 2>/dev/null)"

t_start=$EPOCHREALTIME
st action-start systemctl restart kubelet
systemctl restart kubelet
st "action-returned rc=$?"
for _ in $(seq 1 300); do
  new=$(systemctl show kubelet -p MainPID --value)
  if [ "$(systemctl is-active kubelet)" = active ] && [ "$new" != "$old" ] && [ "$new" != 0 ]; then
    st "kubelet-active pid=$new"
    break
  fi
  sleep 0.2
done
for _ in $(seq 1 300); do
  if [ "$(curl -s --max-time 1 http://127.0.0.1:10248/healthz 2>/dev/null)" = ok ]; then
    st kubelet-healthz-ok
    break
  fi
  sleep 0.2
done
# The first renewal of the node lease by the new kubelet.
for _ in $(seq 1 300); do
  lease=$("${K[@]}" -n kube-node-lease get lease "$(hostname)" -o jsonpath='{.spec.renewTime}' 2>/dev/null)
  if [ -n "$lease" ] && awk -v a="$(date -d "$lease" +%s.%N 2>/dev/null)" -v b="$t_start" 'BEGIN {exit !(a > b)}'; then
    st "node-lease-renewed $lease"
    break
  fi
  sleep 0.5
done
st "info kubelet after: $(unit kubelet)"
st "info containerd after: $(unit containerd)"
st "info kubelet start attempts in the journal since the action: $(journalctl --no-pager -u kubelet --since '-90s' 2>/dev/null | grep -c -E 'Started kubelet|Failed with result|ERROR: this script needs')"
touch "$D/action.done"
