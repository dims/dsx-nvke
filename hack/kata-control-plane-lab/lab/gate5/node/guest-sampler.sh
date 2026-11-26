#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: the sampler that runs in the guest of one replica, as the systemd unit g5-guest of the
# node pod. It does not depend on containerd or the kubelet of the host, so it gives data also
# while they restart.
#
#   guest-sampler.sh <dir>
#
# Files:
#   heartbeat.log     each 0.2 s: <guest clock> <guest uptime>. A hole shows that the guest stopped.
#   etcd.log          each second, from the etcd member of this replica (gRPC gateway on 127.0.0.1):
#                       <time> status  {"member":..,"leader":..,"term":..,"index":..,"rev":..}
#                       <time> members [{"ID":..,"name":..,"peer":..,"learner":..}, ...]
#                     "ERR" in place of the JSON when the call failed.
#   local-readyz.log  each second: /readyz of the API server of this replica, on 127.0.0.1.
set -u
D=$1
mkdir -p "$D"
: >"$D/heartbeat.log"
: >"$D/etcd.log"
: >"$D/local-readyz.log"
C=(--cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key)

heartbeat() {
  local up
  while :; do
    read -r up _ </proc/uptime
    printf '%s %s\n' "$EPOCHREALTIME" "$up"
    sleep 0.2
  done >>"$D/heartbeat.log" 2>&1
}

etcd() {
  local t s m
  while :; do
    t=$EPOCHREALTIME
    s=$(curl -s --max-time 2 "${C[@]}" -X POST -d '{}' https://127.0.0.1:2379/v3/maintenance/status 2>/dev/null |
      jq -c '{member: .header.member_id, leader: .leader, term: .raftTerm, index: .raftIndex, rev: .header.revision}' 2>/dev/null)
    m=$(curl -s --max-time 2 "${C[@]}" -X POST -d '{}' https://127.0.0.1:2379/v3/cluster/member/list 2>/dev/null |
      jq -c '[.members[] | {ID, name, peer: .peerURLs[0], learner: (.isLearner // false)}] | sort_by(.name)' 2>/dev/null)
    printf '%s status %s\n' "$t" "${s:-ERR}"
    printf '%s members %s\n' "$t" "${m:-ERR}"
    sleep 1
  done >>"$D/etcd.log" 2>&1
}

local_readyz() {
  local t
  while :; do
    t=$EPOCHREALTIME
    printf '%s local %s\n' "$t" "$(curl -sk --max-time 2 -o /dev/null -w '%{http_code} %{time_total} %{exitcode} %{errormsg}' https://127.0.0.1:6443/readyz 2>/dev/null)"
    sleep 1
  done >>"$D/local-readyz.log" 2>&1
}

heartbeat &
etcd &
local_readyz &
wait
