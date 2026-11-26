#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Two extra tests on one Kata node pod (kata-clh-runtime-rs), after kubeadm init through the agent.
#
# Test 1, memory of the pod on the kind node. The pod cgroup has the memory limit of the pod plus
# the overhead of the RuntimeClass (130Mi). The guest memory is shared memory of the hypervisor, and
# the kernel charges each guest page to the pod cgroup when the guest first uses it. The NVKE image
# reads about 3 GB at the first start (the copy of /var and the OVN image import), so the guest
# uses much of its memory early. The test reads the /var device in the guest until the guest page
# cache is full, and it records the cgroup numbers and the OOM events before and after.
#
# Test 2, the kubelet reservations. The NVKE default for the kubelet patch is systemReserved 16Gi
# and kubeReserved 2Gi. The test sets 16Gi in the kubelet config of the running node and starts
# the kubelet again, to record the error. Then it puts the lab value back.
#
# Result of test 1 on 2026-11-25: the kernel killed cloud-hypervisor at the memory limit of the pod
# cgroup, and the sandbox was made again. The lab did not change a Kata setting after that result.
# Test 1 is a forced fill. It does not show how long a node takes to reach the same state by itself.
#
# Test 3, a write burst after the fill. The node writes a file of 3 GiB to /var (ext4 on the block
# volume) through the guest page cache. With the stock Kata setting block_device_cache_direct = false
# the hypervisor writes to the volume through the page cache of the host, and those dirty pages
# are charged to the pod cgroup too. overhead-test.sh has the same test for a plain pod.
#
# Variable TESTS: a list with "fill", "write" and "reservation" (default: fill and reservation).
# Test 2 needs a node that runs, so it has no use after a kill.
set -euo pipefail
TESTS=${TESTS:-fill reservation}

HERE="$(cd "$(dirname "$0")" && pwd)"
# RUNTIME_CLASS can name a class with a larger memory overhead (runtimeclasses-overhead.yaml).
export MODE=mtls RUNTIME_CLASS=${RUNTIME_CLASS:-kata-clh-runtime-rs} LIB_MODULES=0 VAR_LOOP=/dev/loop21 ETCD_LOOP=/dev/loop25
export NS=${NS:-gate1-nvke} NAME=${NAME:-nvke-cp}
export LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate1-nvke/a3-kata-rs-extra-tests}
KIND_NODE=kata-cp-control-plane
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
mkdir -p "$LOG_DIR"

node() { docker exec "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
pod() { k -n "$NS" exec "$NAME" -- "$@"; }
say() { echo "== $*"; }
# The memory numbers of the pod cgroup on the kind node, and of the guest.
memory() {
  local uid cg
  uid=$(k -n "$NS" get pod "$NAME" -o jsonpath='{.metadata.uid}')
  cg=$(node find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name "*pod${uid//-/_}.slice")
  say "memory ($1): pod cgroup on the kind node, in MiB"
  node sh -c "awk '{printf \"memory.max %d\\n\", \$1/1048576}' $cg/memory.max; awk '{printf \"memory.current %d\\n\", \$1/1048576}' $cg/memory.current; awk '{printf \"memory.peak %d\\n\", \$1/1048576}' $cg/memory.peak
    awk '\$1 ~ /^(anon|file|shmem|kernel)\$/ {printf \"%s %d\\n\", \$1, \$2/1048576}' $cg/memory.stat; echo memory.events \$(tr '\\n' ' ' <$cg/memory.events)"
  say "memory ($1): guest"
  pod free -m
  say "container restarts: $(k -n "$NS" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].restartCount}'), sandbox processes: $(node sh -c "ps -eo args= | grep -c '[c]loud-hypervisor.*'")"
}

{
  "$HERE/run.sh" wipe | tail -1
  "$HERE/run.sh" identities | grep -E '^== node'
  "$HERE/run.sh" up | tail -1
  "$HERE/run.sh" init | grep -E '^== pod create'
  "$HERE/run.sh" check 1-after-init | grep -E 'RESULT'

  case " $TESTS " in *" fill "*)
    say "test 1: fill the page cache of the guest (read 10 GiB from the /var device, which is mostly empty)"
    memory before-fill
    pod sh -c 'dd if=/dev/g1-var of=/dev/null bs=1M count=10240 2>&1 | tail -1' || say "the command in the pod ended with an error (exit $?)"
    memory after-fill || true
    say "the same from the virtio-fs root filesystem (a sparse file of 10 GiB), then the block device again"
    pod sh -c 'truncate -s 10240M /fill.bin; dd if=/fill.bin of=/dev/null bs=1M 2>&1 | tail -1; rm -f /fill.bin; dd if=/dev/g1-var of=/dev/null bs=1M count=10240 skip=10240 2>&1 | tail -1' || say "the command in the pod ended with an error (exit $?)"
    memory after-second-fill || true
    say "kernel log of the host for a kill at the memory limit of a cgroup (read in the kind node)"
    node sh -c 'dmesg -T 2>/dev/null | grep -E "invoked oom-killer|memory: usage|Memory cgroup out of memory" | tail -3 | cut -c1-400' || true
    k -n "$NS" get events --sort-by=.lastTimestamp | grep -E 'SandboxChanged|Killing' | cut -c1-200 || true
    "$HERE/run.sh" check 2-after-fill | grep -E 'RESULT|healthy|ok \(' || say "the pass rules fail after the fill"
    ;;
  esac
  case " $TESTS " in *" write "*)
    say "test 3: write a file of 3 GiB to /var of the node, with the guest memory already in use"
    pod sh -c 'dd if=/dev/zero of=/var/lib/g1n-fill.bin bs=1M count=3072 2>&1 | tail -1; sync; rm -f /var/lib/g1n-fill.bin' || say "the command in the pod ended with an error (exit $?)"
    memory after-write || true
    node sh -c 'dmesg -T 2>/dev/null | grep -E "invoked oom-killer|memory: usage|Memory cgroup out of memory" | tail -3 | cut -c1-400' || true
    k -n "$NS" get events --sort-by=.lastTimestamp | grep -E 'SandboxChanged|Killing' | cut -c1-200 || true
    ;;
  esac
  case " $TESTS " in *" reservation "*) ;; *)
    "$HERE/run.sh" logs | tail -1
    "$HERE/run.sh" down | tail -1
    exit 0
    ;;
  esac

  say "test 2: the NVKE default reservation (systemReserved 16Gi) in the kubelet config of a guest with 8 GiB"
  pod sh -c 'grep MemTotal /proc/meminfo; cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.lab
    sed -i "/^systemReserved:/{n;s/memory: .*/memory: 16Gi/}" /var/lib/kubelet/config.yaml; grep -A1 "^systemReserved:" /var/lib/kubelet/config.yaml
    systemctl restart kubelet; sleep 12
    echo "kubelet: $(systemctl is-active kubelet), restarts $(systemctl show -p NRestarts --value kubelet)"
    journalctl --no-pager -u kubelet --since "-12s" | grep -E "E[0-9]{4} |rror|ailed" | grep -i -E "reserv|allocatable|capacity|run.go|command failed" | cut -c1-420 | tail -3
    mv /var/lib/kubelet/config.yaml.lab /var/lib/kubelet/config.yaml; systemctl restart kubelet; sleep 8
    echo "kubelet with the lab value again: $(systemctl is-active kubelet)"' || true
  "$HERE/run.sh" check 3-after-kubelet-test | grep -E 'RESULT'

  "$HERE/run.sh" logs | tail -1
  "$HERE/run.sh" down | tail -1
} 2>&1 | tee "$LOG_DIR/extra-tests.txt"
