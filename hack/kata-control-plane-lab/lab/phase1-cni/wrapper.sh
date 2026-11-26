#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Container command for the NVKE node image (nvke-node, built from kindest/node) in a pod.
# Steps 1 to 4 are a copy of lab/gate1/wrapper.sh at 2026-11-25 16:49 with no change.
# Step 5 is new: what nico-sim does for an NVKE node container with docker exec.
#
# Container command for the kind node image in a pod. It runs as PID 1, before the kind entrypoint.
# It does what Docker and kind do for a node container, and what Kubernetes does not do:
#   1. a private cgroup namespace,
#   2. an empty /run and /tmp at each start, and /var on a volume with the /var content of the image,
#   3. node state outside /var that stays through a container restart.
#   4. in a VM guest (Kata), what a kind node gets from the kernel of its host.
# The pod gives it two raw block devices (volumeDevices) and these variables:
#   G1_VAR_DEV    device for /var            (default /dev/g1-var)
#   G1_ETCD_DEV   device for /var/lib/etcd   (default /dev/g1-etcd)
#   G1_GUEST      1 = the container has its own kernel (a Kata guest)
#   G1_SKIP       test switch: a list of steps to leave out (init-cgroup, sysctl, kmsg)
#   G1_STOP_TIMEOUT  optional: seconds that systemd in the node waits for a unit to stop
# Step 5 uses these inputs:
#   /g1n-spire/agent.conf, /g1n-spire/initial-trust-bundle.pem   from a Secret. Absent in the plaintext run
#   G1N_AGENT_PLAINTEXT   1 = nvke-agent with --disable-mtls (no authentication, first run only)
#   G1N_SKIP_UNITS        test switch: a list of image units to leave out (cni-images)
set -o errexit -o nounset -o pipefail

VAR_DEV=${G1_VAR_DEV:-/dev/g1-var}
ETCD_DEV=${G1_ETCD_DEV:-/dev/g1-etcd}
STATE=/var/lib/g1-state # node state that the image keeps outside /var

log() { echo "WRAP: $*" >&2; }
skip() {
  case " ${G1_SKIP:-} " in *" $1 "*)
    log "TEST: skip $1"
    return 0
    ;;
  esac
  return 1
}

# --- 1. Private cgroup namespace -------------------------------------------------------------
# containerd gives a privileged container the cgroup namespace of the node (cgroup v2).
# Then /sys/fs/cgroup is the cgroup tree of the node, and a kubelet with cgroupRoot /kubelet
# in this container would manage the pod cgroups of the node. Docker gives a kind node a private
# cgroup namespace (--cgroupns=private), and the kind entrypoint depends on it.
if [ -f /sys/fs/cgroup/cgroup.controllers ] && [ "$(cat /proc/self/cgroup)" != "0::/" ]; then
  if [ -n "${G1_CGROUPNS:-}" ]; then
    log "ERROR: the cgroup namespace is still not private: $(cat /proc/self/cgroup)"
    exit 1
  fi
  log "cgroup of PID 1 is $(cut -d: -f3 /proc/self/cgroup). Enter a private cgroup namespace."
  export G1_CGROUPNS=new
  exec unshare --cgroup -- "$0" "$@"
fi
if [ "${G1_CGROUPNS:-}" = new ]; then
  # The old mount shows the tree of the old namespace. A new mount shows the new root.
  umount /sys/fs/cgroup
  mount -t cgroup2 -o rw,nosuid,nodev,noexec,relatime cgroup2 /sys/fs/cgroup
  log "cgroup namespace is private. Controllers: $(cat /sys/fs/cgroup/cgroup.controllers)"
fi
unset G1_CGROUPNS
# A new container must have a cgroup with no child and no old process.
log "cgroup at start: children [$(find /sys/fs/cgroup -mindepth 1 -maxdepth 1 -type d -printf '%f ')] processes [$(tr '\n' ' ' </sys/fs/cgroup/cgroup.procs)]"

