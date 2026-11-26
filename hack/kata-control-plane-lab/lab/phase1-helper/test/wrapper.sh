#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Container command of the test pod of the bootstrap helper. It is the wrapper of gate 4
# (~/notes/hosted/lab/gate4/wrapper.sh) with these parts left out, because the test checks
# only files, the commands and the status file:
#   - no block volume for /var and none for /var/lib/etcd (part 2),
#   - no node state for /etc/kubernetes, /kind and the machine ID (part 3),
#   - no node address (part 5).
# The pod mounts an emptyDir on /var/lib/nico-containers. It stands for the /var volume:
# its content stays through a container restart, and the rest of the root filesystem does not.
# The wrapper writes no SPIRE file and no cloud-init status. That is the work of the helper.
set -o errexit -o nounset -o pipefail

log() { echo "WRAP: $*" >&2; }
skip() {
  case " ${G1_SKIP:-} " in *" $1 "*) return 0 ;; esac
  return 1
}

# 1. Private cgroup namespace (gate 4 wrapper, part 1).
if [ -f /sys/fs/cgroup/cgroup.controllers ] && [ "$(cat /proc/self/cgroup)" != "0::/" ]; then
  if [ -n "${G1_CGROUPNS:-}" ]; then
    log "ERROR: the cgroup namespace is still not private: $(cat /proc/self/cgroup)"
    exit 1
  fi
  export G1_CGROUPNS=new
  exec unshare --cgroup -- "$0" "$@"
fi
if [ "${G1_CGROUPNS:-}" = new ]; then
  umount /sys/fs/cgroup
  mount -t cgroup2 -o rw,nosuid,nodev,noexec,relatime cgroup2 /sys/fs/cgroup
  log "cgroup namespace is private"
fi
unset G1_CGROUPNS
if [ "${G1_GUEST:-0}" = 1 ] && ! skip init-cgroup; then
  mkdir -p /sys/fs/cgroup/init
fi

# 2. An empty /run and /tmp at each start.
find /run /tmp -xdev -mindepth 1 -delete || log "WARN: could not empty /run and /tmp"
chmod 755 /run
chmod 1777 /tmp

# 4. What a kind node gets from the kernel of its host.
if [ "${G1_GUEST:-0}" = 1 ]; then
  sysctl -q -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576
fi
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ]; then
  sysctl -q -w net.ipv4.ip_forward=1
fi
if [ ! -e /dev/kmsg ]; then
  mknod -m 600 /dev/kmsg c 1 11
fi

# A time mark on the root filesystem. A new container has a new mark.
date +%s >/.helper-test-container-start

log "state is ready. Start the kind entrypoint."
exec /usr/local/bin/entrypoint /sbin/init
