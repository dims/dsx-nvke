#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# DIAGNOSTIC, BY HAND, not a part of the flow of NVKE or of the provider.
# NVKE gets the join strings from the oldest joined control plane node (kubeadm_join.go:216-231),
# and the agent of that node runs "kubeadm init phase upload-certs --upload-certs", with "--config"
# only when /tmp/kubeadm-init-config.yaml exists (agent.go:50-51, 1596-1602). That file exists only
# on the node of kubeadm init, and /tmp is new in each pod. Without it kubeadm takes the address of
# the interface with the default route, which is the pod IP here and is not in the certificate of
# the API server. This script writes a small InitConfiguration with the node address into that
# path, in the pod of one Machine, and records the step.
# Usage: LOG_DIR=<run folder> init-config-by-hand.sh <machine name> [show]
set -euo pipefail
. /root/kata-cp/bin/env.sh
m=${1:?machine}
k() { docker exec kata-bb-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
ip=$(k -n nvke-system get podvmmachine "$m" -o jsonpath='{.status.address}')
echo "$m ($ip): /tmp now: $(k -n d exec "$m" -- sh -c 'ls /tmp | tr "\n" " "')"
[ "${2:-}" = show ] && exit 0
k -n d exec "$m" -- sh -c "printf 'apiVersion: kubeadm.k8s.io/v1beta4\nkind: InitConfiguration\nlocalAPIEndpoint:\n  advertiseAddress: $ip\n  bindPort: 6443\n' > /tmp/kubeadm-init-config.yaml; ls -la /tmp/kubeadm-init-config.yaml"
echo "$(date -u +%FT%TZ) BY HAND (diagnostic): /tmp/kubeadm-init-config.yaml with localAPIEndpoint.advertiseAddress $ip on $m" | tee -a "${LOG_DIR:-$W/logs/p2s6/run-1}/by-hand.txt"