# The Kata agent puts each exec process in the cgroup of the container. systemd turns on the
# controllers for the child cgroups, and then the kernel refuses a process in the cgroup of the
# container (EBUSY), so each `kubectl exec` fails. The agent uses the child cgroup "init" if it
# exists. Make it before systemd starts.
if [ "${G1_GUEST:-0}" = 1 ] && ! skip init-cgroup; then
  mkdir -p /sys/fs/cgroup/init
fi

# --- 2. /run, /tmp and the block volumes -----------------------------------------------------
# An emptyDir volume lives as long as the pod. After a container restart it still has the files
# of the old container (shim sockets, container IO folders). A machine start has an empty /run
# and /tmp, so make them empty.
find /run /tmp -xdev -mindepth 1 -delete || log "WARN: could not empty /run and /tmp"
chmod 755 /run
chmod 1777 /tmp

# Make ext4 on a device only if the device has no filesystem signature.
format_if_empty() {
  local dev=$1 label=$2
  if [ ! -b "$dev" ]; then
    log "ERROR: $dev is not a block device"
    exit 1
  fi
  if [ -z "$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)" ]; then
    log "no filesystem on $dev. Make ext4 with label $label."
    mkfs.ext4 -q -L "$label" "$dev"
  fi
}

# /var: on the first start, copy the /var of the image to the volume. Docker does this copy for
# an anonymous volume. The image keeps its pulled images in /var/lib/containerd.
format_if_empty "$VAR_DEV" g1-var
mkdir -p /mnt/g1-var
mount "$VAR_DEV" /mnt/g1-var
if [ ! -e /mnt/g1-var/.g1-var-copied ]; then
  log "first start: copy /var of the image to $VAR_DEV"
  cp -a /var/. /mnt/g1-var/
  touch /mnt/g1-var/.g1-var-copied
fi
umount /mnt/g1-var
mount "$VAR_DEV" /var

# /var/lib/etcd: a new ext4 has a lost+found folder. kubeadm stops when the etcd folder is not
# empty (preflight check DirAvailable--var-lib-etcd), so remove the folder while etcd has no data.
format_if_empty "$ETCD_DEV" g1-etcd
mkdir -p /var/lib/etcd
mount "$ETCD_DEV" /var/lib/etcd
chmod 700 /var/lib/etcd
if [ ! -d /var/lib/etcd/member ] && [ -d /var/lib/etcd/lost+found ]; then
  rmdir /var/lib/etcd/lost+found
fi

# --- 3. Node state outside /var --------------------------------------------------------------
# Kubernetes makes a new container at each restart, so each file outside a volume returns to
# the image content. Keep these paths on the /var volume.
mkdir -p "$STATE/etc-kubernetes" "$STATE/kind"

# /etc/kubernetes: certificates, kubeconfig files and static pod manifests of kubeadm.
cp -an /etc/kubernetes/. "$STATE/etc-kubernetes/"
mount --bind "$STATE/etc-kubernetes" /etc/kubernetes

# /kind: the entrypoint keeps the last node address (old-ipv4) and the product UUID here, and
# reads kubeadm.conf from here when the address changes. The files of the image (bin, manifests,
# version) come from the image at each start. The node files are not in the image, so they stay.
cp -a /kind/. "$STATE/kind/"
mount --bind "$STATE/kind" /kind

# /etc/machine-id: the entrypoint deletes it and makes a new one at each start. In a container,
# systemd takes the ID from the variable container_uuid of PID 1, so keep one UUID for the node.
[ -s "$STATE/machine-uuid" ] || cat /proc/sys/kernel/random/uuid >"$STATE/machine-uuid"
container_uuid=$(cat "$STATE/machine-uuid")
export container_uuid

# --- 4. What a kind node gets from the kernel of its host ------------------------------------
# A Kata guest has the default values of its kernel. The kubelet and systemd need more inotify
# instances than 128. These values are for the whole kernel, so set them in a guest only.
if [ "${G1_GUEST:-0}" = 1 ] && ! skip sysctl; then
  sysctl -q -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576
