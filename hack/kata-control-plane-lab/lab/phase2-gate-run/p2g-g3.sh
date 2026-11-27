#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# G3: a cluster with the older Kubernetes version and one worker, then the upgrade of the control
# plane through the NVKE API (version and machine template in one request), then the worker pool.
# Usage (detached): OLD_VER=1.35.5 OLD_IMG=<image> setsid nohup p2-gate/p2g-g3.sh <label> >logs/p2g/<label>-g3.out 2>&1 &
label=${1:?label}
. /root/kata-cp/bin/env.sh
OLD_VER=${OLD_VER:?}
OLD_IMG=${OLD_IMG:?}
NEW_VER=${NEW_VER:-1.36.4}
NEW_IMG=${NEW_IMG:-docker.io/library/nvke-node-podvm:bcc4376f-p5}
export LOG_DIR=$W/logs/p2g/$label DISK_LOG=$W/logs/p2g/disk.txt
export K8S_VERSION=$OLD_VER IMG_CLUSTER=$OLD_IMG IMG_WORKER=$OLD_IMG
mkdir -p "$LOG_DIR"
cd "$W/p2-gate" || exit 1
echo "== $(utc) G3 in $label: Kubernetes $OLD_VER (image ${OLD_IMG##*:}) to $NEW_VER (image ${NEW_IMG##*:})"
pgrep -f "storage-loop[.]sh" >/dev/null || (setsid nohup "$W/p2-replace/storage-loop.sh" >>"$W/logs/p2g/storage-loop.out" 2>&1 &)
WAIT=1 "$W/p2-replace/disk.sh" "$label cluster with Kubernetes $OLD_VER"
./run.sh flow; rc=$?; echo "flow exit code: $rc"
if [ "$rc" != 0 ]; then echo "== $(utc) the cluster with $OLD_VER did not come up. Stop of G3 in $label"; exit 1; fi
./run.sh wait-good 3 300; echo "wait-good exit code: $?"
./run.sh pool-post workers wk 1; echo "pool-post exit code: $?"
./run.sh pool-wait 1 old; echo "pool-wait exit code: $?"
./run.sh health old; echo "health old exit code: $?"
./run.sh w2 old; echo "w2 old exit code: $?"
./run.sh facts old >/dev/null
./run.sh upgrade up "$NEW_VER" "$NEW_IMG"; echo "upgrade exit code: $?"
./run.sh health after-upgrade; echo "health after-upgrade exit code: $?"
./run.sh w2 after-upgrade; echo "w2 after-upgrade exit code: $?"
./run.sh pool-upgrade wp "$NEW_VER" "$NEW_IMG"; echo "pool-upgrade exit code: $?"
export IMG_WORKER=$NEW_IMG
./run.sh worker-delete wp; echo "worker-delete exit code: $?"
./run.sh w1 final; echo "w1 final exit code: $?"
./run.sh health final; echo "health final exit code: $?"
./run.sh w2 final; echo "w2 final exit code: $?"
./run.sh facts final >/dev/null
echo "== $(utc) end of G3 in $label"
