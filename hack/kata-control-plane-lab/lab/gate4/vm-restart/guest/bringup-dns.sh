#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Bring up the three replica control plane of gate 4 in the VM with the DNS option
# (ETCD_PEER_DNS=1, ETCD_SAN_SKIP=0, ETP=Local), from empty volumes.
set -euo pipefail
. /opt/vm-restart/env.sh
export LOG_DIR=${LOG_DIR:-/var/lib/vm-restart/logs/bringup-dns}
R=/opt/vm-restart/gate4/run.sh
date -u +%FT%TZ
free -g | sed -n 2p
$R services
$R node-up a
$R init
$R node-up b
$R join b
$R node-up c
$R join c
$R versions
$R check 3-after-join
$R peercheck after-join
$R reach 6-after-join
free -g | sed -n 2p
date -u +%FT%TZ
echo "BRINGUP DONE"