fi
# kubeadm stops when IP forwarding is off (preflight check FileContent--proc-sys-net-ipv4-ip_forward).
# The value is for the network namespace of the pod. With runc it is 1 from the host.
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ] && ! skip sysctl; then
  sysctl -q -w net.ipv4.ip_forward=1
fi
# The kubelet reads /dev/kmsg. A privileged Kata container has only the default device nodes.
if [ ! -e /dev/kmsg ] && ! skip kmsg; then
  mknod -m 600 /dev/kmsg c 1 11
fi
# The kubeadm check SystemVerification reads the kernel config. If the kernel has no
# /proc/config.gz, take the file that the pod gives in /g1-kernel/config.
if [ -f /g1-kernel/config ] && [ ! -e /proc/config.gz ] && [ ! -e "/boot/config-$(uname -r)" ]; then
  cp /g1-kernel/config "/boot/config-$(uname -r)"
fi

# Optional: the time that systemd in the node waits for a unit to stop (G1_STOP_TIMEOUT, seconds).
# At a node stop, kube-apiserver does not exit while etcd is down, and systemd waits 90 s for it.
# With a lower value the node stops by itself inside the grace period of the pod. A Kata container
# needs that, because a kill from the runtime does not stop a container with systemd in it.
if [ -n "${G1_STOP_TIMEOUT:-}" ]; then
  mkdir -p /etc/systemd/system.conf.d
  printf '[Manager]\nDefaultTimeoutStopSec=%ss\n' "$G1_STOP_TIMEOUT" >/etc/systemd/system.conf.d/g1-stop-timeout.conf
fi

# --- 5. The NVKE node image --------------------------------------------------------------------
# On the infra path the NVKE controller gives a node a cloud-config with three files and one
# command (controller/internal/clients/capi/bootstrap_userdata.go:101-151). nico-sim applies it
# with docker exec after the container start. A pod has no such step, so do it here, before systemd.

# 5a. The SPIRE agent files. /etc/spire-agent is not on a volume, so write the two files at each
# start. NVKE writes them with the owner root:root and the mode 0644. agent.conf holds the join
# token. The agent keeps its key and its SVID in /var/lib/spire-agent, which is on the /var volume.
if [ -f /g1n-spire/agent.conf ]; then
  install -d -m 0755 /etc/spire-agent
  install -m 0644 -o root -g root /g1n-spire/agent.conf /etc/spire-agent/agent.conf
  install -m 0644 -o root -g root /g1n-spire/initial-trust-bundle.pem /etc/spire-agent/initial-trust-bundle.pem
  log "SPIRE agent files are in /etc/spire-agent"
else
  log "no SPIRE files. spire-agent.service restarts in a loop, and nvke-agent needs --disable-mtls."
fi

# 5b. The agent environment file. The unit reads /etc/default/nke-agent first and
# /etc/default/nvke-agent second, so the second file sets AGENT_ARGS. For mTLS the image file is
# correct as it is. For the plaintext run, add --disable-mtls to the arguments of the image.
if [ "${G1N_AGENT_PLAINTEXT:-0}" = 1 ]; then
  sed -i 's/^AGENT_ARGS="/AGENT_ARGS="--disable-mtls /' /etc/default/nvke-agent
  log "PLAINTEXT: nvke-agent has no authentication: $(grep ^AGENT_ARGS /etc/default/nvke-agent)"
fi

# 5c. The cloud-init status file. The image has a cloud-init shim that prints the state from this
# file (hack/capd-kindest-node/scripts/cloud-init-status-shim). nico-sim writes "done" when it has
# applied the cloud-config. The agent preflight with check_cloud_init_status needs "done".
install -d -m 0755 /var/lib/nico-containers/cloud-init
echo "done" >/var/lib/nico-containers/cloud-init/status

