# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Variables for a Kata run with the class of record. Use: ( . ./env-kata.sh; LOG_DIR=... ./run.sh full )
export RUNTIME_CLASS=kata-clh-runtime-rs-fix-direct
export G1_SKIP=init-cgroup      # the patched Kata agent needs no "init" cgroup
export STOP_TIMEOUT=            # the systemd default, as the gate 4 runs with this class
export VAR_LOOP=/dev/loop21 ETCD_LOOP=/dev/loop25
export KERNEL_CONFIG=/scratch/kata-cp/logs/kata-guest-kernel-config-6.18.62-211.txt
export P1_OVS_DATAPATH=netdev
