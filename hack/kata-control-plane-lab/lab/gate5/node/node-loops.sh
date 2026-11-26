#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: the loops that run in the kind node, each as a systemd unit (see lib.sh, loops_start).
#
#   node-loops.sh readyz <dir> <interval> <shared ip> <ip a> <ip b> <ip c>
#       One loop for each address. Each call is a new TCP and TLS connection to /readyz.
#       A line of readyz-<target>.log:
#         <start time of the call> <target> <http code> <seconds> <curl exit code> <curl error text>
#       The http code is 000 when no answer came.
#   node-loops.sh k8s <dir> <interval> <namespace> <node name>
#       A line of k8s.log: <time> <kind> <value>. The kinds:
#         pods      name|uid|pod IP|restart count|ready|container ID|phase of each node pod
#         eps       address=ready of each endpoint of the shared Service cp-api
#         node      Ready condition, then the labels of the node
#         handlers  the runtime handlers that the node reports
#         units     main PID, restart counter and state of containerd and of the kubelet
#         kata      pid:start time:program of each Kata process (shim, virtiofsd, hypervisor)
#         kd        the kata-deploy pods and jobs
#       analyze.sh prints a line only when its value changes.
set -u
mode=$1
D=$2
I=$3
shift 3

readyz_loop() { # readyz_loop <target> <ip>
  local name=$1 ip=$2 t out
  while :; do
    t=$EPOCHREALTIME
    out=$(curl -sk --max-time 2 -o /dev/null -w '%{http_code} %{time_total} %{exitcode} %{errormsg}' "https://$ip:6443/readyz" 2>/dev/null)
    printf '%s %s %s\n' "$t" "$name" "$out"
    sleep "$I"
  done >>"$D/readyz-$name.log" 2>&1
}

k8s_loop() {
  local ns=$1 node=$2 t p pid exe st x
  local K=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=3s)
  while :; do
    t=$EPOCHREALTIME
    printf '%s pods %s\n' "$t" "$("${K[@]}" -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.uid}{"|"}{.status.podIP}{"|"}{.status.containerStatuses[0].restartCount}{"|"}{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].containerID}{"|"}{.status.phase}{" "}{end}' 2>&1 | tr '\n' ' ')"
    printf '%s eps %s\n' "$t" "$("${K[@]}" -n "$ns" get endpointslices -l kubernetes.io/service-name=cp-api -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"="}{.conditions.ready}{" "}{end}' 2>&1 | tr '\n' ' ')"
    # One call for the node: the Ready condition and the labels, then (after "@@") the handlers.
    x=$("${K[@]}" get node "$node" -o jsonpath='{"ready="}{.status.conditions[?(@.type=="Ready")].status}{" "}{.metadata.labels}{"@@"}{.status.runtimeHandlers[*].name}' 2>&1 | tr '\n' ' ')
    printf '%s node %s\n' "$t" "${x%%@@*}"
    printf '%s handlers %s\n' "$t" "${x#*@@}"
    printf '%s units containerd=%s kubelet=%s\n' "$t" \
      "$(systemctl show containerd -p MainPID -p NRestarts -p ActiveState --value | tr '\n' '/')" \
      "$(systemctl show kubelet -p MainPID -p NRestarts -p ActiveState --value | tr '\n' '/')"
    p=""
    for pid in $(ps -eo pid=,comm= | awk '$2 ~ /^(containerd-shim|virtiofsd|cloud-hyperviso|qemu-system)/ {print $1}'); do
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
      case "$exe" in /opt/kata*) ;; *) continue ;; esac
      st=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f20)
      p="$p $pid:$st:${exe// /_}"
    done
    printf '%s kata%s\n' "$t" "$p"
    printf '%s kd %s\n' "$t" "$("${K[@]}" -n kube-system get pods,jobs --no-headers 2>&1 |
      awk '/kata-deploy/ {if ($1 ~ /^job/) printf "%s,%s,%s ", $1, $2, $3; else printf "%s,%s,%s,%s ", $1, $2, $3, $4}')"
    # The calls above take some tenths of a second. Sleep for the rest of the interval.
    sleep "$(awk -v s="$t" -v e="$EPOCHREALTIME" -v i="$I" 'BEGIN {d = i - (e - s); print (d > 0.05 ? d : 0.05)}')"
  done >>"$D/k8s.log" 2>&1
}

case "$mode" in
  readyz)
    readyz_loop shared "$1" &
    readyz_loop a "$2" &
    readyz_loop b "$3" &
    readyz_loop c "$4" &
    wait
    ;;
  k8s) k8s_loop "$1" "$2" ;;
  *)
    echo "unknown mode $mode" >&2
    exit 1
    ;;
esac
