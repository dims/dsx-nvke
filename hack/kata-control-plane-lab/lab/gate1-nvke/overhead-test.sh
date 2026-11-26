#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Memory overhead test for a Kata pod: does the pod cgroup on the node kill the hypervisor when
# the guest uses all its memory?
#
# The script starts one plain pod (no systemd, no kubeadm) with the given RuntimeClass and memory
# limit. In the guest it reads, in rounds, more data than the guest has memory: from a raw block
# volume, from a sparse file on the virtio-fs root filesystem, and all files of the image. The
# guest page cache then holds all free guest memory. On the kind node a sampler reads the pod
# cgroup each second. The Kata Rust runtime keeps the hypervisor, virtiofsd and the shim in the
# pod cgroup, whose limit is the pod limit plus the memory overhead of the RuntimeClass.
#
# With WRITE_MB set, each round also writes that many MiB to the block volume through the guest
# page cache and syncs, so the hypervisor side also holds dirty pages of the host.
#
# Usage: overhead-test.sh <label> <runtime class> <memory limit> [seconds of load, default 150]
# Example: overhead-test.sh rs-8g-stock kata-clh-runtime-rs 8Gi
# Each kubectl call runs in the kind node. The script uses one loop device (var-2) and reads it only.
set -euo pipefail

LABEL=$1 RC=$2 LIMIT=$3 DURATION=${4:-150}
NS=${NS:-gate1-nvke-mem}
POD=fill
BLK_LOOP=${BLK_LOOP:-/dev/loop21}      # var-2 in /scratch/kata-cp/disks/loop-map.txt
IMAGE=${IMAGE:-nvke-node:bcc4376f-amd64}  # used only for its large root filesystem and its tools
CPU=${CPU:-2}
WRITE_MB=${WRITE_MB:-0}                # MiB to write to the block volume in each round. 0 = read only
WRITE_CMD=${WRITE_CMD:-}               # other write command for each round, for example small writes with oflag=dsync
KIND_NODE=kata-cp-control-plane
BIN_DIR=/var/lib/gate1-nvke/bin        # folder in the kind node
STOP=/tmp/gate1-nvke-mem.stop
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate1-nvke/overhead/$LABEL}
HERE="$(cd "$(dirname "$0")" && pwd)"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
mkdir -p "$LOG_DIR"

node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
say() { echo "== $*"; }
mib() { awk '{printf "%d", $1/1048576}'; }

{
  say "test $LABEL: runtime class $RC, memory limit $LIMIT, load for $DURATION s, write $WRITE_MB MiB each round${WRITE_CMD:+ and run \"$WRITE_CMD\"}, at $(date -u +%FT%TZ)"
  grep -q "^$BLK_LOOP .*var-2" /scratch/kata-cp/disks/loop-map.txt || { echo "$BLK_LOOP is not var-2"; exit 1; }
  free -g | sed -n 2p
  node mkdir -p "$BIN_DIR"
  docker cp -q "$HERE/mem-sampler.sh" "$KIND_NODE:$BIN_DIR/mem-sampler.sh"

  nodei "${KC[@]}" apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
---
apiVersion: v1
kind: PersistentVolume
metadata: {name: $NS-blk}
spec:
  capacity: {storage: 30Gi}
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: $NS-local-block
  claimRef: {namespace: $NS, name: blk}
  local: {path: $BLK_LOOP}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - {key: kubernetes.io/hostname, operator: In, values: ["$KIND_NODE"]}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: blk, namespace: $NS}