# 5d. Test switch: leave out a unit of the image. The unit nke-container-cni-images installs the
# OVN image package at each start, and nvke-agent waits for it. A control plane node with no CNI
# does not need it. The unit has a condition on this file.
case " ${G1N_SKIP_UNITS:-} " in *" cni-images "*)
  rm -f /usr/lib/nvke/e2e/cni-images.deb
  log "TEST: skip nke-container-cni-images.service"
  ;;
esac

# --- 6. Phase 1 step 1: Open vSwitch with the userspace datapath ------------------------------
# Each change below is one that a site can make in its node image. Each one has its own switch,
# so a run can show what fails without it.
#   P1_OVS_DATAPATH     netdev or system: the value of NKE_OVS_DATAPATH_TYPE for nvke-agent. Empty = the image value (system)
#   P1_OVS_NO_MODPROBE  1 = remove the "modprobe openvswitch" step that the image adds to ovs-vswitchd.service
#   P1_TUN              1 = make the device node /dev/net/tun if it is absent
#   P1_KMOD_NOOP        1 = replace ovs-kmod-ctl by a script that does nothing (a guard for the runc baseline)

# 6a. The image sets NKE_OVS_DATAPATH_TYPE=system in nvke-agent.service.d/container-ovs.conf. systemd reads
# the drop-in files in name order, and a later Environment= line for the same name replaces the earlier one.
if [ -n "${P1_OVS_DATAPATH:-}" ]; then
  install -d -m 0755 /etc/systemd/system/nvke-agent.service.d
  printf '[Service]\nEnvironment=NKE_OVS_DATAPATH_TYPE=%s\n' "$P1_OVS_DATAPATH" \
    >/etc/systemd/system/nvke-agent.service.d/zz-p1-ovs-datapath.conf
  log "P1: NKE_OVS_DATAPATH_TYPE=$P1_OVS_DATAPATH for nvke-agent"
fi

# 6b. The image adds ExecStartPre "test -e /sys/module/openvswitch || exec modprobe openvswitch" to
# ovs-vswitchd.service (no-rmmod-bridge.conf). A guest kernel with no Open vSwitch module fails it, and the
# userspace datapath does not need the module. An empty ExecStartPre= line in a later drop-in clears the list.
if [ "${P1_OVS_NO_MODPROBE:-0}" = 1 ]; then
  install -d -m 0755 /etc/systemd/system/ovs-vswitchd.service.d
  printf '[Service]\nExecStartPre=\n' >/etc/systemd/system/ovs-vswitchd.service.d/zz-p1-no-modprobe.conf
  log "P1: ovs-vswitchd.service starts with no modprobe step"
fi

# 6c. The userspace datapath makes each internal port as a TAP device, through /dev/net/tun.
if [ "${P1_TUN:-0}" = 1 ] && [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod -m 0666 /dev/net/tun c 10 200
  log "P1: made /dev/net/tun"
fi

# 6d. Guard for the runc baseline only. With runc the pod uses the kernel of the lab host. ovs-ctl calls
# "ovs-kmod-ctl insert", which runs modprobe and then "rmmod bridge" when /sys/module/openvswitch is absent.
# The lab must not load or remove a module on the host, so the script does nothing here.
if [ "${P1_KMOD_NOOP:-0}" = 1 ]; then
  printf '#!/bin/sh\n# Lab guard: no module load and no module removal from this pod.\nexit 0\n' \
    >/usr/share/openvswitch/scripts/ovs-kmod-ctl
  chmod 0755 /usr/share/openvswitch/scripts/ovs-kmod-ctl
  log "P1: ovs-kmod-ctl does nothing"
fi
log "P1: /dev/net/tun: $(ls -l /dev/net/tun 2>&1 | tr -s ' ')"

# A time mark on the root filesystem. After init, "find / -xdev -cnewer /.g1n-start" lists the
# files that the node wrote outside the volumes. A new container loses those files.
touch /.g1n-start

log "state is ready. Start the kind entrypoint."
exec /usr/local/bin/entrypoint /sbin/init
