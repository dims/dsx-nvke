# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Settings of the gate 4 scripts in the Lima VM kata-restart. Source this file.
# Second design: the etcd peer check stays on (ETCD_PEER_DNS=1). The file env.sh.skipflag has
# the settings of the first test.
export NS=gate4
export KIND_NODE=kata-vm-control-plane
export RUNTIME_CLASS=kata-clh-runtime-rs-fix-direct
export G1_SKIP=init-cgroup        # the patched agent has the exec fix
export STOP_TIMEOUT=              # the systemd default, as in the lab run of record
export ETCD_PEER_DNS=1            # headless Service cp-peer, its DNS name in each etcd peer certificate
export ETCD_SAN_SKIP=0            # no etcd flag peer-skip-client-san-verification
export ETP=Local                  # the Service of a replica keeps the source address of a call
export KEEP=1
export CPU=2                      # lab: 4
export MEMORY=4Gi                 # lab: 6Gi
export OWNER=sts
export LOOP_MAP=/var/lib/vm-restart/disks/loop-map.txt
export SECRET_DIR=/var/lib/vm-restart/secrets
export KERNEL_CONFIG=/opt/vm-restart/kata-guest-kernel-config-6.18.62-211.txt
export KUBECONFIG=/var/lib/vm-restart/kubeconfig
