#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Before block D: remove the inner clusters of blocks C2 and C3 (they hold the 12 loop devices and CPU).
. /root/kata-cp/bin/env.sh
cd "$W"
(
  . c3/env-c3.sh
  export LOG_DIR=$W/logs/c3/down-before-d SEC=$W/secrets/c3-down
  c3/dry/run.sh down; c3/dry/run.sh wipe
) >logs/d-cleanup-c3.log 2>&1
echo "c3 down: exit $?"
(
  export FIXED=1 PV_NODES=all INNER_CNI=kindnet ETCD_LISTEN=default ETCD_SAN_SKIP=0 NS=c2
  . bin/env-gate4.sh
  export LOG_DIR=$G4_LOGS/c2-down-before-d
  gate4/run.sh down; gate4/run.sh wipe
) >logs/d-cleanup-c2.log 2>&1
echo "c2 down: exit $?"
kubectl get ns --no-headers | awk '{print $1}' | tr '\n' ' '; echo
kubectl get pv --no-headers 2>/dev/null | wc -l
docker exec kata-bb-control-plane sh -c 'losetup -a | grep -c volumeDevices'
echo "CLEANUP DONE"
