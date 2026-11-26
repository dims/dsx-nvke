#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: the state of one replica, read in its guest. It only reads. lib.sh sends it to
# "bash -s" in the node pod. Lines that start with "KV " hold the values that a test must not
# change. "INFO" lines are for the record.
C=(--cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt --key /etc/kubernetes/pki/etcd/healthcheck-client.key)
IK=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=10s)

echo "KV boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "KV guest_kernel=$(uname -r)"
echo "KV machine_id=$(cat /etc/machine-id)"
echo "INFO guest clock $EPOCHREALTIME, uptime $(cut -d' ' -f1 /proc/uptime) s, $(nproc) CPUs, $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) MiB"

s=$(curl -s --max-time 5 "${C[@]}" -X POST -d '{}' https://127.0.0.1:2379/v3/maintenance/status 2>/dev/null)
echo "KV etcd_member_id=$(jq -r '.header.member_id' <<<"$s" 2>/dev/null)"
echo "KV etcd_leader=$(jq -r '.leader' <<<"$s" 2>/dev/null)"
echo "KV etcd_raft_term=$(jq -r '.raftTerm' <<<"$s" 2>/dev/null)"
echo "INFO etcd status: $s"
m=$(curl -s --max-time 5 "${C[@]}" -X POST -d '{}' https://127.0.0.1:2379/v3/cluster/member/list 2>/dev/null)
echo "KV etcd_members=$(jq -c '[.members[] | {ID, name, peer: .peerURLs[0], client: .clientURLs[0], learner: (.isLearner // false)}] | sort_by(.name)' <<<"$m" 2>/dev/null)"

echo "KV inner_nodes=$("${IK[@]}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"/"}{.metadata.uid}{"/"}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}' 2>&1)"
echo "INFO nodes of the inner cluster:"
"${IK[@]}" get nodes -o wide 2>&1 | sed 's/^/INFO   /'
echo "INFO local /readyz: $(curl -sk --max-time 5 -o /dev/null -w '%{http_code} %{time_total}' https://127.0.0.1:6443/readyz)"

# The containers of the inner control plane. A new container ID or a higher attempt shows that
# a component of the control plane started again in the guest.
echo "KV inner_containers=$(crictl ps -o json 2>/dev/null | jq -r '[.containers[] | "\(.metadata.name):\(.id[0:12]):\(.metadata.attempt)"] | sort | join(" ")' 2>/dev/null)"
echo "INFO containers in the guest:"
crictl ps -a 2>&1 | sed 's/^/INFO   /'
echo "KV inner_units=$(systemctl show containerd kubelet -p MainPID --value 2>/dev/null | tr '\n' ' ')"
echo "INFO last lines of the guest kernel log:"
dmesg 2>/dev/null | tail -15 | sed 's/^/INFO   /'
