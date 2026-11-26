# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Variables for the runc baseline. Use: ( . ./env-runc.sh; LOG_DIR=... ./run.sh full )
export RUNTIME_CLASS=
export VAR_LOOP=/dev/loop20 ETCD_LOOP=/dev/loop24
export P1_OVS_DATAPATH=netdev
export P1_KMOD_NOOP=1           # guard: ovs-ctl can never run modprobe or rmmod on the host kernel
