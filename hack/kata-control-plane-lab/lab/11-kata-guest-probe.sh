#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Probe a privileged Kata pod: guest kernel options, cgroups, a raw block volume, overlayfs, netfilter.
# Use: 11-kata-guest-probe.sh <runtime class> [loop device, default /dev/loop29 = spare-0]
# The pod uses the kind node image only for its tools. It does not start systemd.
set -uo pipefail

RC=${1:?runtime class}
DEV=${2:-/dev/loop29}
NODE=kata-cp-control-plane
K="docker exec -i $NODE kubectl --kubeconfig /etc/kubernetes/admin.conf"
POD=guest-probe

$K delete pod $POD --ignore-not-found --wait=true >/dev/null 2>&1
$K delete pvc probe-blk --ignore-not-found --wait=true >/dev/null 2>&1
$K delete pv probe-blk --ignore-not-found --wait=true >/dev/null 2>&1
docker exec $NODE wipefs -a -q "$DEV"

$K apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: probe-blk
spec:
  capacity: {storage: 20Gi}
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: probe-block
  local: {path: $DEV}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - {key: kubernetes.io/hostname, operator: In, values: [$NODE]}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: probe-blk
spec:
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  storageClassName: probe-block
  volumeName: probe-blk
  resources: {requests: {storage: 20Gi}}
---
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  runtimeClassName: $RC
  restartPolicy: Never
  containers:
    - name: c
      image: docker.io/kindest/node:v1.36.4
      imagePullPolicy: Never
      command: ["sleep", "infinity"]
      securityContext: {privileged: true}
      resources: {limits: {cpu: "2", memory: 2Gi}}
      volumeDevices:
        - {name: blk, devicePath: /dev/probe-blk}
      volumeMounts:
        - {name: run, mountPath: /run}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - name: blk
      persistentVolumeClaim: {claimName: probe-blk}
    - name: run
      emptyDir: {medium: Memory}
    - name: tmp
      emptyDir: {medium: Memory}
EOF

if ! $K wait --for=condition=Ready pod/$POD --timeout=180s; then
  $K describe pod $POD | tail -12 | cut -c1-700
  exit 1
fi

$K exec $POD -- bash -c '
sec() { echo; echo "== $*"; }
sec kernel; uname -r; nproc; free -m | sed -n 2p
sec "kernel config"; ls -l /proc/config.gz 2>&1
if [ -e /proc/config.gz ]; then
  for o in OVERLAY_FS FUSE_FS EXT4_FS XFS_FS EROFS_FS BLK_DEV_LOOP BLK_DEV_DM DM_THIN_PROVISIONING NF_TABLES IP_NF_IPTABLES IP6_NF_IPTABLES NETFILTER_XTABLES NF_NAT NF_CONNTRACK NETFILTER_XT_MATCH_COMMENT NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_TARGET_MASQUERADE BRIDGE BRIDGE_NETFILTER VETH VXLAN IP_VS DUMMY TUN CGROUP_BPF BPF_SYSCALL CGROUP_PIDS CGROUP_HUGETLB CPUSETS MEMCG BLK_CGROUP CGROUP_DEVICE CGROUP_FREEZER CGROUP_SCHED SECCOMP SECURITY_APPARMOR SECURITY_SELINUX USER_NS PID_NS NET_NS IPC_NS UTS_NS CGROUP_NS MODULES IKCONFIG_PROC INOTIFY_USER FANOTIFY NAMESPACES AUFS_FS INET_DIAG; do
    v=$(zcat /proc/config.gz | grep -E "^CONFIG_$o=" | cut -d= -f2); printf "%s=%s " "$o" "${v:-absent}"
  done; echo
fi
sec filesystems; grep -E "overlay|fuse|ext4|xfs|erofs|virtiofs" /proc/filesystems | tr "\n" " "; echo
sec "root filesystem"; findmnt -no FSTYPE,SOURCE,OPTIONS / | cut -c1-160
sec cgroups; cat /proc/self/cgroup; echo "controllers: $(cat /sys/fs/cgroup/cgroup.controllers)"; echo "subtree_control: $(cat /sys/fs/cgroup/cgroup.subtree_control)"; findmnt -no FSTYPE,OPTIONS /sys/fs/cgroup; echo "procs in root cgroup: $(wc -l < /sys/fs/cgroup/cgroup.procs)"
mkdir /sys/fs/cgroup/probe-child 2>&1 && echo "mkdir child cgroup: ok" && rmdir /sys/fs/cgroup/probe-child
sec inotify; sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
sec "block volume"; ls -l /dev/probe-blk; lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS 2>&1 | head -8
mkfs.ext4 -q -F /dev/probe-blk && mkdir -p /mnt/b && mount /dev/probe-blk /mnt/b && df -h /mnt/b | tail -1
sec "overlayfs on the block volume"; cd /mnt/b && mkdir -p l u w m && mount -t overlay overlay -o lowerdir=l,upperdir=u,workdir=w m && echo "overlay on block: ok" && umount m
sec "overlayfs on the root filesystem"; mkdir -p /ovl/l /ovl/u /ovl/w /ovl/m && mount -t overlay overlay -o lowerdir=/ovl/l,upperdir=/ovl/u,workdir=/ovl/w /ovl/m && echo "overlay on root: ok" && umount /ovl/m
sec netfilter; iptables-nft -t nat -L -n 2>&1 | head -2; iptables-legacy -t nat -L -n 2>&1 | head -2; nft list tables 2>&1 | head -3
sec "dummy interface"; ip link add lbip0 type dummy 2>&1 && ip addr add 172.30.255.240/32 dev lbip0 && ip link set lbip0 up && ip -br addr show lbip0
sec "mount steps of the kind entrypoint"; mount --make-rshared / && echo "make-rshared: ok"; mount -o remount,ro /sys && echo "remount /sys ro: ok"; mount -o remount,rw /sys 2>&1 | head -1
sec "memory filesystems"; df -h /dev/shm /run /tmp | sed 1d
sec "ids"; cat /proc/sys/kernel/random/boot_id; ls /sys/class/dmi/id/product_uuid 2>&1; cat /etc/machine-id 2>&1 | head -1
sec "devices"; ls /dev | tr "\n" " "; echo
sec "modules"; ls /lib/modules 2>&1 | head -3; lsmod 2>&1 | head -3
' 2>&1
