#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2, part 2: one control plane node as a pod, made with the files of gate 1 (lab/gate1/run.sh).
# The Kata pod and the runc pod use the same two loop devices, one after the other:
# var-1 (/dev/loop20) for /var and etcd-1 (/dev/loop24) for /var/lib/etcd.
# Before each start the script discards the two devices, so the two backing files are sparse again
# and the two runtimes start from the same state.
#
# Usage: cp.sh <kata|runc> <up|down>
set -euo pipefail

TARGET=${1:?kata or runc}
STEP=${2:?up or down}
KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
GATE1="$(cd "$(dirname "$0")/../gate1" && pwd)"

export NS=gate2-$TARGET NAME=cp CPU=${CPU:-4} MEMORY=${MEMORY:-8Gi}
export VAR_LOOP=/dev/loop20 ETCD_LOOP=/dev/loop24
export LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate2/cp-$TARGET}
case "$TARGET" in
  kata)
    # The class of record has the exec fix and the kill fix, so the wrapper needs no "init" cgroup
    # step, and systemd keeps its default stop timeout.
    export RUNTIME_CLASS=${RUNTIME_CLASS:-kata-clh-runtime-rs-fix-direct} LIB_MODULES=0 SNAPSHOTTER=overlayfs
    export IGNORE_PREFLIGHT= STOP_TIMEOUT= G1_SKIP=init-cgroup
    export KERNEL_CONFIG=/scratch/kata-cp/logs/kata-guest-kernel-config-6.18.62-211.txt
    ;;
  runc)
    export RUNTIME_CLASS= LIB_MODULES=1 SNAPSHOTTER= STOP_TIMEOUT= G1_SKIP=
    ;;
  *) echo "unknown target $TARGET"; exit 1 ;;
esac

grep -q "^$VAR_LOOP /scratch/kata-cp/disks/var-1.img " /scratch/kata-cp/disks/loop-map.txt
grep -q "^$ETCD_LOOP /scratch/kata-cp/disks/etcd-1.img " /scratch/kata-cp/disks/loop-map.txt

case "$STEP" in
  up)
    "$GATE1/run.sh" wipe
    docker exec "$KIND_NODE" blkdiscard -f "$VAR_LOOP"
    docker exec "$KIND_NODE" blkdiscard -f "$ETCD_LOOP"
    echo "backing files after discard (kB in use): $(du -k /scratch/kata-cp/disks/var-1.img /scratch/kata-cp/disks/etcd-1.img | tr '\n' ' ')"
    "$GATE1/run.sh" up
    "$GATE1/run.sh" versions
    "$GATE1/run.sh" check 1-after-init
    ;;
  down)
    "$GATE1/run.sh" logs || true
    "$GATE1/run.sh" down
    "$GATE1/run.sh" wipe
    ;;
  *) echo "unknown step $STEP"; exit 1 ;;
esac