spec:
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  storageClassName: $NS-local-block
  volumeName: $NS-blk
  resources: {requests: {storage: 30Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS}
spec:
  runtimeClassName: $RC
  # Never: a pod whose hypervisor dies stays failed, so the result is clear.
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  terminationGracePeriodSeconds: 2
  containers:
    - name: fill
      image: $IMAGE
      imagePullPolicy: Never
      command: ["sleep", "infinity"]
      resources:
        limits: {cpu: "$CPU", memory: $LIMIT}
      volumeDevices:
        - {name: blk, devicePath: /dev/blk}
  volumes:
    - name: blk
      persistentVolumeClaim: {claimName: blk}
YAML
  node bash -c "for i in \$(seq 1 120); do [ \"\$(${KC[*]} -n $NS get pod $POD -o jsonpath='{.status.phase}')\" = Running ] && exit 0; sleep 1; done; exit 1"

  uid=$(k -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}')
  cg=$(node find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name "*pod${uid//-/_}.slice")
  sandbox=$(node crictl pods -q --namespace "$NS" --name "$POD" --state ready)
  max=$(node cat "$cg/memory.max" | mib)
  guest=$(k -n "$NS" exec "$POD" -- awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  overhead=$(k get runtimeclass "$RC" -o jsonpath='{.overhead.podFixed.memory}')
  say "pod cgroup $cg"
  say "memory.max $max MiB (limit $LIMIT plus overhead $overhead). Guest MemTotal $guest MiB, $(k -n "$NS" exec "$POD" -- nproc) CPUs, kernel $(k -n "$NS" exec "$POD" -- uname -r)"
  say "processes of the sandbox on the kind node, and the cgroup of each one"
  node sh -c "for p in \$(ps -eo pid=,comm=,args= | awk '\$2 ~ /^(cloud-hyperviso|virtiofsd|containerd-shim)/ && /$sandbox/ {print \$1}'); do echo \"\$(cat /proc/\$p/comm) pid \$p: \$(cut -d: -f3 /proc/\$p/cgroup)\"; done" | tee "$LOG_DIR/sandbox-cgroups.txt"
  ooms_before=$(node sh -c 'dmesg 2>/dev/null | grep -c "invoked oom-killer"' || true)

  node rm -f "$STOP"
  node sh "$BIN_DIR/mem-sampler.sh" "$cg" "$STOP" >"$LOG_DIR/samples.txt" 2>&1 &
  samplers=($!)
  # The Go runtime keeps sandbox processes outside the pod cgroup. Sample each such cgroup too.
  extra=0
  for other in $(awk '{print $NF}' "$LOG_DIR/sandbox-cgroups.txt" | sort -u); do
    case "$other" in "${cg#/sys/fs/cgroup}"*) continue ;; esac
    extra=$((extra + 1))
    say "outside the pod cgroup: $other, memory.max $(node cat "/sys/fs/cgroup$other/memory.max" 2>&1), memory.max of its parent $(node cat "/sys/fs/cgroup$(dirname "$other")/memory.max" 2>&1)"
    echo "$other" >"$LOG_DIR/samples-outside-$extra.cgroup"
    node sh "$BIN_DIR/mem-sampler.sh" "/sys/fs/cgroup$other" "$STOP" >"$LOG_DIR/samples-outside-$extra.txt" 2>&1 &
    samplers+=($!)
  done

  say "load in the guest"
  rc=0
  k -n "$NS" exec "$POD" -- sh -c '
    end=$(( $(date +%s) + '"$DURATION"' ))
    gm=$(awk "/MemTotal/{print int(\$2/1024)}" /proc/meminfo)
    n=$(( gm + 2048 ))
    truncate -s ${n}M /fill.bin
    echo "read size $n MiB for each source. Files on the root filesystem: $(find / -xdev -type f | wc -l)"
    r=0
    while [ $(date +%s) -lt $end ]; do
      r=$((r + 1))
      dd if=/dev/blk of=/dev/null bs=1M count=$n skip=$(( (r % 2) * n )) 2>/dev/null
      dd if=/fill.bin of=/dev/null bs=1M 2>/dev/null
      find / -xdev -type f -size +8k ! -name fill.bin -print0 2>/dev/null | xargs -0 cat >/dev/null 2>&1
      if [ '"$WRITE_MB"' -gt 0 ]; then dd if=/dev/zero of=/dev/blk bs=1M count='"$WRITE_MB"' 2>/dev/null; sync; fi
      '"$WRITE_CMD"'
      echo "round $r done at $(date -u +%T): $(free -m | awk "/Mem:/{print \"guest used=\"\$3\" free=\"\$4\" cache=\"\$6}")"
    done
    rm -f /fill.bin' 2>&1 | tee "$LOG_DIR/fill.txt" || rc=$?
  say "the load ended with exit code $rc"
  sleep 3
  node touch "$STOP"
  for pid in "${samplers[@]}"; do wait "$pid" || true; done

  say "after the load"
  k -n "$NS" get pod "$POD" -o wide || true
  node sh -c "[ -d $cg ] && { echo memory.peak \$(awk '{printf \"%d\", \$1/1048576}' $cg/memory.peak) MiB; echo memory.events \$(tr '\n' ' ' <$cg/memory.events); } || echo 'the pod cgroup is gone'" || true
  ooms_after=$(node sh -c 'dmesg 2>/dev/null | grep -c "invoked oom-killer"' || true)
  if [ "$ooms_after" != "$ooms_before" ]; then
    say "kernel report of a kill at a cgroup memory limit (host kernel log, read in the kind node)"
    node sh -c 'dmesg 2>/dev/null | awk "/invoked oom-killer/{buf=\"\"} {buf=buf \$0 \"\n\"} END{printf \"%s\", buf}"' >"$LOG_DIR/oom-report.txt" || true
    if grep -q "pod${uid//-/_}" "$LOG_DIR/oom-report.txt"; then
      grep -E 'invoked oom-killer|memory: usage|Killed process|\] (anon|file|kernel|pagetables|sec_pagetables|shmem|slab|active_file|inactive_file) [0-9]+$|cloud-hyperviso|virtiofsd|containerd-shim' "$LOG_DIR/oom-report.txt" | cut -c1-260
    else
      echo "the last kernel report is for a different cgroup, not for this pod"
    fi
  fi

  # Summary from the samples. "Outside the guest" is the use of the pod cgroup minus the shared memory of the guest.
  awk -v label="$LABEL" -v rc="$RC" -v limit="$LIMIT" -v ovh="$overhead" -v max="$max" -v guest="$guest" -v code="$rc" '
    function val(k,  i, a) { for (i = 2; i <= NF; i++) { split($i, a, "="); if (a[1] == k) return a[2] + 0 } return 0 }
    /current=/ {
      c = val("current"); s = val("shmem"); hard = val("anon") + val("kernel"); n++
      if (c > peak) { peak = c; peak_shmem = s; peak_hard = hard; peak_cache = val("file") - s }
      if (s > max_shmem) max_shmem = s
      if (hard > max_hard) max_hard = hard
      if (c - s > max_out) max_out = c - s
      kills = val("ev_oom_kill"); hits = val("ev_max"); last = $0
    }
    END {
      result = (kills > 0 || code != 0) ? "KILLED" : "survived"
      printf "SUMMARY %s | class %s | limit %s | overhead %s | cgroup limit %d MiB | guest MemTotal %d MiB | %s | peak %d MiB (guest shmem %d, anon+kernel %d, host file cache %d) | largest guest shmem %d | largest anon+kernel %d | largest use outside the guest %d | limit hits %d | oom_kill %d | samples %d\n",
        label, rc, limit, ovh, max, guest, result, peak, peak_shmem, peak_hard, peak_cache, max_shmem, max_hard, max_out, hits, kills, n
      sub(/^.*\| /, "", last); printf "processes at the last sample (name:RSS MiB): %s\n", last
    }' "$LOG_DIR/samples.txt"

  for f in "$LOG_DIR"/samples-outside-*.txt; do
    [ -f "$f" ] || continue
    awk -v name="$(cat "${f%.txt}.cgroup")" '
      function val(k,  i, a) { for (i = 2; i <= NF; i++) { split($i, a, "="); if (a[1] == k) return a[2] + 0 } return 0 }
      /current=/ { c = val("current"); if (c > peak) { peak = c; s = val("shmem"); h = val("anon") + val("kernel"); fc = val("file") - val("shmem") } last = $0 }
      END { sub(/^.*\| /, "", last); printf "OUTSIDE %s | peak %d MiB (shmem %d, anon+kernel %d, host file cache %d) | processes at the last sample: %s\n", name, peak, s, h, fc, last }' "$f"
  done

  k -n "$NS" delete pod "$POD" --wait=true >/dev/null 2>&1 || true
} 2>&1 | tee "$LOG_DIR/test.txt"
