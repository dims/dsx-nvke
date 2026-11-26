#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Host setup for the Kata lab. It needs sudo for modprobe and losetup.
# It changes no Docker configuration. Each step does nothing if its result exists.
#
# Removal:
#   kind delete cluster --name kata-cp
#   docker network rm kata-cp
#   for d in $(sudo losetup -l -n -O NAME,BACK-FILE | awk '$2 ~ "^/scratch/kata-cp/disks/" {print $1}'); do sudo losetup -d "$d"; done
#   rm -f /scratch/kata-cp/disks/*.img
#   sudo modprobe -r vhost_vsock vhost_net
set -euo pipefail

WORK=/scratch/kata-cp
NET=kata-cp
CLUSTER=kata-cp
NODE_IMAGE=kindest/node:v1.36.4
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1. kernel modules for Kata (not kept after a restart)"
sudo modprobe vhost_vsock
sudo modprobe vhost_net
lsmod | grep -E '^vhost' || true

echo "== 2. sparse files and loop devices (name:size in GB)"
for spec in var-0:30 var-1:30 var-2:30 var-3:30 etcd-0:10 etcd-1:10 etcd-2:10 etcd-3:10 fio-0:10 fio-1:10 spare-0:20 spare-1:20; do
  name=${spec%%:*}
  size=${spec##*:}
  f=$WORK/disks/$name.img
  [ -f "$f" ] || truncate -s "${size}G" "$f"
  if ! sudo losetup -j "$f" | grep -q .; then
    sudo losetup --find --show --direct-io=on "$f"
  fi
done
sudo losetup -l -n -O NAME,BACK-FILE,DIO | awk -v p="$WORK/disks/" 'index($2, p) == 1' | sort -k2 | tee "$WORK/disks/loop-map.txt"

echo "== 3. Docker network with a range that stays free for MetalLB"
# Containers get 172.30.0.0/24. MetalLB gets 172.30.255.200 to 172.30.255.250.
docker network inspect "$NET" >/dev/null 2>&1 || docker network create -d bridge \
  --subnet 172.30.0.0/16 --ip-range 172.30.0.0/24 --gateway 172.30.0.1 \
  -o com.docker.network.bridge.enable_ip_masquerade=true "$NET"

echo "== 4. kind node"
docker image inspect "$NODE_IMAGE" >/dev/null 2>&1 || docker pull "$NODE_IMAGE"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  KIND_EXPERIMENTAL_DOCKER_NETWORK="$NET" kind create cluster --name "$CLUSTER" \
    --image "$NODE_IMAGE" --config "$HERE/kind-config.yaml" \
    --kubeconfig "$WORK/kubeconfig" --wait 180s
fi
chmod 600 "$WORK/kubeconfig"
echo "done"
