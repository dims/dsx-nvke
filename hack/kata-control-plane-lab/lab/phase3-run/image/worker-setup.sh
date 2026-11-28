#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Image build step of the worker image (Dockerfile.worker). It runs in the build container.
#   1. It checks what the container backend of the simulator and the join token method need from
#      the image. The build stops at the first thing that is absent.
#   2. It writes the drop-in of the agent unit that keeps --disable-mlx5-rescan.
#   3. It imports the container images of /tmp/p3-images into the containerd store of the image.
set -eu
UNIT=/etc/systemd/system/nvke-agent.service
DROPIN=$UNIT.d/zz-p3-no-mlx5-rescan.conf
IMAGES=/tmp/p3-images
fail() { echo "ERROR: $*"; exit 1; }
have() { [ -e "$1" ] || fail "the image has no $1 ($2)"; }

# --- 1. what the simulator and the method need ------------------------------------------------
# The simulator starts the container with "/bin/sh -c <its entry command>", which ends with
# "exec /usr/local/bin/entrypoint /sbin/init" (controller/nico-sim/internal/container/service.go:33-42).
have /bin/sh "the entry command of the simulator"
have /usr/local/bin/entrypoint "the entry point of the kind node image"
have /sbin/init "systemd"
command -v mount >/dev/null || fail "no mount program (the entry command binds the boot ID)"
# The simulator applies the bootstrap data with docker exec and writes a status file. The agent
# asks "cloud-init status", and the shim of the image reads that file.
have /usr/local/bin/cloud-init "the cloud-init shim"
grep -q 'nico-containers/cloud-init/status' /usr/local/bin/cloud-init || fail "/usr/local/bin/cloud-init is not the shim that reads the status file of the simulator"
command -v python3 >/dev/null || fail "no python3 (the simulator reads the EK certificate with it, and the network unit is a python program)"
# The units of a container node.
have /usr/local/sbin/prepare-container-network "the network unit of a container node"
have /etc/systemd/system/nke-container-network.service "the network unit of a container node"
have /usr/bin/kubeadm.real "the kubeadm wrapper of a container node"
grep -q 'NKE_OVS_DATAPATH_TYPE=system' "$UNIT.d/container-ovs.conf" || fail "the agent unit has no kernel datapath setting of a container node"
# The guard of the machine: the Open vSwitch unit stops when the kernel module is absent.
grep -q 'modprobe openvswitch' /etc/systemd/system/ovs-vswitchd.service.d/no-rmmod-bridge.conf || fail "the guard of the Open vSwitch unit is absent"
# The OVN images come from a package file of the base image. A node of the lab cannot pull.
[ -s /usr/lib/nvke/e2e/cni-images.deb ] || fail "the base image has no OVN image package (/usr/lib/nvke/e2e/cni-images.deb)"
have /etc/systemd/system/multi-user.target.wants/nke-container-cni-images.service "the unit that installs the OVN image package"
# The join token method: the SPIRE agent does not wait for a TPM.
if grep -q 'swtpm-local' /etc/systemd/system/spire-agent.service.d/override.conf; then fail "the base image is built for the TPM method (the SPIRE agent needs swtpm-local.service)"; fi
[ ! -e /etc/systemd/system/multi-user.target.wants/swtpm-local.service ] || fail "the base image starts swtpm-local.service (TPM method)"

# --- 2. the drop-in of the agent unit ------------------------------------------------------------
# It replaces the ExecStart line. Stop if the unit of the base image is not the unit that this
# step knows, and if the agent binary does not know the flag.
grep -q -x 'ExecStart=/usr/local/bin/nvke-agent \$AGENT_ARGS' "$UNIT" || fail "$UNIT has another ExecStart line than this build expects"
/usr/local/bin/nvke-agent --help >/tmp/p3-agent-help.txt 2>&1 || true
grep -q -E '^[[:space:]]+-disable-mlx5-rescan([[:space:]]|$)' /tmp/p3-agent-help.txt || fail "the agent binary has no flag --disable-mlx5-rescan"
rm -f /tmp/p3-agent-help.txt
mkdir -p "$UNIT.d"
cat >"$DROPIN" <<'UNITEOF'
# Made at image build time by worker-setup.sh (phase 3).
# NVKE replaces /etc/default/nvke-agent with its bootstrap data, and its AGENT_ARGS do not have
# --disable-mlx5-rescan. This container is privileged and runs on the kernel of the machine, so
# the agent must never run the mlx5 rescan script (it removes PCI devices and scans the bus).
[Service]
ExecStart=
ExecStart=/usr/local/bin/nvke-agent $AGENT_ARGS --disable-mlx5-rescan
UNITEOF
chmod 0644 "$DROPIN"

# --- 3. the container images --------------------------------------------------------------------
# Into the containerd store of the image, not unpacked, as kind does it for a node image.
# containerd unpacks an image at its first use. The same step as in the pod image
# (p2-image/Dockerfile).
count=0
for f in "$IMAGES"/*.tar; do if [ -e "$f" ]; then count=$((count + 1)); fi; done
if [ "$count" -gt 0 ]; then
  containerd >/tmp/p3-build-containerd.log 2>&1 &
  pid=$!
  i=0
  until ctr version >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 30 ]; then cat /tmp/p3-build-containerd.log; fail "containerd did not start in the build container"; fi
    sleep 1
  done
  for f in "$IMAGES"/*.tar; do ctr -n k8s.io images import --no-unpack --platform linux/amd64 "$f"; done
  # The DNS cache DaemonSet of NVKE names its image by digest.
  ctr -n k8s.io images tag --force registry.k8s.io/dns/k8s-dns-node-cache:1.26.8 \
    registry.k8s.io/dns/k8s-dns-node-cache@sha256:bc6e64e2c85956af2fcc0aa720086410d41b4f31f378c9a92646fecc85cd4739
  ctr -n k8s.io images ls -q | grep -E 'registry.k8s.io/pause:3.10.2$' || fail "no image pause:3.10.2 in the store"
  ctr -n k8s.io images ls -q | grep -E 'k8s-dns-node-cache' || fail "no DNS cache image in the store"
  kill "$pid"
  wait "$pid" || true
  rm -rf /run/containerd /tmp/p3-build-containerd.log
elif [ "${ALLOW_NO_INNER_IMAGES:-0}" = 1 ]; then
  echo "WARNING: no image file in $IMAGES. This image is for a build check only. A worker of it cannot start a pod in the lab"
else
  fail "no image file in $IMAGES (pause-3.10.2.tar and k8s-dns-node-cache.tar)"
fi
rm -rf "$IMAGES"

echo "== facts of the worker image"
echo "agent: $(/usr/local/bin/nvke-agent --version 2>&1 | head -1), sha256 $(sha256sum /usr/local/bin/nvke-agent | cut -d' ' -f1)"
echo "agent arguments of the image (NVKE replaces this file): $(grep '^AGENT_ARGS' /etc/default/nvke-agent)"
echo "drop-ins of the agent unit: $(ls "$UNIT.d" | tr '\n' ' ')"
echo "ExecStart of the drop-in: $(grep '^ExecStart=/' "$DROPIN")"
echo "kubelet extra arguments: $(cat /etc/default/kubelet)"
echo "OVN image package: $(stat -c %s /usr/lib/nvke/e2e/cni-images.deb) bytes"
echo "machine ID file of D-Bus in /var: $(ls -l /var/lib/dbus/machine-id 2>&1 | cut -c1-80)"
