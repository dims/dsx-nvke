#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2, part 1: the fio sync write test of the etcd documents, in several places.
#
#   fio --rw=write --ioengine=sync --fdatasync=1 --directory=<folder> --size=22m --bs=2300 --name=mytest
#
# Each kubectl call runs inside the kind node (docker exec), so the host opens no TCP connection.
# Each run starts from the same state: the loop device is discarded (the backing file is sparse
# again), and the place makes a new ext4 with no lazy init, so no background write runs with fio.
#
# Usage: fio-run.sh <place> <run number>
#   host-loop        the host, ext4 on the loop device
#   host-scratch     the host, a folder on /scratch (no loop device)
#   runc-block       a runc pod, raw block volume, the pod makes ext4
#   runc-emptydir    a runc pod, a disk emptyDir (the /var of the kind node, which is on /scratch)
#   kata-block       a Kata pod with the class of record, raw block volume
#   kata-virtiofs    a Kata pod with the class of record, a disk emptyDir (virtio-fs)
#   kata-nodirect-block   class kata-clh-runtime-rs-ovh512 (stock agent, no direct I/O), raw block volume
#   kata-go-block    class kata-clh (Go runtime, stock), raw block volume
# Other steps: setup (namespace and volume), down (delete them), summary (table of all runs).
set -euo pipefail

KIND_NODE=${KIND_NODE:-kata-cp-control-plane}
NS=${NS:-gate2-fio}
LOOP=${LOOP:-/dev/loop28} # fio-1 in /scratch/kata-cp/disks/loop-map.txt
IMG=${IMG:-fio-1}         # the image file of the loop device, for the check against the loop map
LOOP_MAP=${LOOP_MAP:-/scratch/kata-cp/disks/loop-map.txt}
IMAGE=${IMAGE:-gate2-tools:1}
KATA_CLASS=${KATA_CLASS:-kata-clh-runtime-rs-fix-direct}
MNT=${MNT:-/scratch/kata-cp/mnt}
LOG_DIR=${LOG_DIR:-/scratch/kata-cp/logs/gate2/fio}
FIO_ARGS="--rw=write --ioengine=sync --fdatasync=1 --size=22m --bs=2300 --name=mytest --output-format=json"
MKFS_ARGS="-q -F -E lazy_itable_init=0,lazy_journal_init=0"
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
mkdir -p "$LOG_DIR"

node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
say() { echo "== $*"; }

check_device() {
  case "$IMG" in fio-1 | spare-1 | var-1 | etcd-1 | var-2 | etcd-2) ;; *) echo "$IMG is not a device of gate 2"; exit 1 ;; esac
  grep -q "^$LOOP /scratch/kata-cp/disks/$IMG.img " "$LOOP_MAP" || { echo "$LOOP is not $IMG in $LOOP_MAP"; exit 1; }
}
# The write count and the flush count of the loop device and of the NVMe disk of /scratch, from /proc/diskstats.
loop_stats() { awk -v d="${LOOP#/dev/}" '$3 == d || $3 == "nvme1n1" {printf "%s writes %s flushes %s flush-ms %s. ", $3, $8, $19, $20}' /proc/diskstats; }
# Make the backing file sparse again, and remove each filesystem signature.
reset_device() {
  check_device
  # The kubelet holds a raw block volume with one more loop device. Wait until it is gone.
  node bash -c "for i in \$(seq 1 60); do losetup -a | grep -q 'volumeDevices/$NS-dev/' || exit 0; sleep 1; done; echo 'the kubelet still holds the volume'; exit 1"
  node blkdiscard -f "$LOOP"
  node wipefs -a -q "$LOOP"
  echo "backing file after discard: $(du -k "/scratch/kata-cp/disks/$IMG.img" | cut -f1) kB in use"
}

cmd_setup() {
  check_device
  nodei "${KC[@]}" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
---
apiVersion: v1
kind: PersistentVolume
metadata: {name: $NS-dev}
spec:
  capacity: {storage: 10Gi}
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: $NS-local-block
  claimRef: {namespace: $NS, name: fio-dev}
  local: {path: $LOOP}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - {key: kubernetes.io/hostname, operator: In, values: ["$KIND_NODE"]}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: fio-dev, namespace: $NS}
spec:
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  storageClassName: $NS-local-block
  volumeName: $NS-dev
  resources: {requests: {storage: 10Gi}}
EOF
}

cmd_down() {
  k delete namespace "$NS" --ignore-not-found --wait=true
  k delete pv "$NS-dev" --ignore-not-found --wait=true
  node bash -c "for i in \$(seq 1 60); do losetup -a | grep -q 'volumeDevices/$NS-dev/' || exit 0; sleep 1; done; exit 1"
  reset_device
}

# The script that runs in the pod. mode = block or dir.
pod_script() {
  cat <<EOF
set -e
echo "kernel \$(uname -r)"
fio --version
mkdir -p /mnt/fio
if [ "$1" = block ]; then
  mm=\$(printf '%d:%d' 0x\$(stat -c %t /dev/fio-dev) 0x\$(stat -c %T /dev/fio-dev))
  dev=\$(basename "\$(readlink -f /sys/dev/block/\$mm)")
  echo "device \$dev (\$mm): logical \$(cat /sys/block/\$dev/queue/logical_block_size) physical \$(cat /sys/block/\$dev/queue/physical_block_size) write_cache [\$(cat /sys/block/\$dev/queue/write_cache)] discard_max \$(cat /sys/block/\$dev/queue/discard_max_bytes) scheduler [\$(cat /sys/block/\$dev/queue/scheduler)]" || true
  mkfs.ext4 $MKFS_ARGS /dev/fio-dev
  mount /dev/fio-dev /mnt/fio
fi
echo "mount: \$(findmnt -n -o SOURCE,FSTYPE,OPTIONS -T /mnt/fio)"
mkdir -p /mnt/fio/run
sync
sleep 2
echo "FIO-JSON-START"
fio $FIO_ARGS --directory=/mnt/fio/run
echo "FIO-JSON-END"
rm -rf /mnt/fio/run
if [ "$1" = block ]; then umount /mnt/fio; fi
EOF
}

# run_pod <name> <runtime class or empty> <block|dir> <log file>
run_pod() {
  local name=$1 class=$2 mode=$3 log=$4 volume mount
  if [ "$mode" = block ]; then
    volume='persistentVolumeClaim: {claimName: fio-dev}'
    mount='volumeDevices: [{name: data, devicePath: /dev/fio-dev}]'
  else
    volume='emptyDir: {}'
    mount='volumeMounts: [{name: data, mountPath: /mnt/fio}]'
  fi
  {
    cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $name, namespace: $NS}
spec:
  ${class:+runtimeClassName: $class}
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  terminationGracePeriodSeconds: 5
  containers:
    - name: fio
      image: $IMAGE
      imagePullPolicy: Never
      securityContext: {privileged: true}
      resources:
        limits: {cpu: "2", memory: 2Gi}
      $mount
      command:
        - bash
        - -c
        - |
EOF
    pod_script "$mode" | sed 's/^/          /'
    cat <<EOF
  volumes:
    - name: data
      $volume
EOF
  } >"$LOG_DIR/.pod.yaml"
  nodei "${KC[@]}" apply -f - <"$LOG_DIR/.pod.yaml" >/dev/null
  node bash -c "for i in \$(seq 1 300); do p=\$(${KC[*]} -n $NS get pod $name -o jsonpath='{.status.phase}'); case \$p in Succeeded|Failed) echo \"pod phase \$p\"; exit 0;; esac; sleep 1; done; echo 'pod timeout'; exit 1" >>"$log"
  k -n "$NS" get pod "$name" -o jsonpath='runtime class [{.spec.runtimeClassName}] node {.spec.nodeName}{"\n"}' >>"$log"
  k -n "$NS" logs "$name" >>"$log" 2>&1
  k -n "$NS" delete pod "$name" --wait=true >/dev/null
}

cmd_run() {
  local place=$1 run=$2 log
  log="$LOG_DIR/$place-run$run.log"
  : >"$log"
  {
    echo "place $place run $run at $(date -u +%FT%TZ)"
    echo "uptime before: $(uptime)"
  } >>"$log"
  case "$place" in
    host-loop)
      reset_device >>"$log"
      echo "before: $(loop_stats)" >>"$log"
      {
        echo "kernel $(uname -r)"
        fio --version
        d=${LOOP#/dev/}
        echo "device $d: logical $(cat /sys/block/$d/queue/logical_block_size) physical $(cat /sys/block/$d/queue/physical_block_size) write_cache [$(cat /sys/block/$d/queue/write_cache)] discard_max $(cat /sys/block/$d/queue/discard_max_bytes) scheduler [$(cat /sys/block/$d/queue/scheduler)]"
      } >>"$log"
      mkdir -p "$MNT/$IMG"
      # shellcheck disable=SC2086
      sudo mkfs.ext4 $MKFS_ARGS,root_owner="$(id -u):$(id -g)" "$LOOP"
      sudo mount "$LOOP" "$MNT/$IMG"
      echo "mount: $(findmnt -n -o SOURCE,FSTYPE,OPTIONS -T "$MNT/$IMG")" >>"$log"
      mkdir -p "$MNT/$IMG/run"
      sync
      sleep 2
      echo "FIO-JSON-START" >>"$log"
      # shellcheck disable=SC2086
      fio $FIO_ARGS --directory="$MNT/$IMG/run" >>"$log"
      echo "FIO-JSON-END" >>"$log"
      rm -rf "$MNT/$IMG/run"
      sudo umount "$MNT/$IMG"
      echo "after: $(loop_stats)" >>"$log"
      ;;
    host-scratch)
      mkdir -p "$MNT/host-scratch/run"
      echo "before: $(loop_stats)" >>"$log"
      {
        echo "kernel $(uname -r)"
        fio --version
        echo "mount: $(findmnt -n -o SOURCE,FSTYPE,OPTIONS -T "$MNT/host-scratch")"
        echo "FIO-JSON-START"
      } >>"$log"
      # shellcheck disable=SC2086
      fio $FIO_ARGS --directory="$MNT/host-scratch/run" >>"$log"
      echo "FIO-JSON-END" >>"$log"
      rm -rf "$MNT/host-scratch"
      echo "after: $(loop_stats)" >>"$log"
      ;;
    runc-block | kata-block | kata-nodirect-block | kata-go-block)
      local class=
      case "$place" in
        kata-block) class=$KATA_CLASS ;;
        kata-nodirect-block) class=kata-clh-runtime-rs-ovh512 ;;
        kata-go-block) class=kata-clh ;;
      esac
      reset_device >>"$log"
      echo "before: $(loop_stats)" >>"$log"
      run_pod "fio-$place-$run" "$class" block "$log"
      echo "after: $(loop_stats)" >>"$log"
      ;;
    runc-emptydir | kata-virtiofs)
      local dirclass=
      [ "$place" = runc-emptydir ] || dirclass=$KATA_CLASS
      echo "before: $(loop_stats)" >>"$log"
      run_pod "fio-$place-$run" "$dirclass" dir "$log"
      echo "after: $(loop_stats)" >>"$log"
      ;;
    *) echo "unknown place $place"; exit 1 ;;
  esac
  echo "uptime after: $(uptime)" >>"$log"
  one_line "$log"
}

# One line for a run: percentiles of fdatasync in ms, and the write rate.
one_line() {
  local log=$1
  sed -n '/^FIO-JSON-START$/,/^FIO-JSON-END$/p' "$log" | sed '1d;$d' |
    jq -r --arg f "$(basename "$log" .log)" '.jobs[0] | [$f,
      (.sync.lat_ns.N|tostring),
      (.sync.lat_ns.mean/1e6*1000|round/1000|tostring),
      (.sync.lat_ns.percentile["50.000000"]/1e6*1000|round/1000|tostring),
      (.sync.lat_ns.percentile["90.000000"]/1e6*1000|round/1000|tostring),
      (.sync.lat_ns.percentile["99.000000"]/1e6*1000|round/1000|tostring),
      (.sync.lat_ns.percentile["99.900000"]/1e6*1000|round/1000|tostring),
      (.sync.lat_ns.max/1e6*1000|round/1000|tostring),
      (.write.iops|round|tostring),
      (.write.bw|tostring),
      (.write.runtime/1000|tostring)] | @tsv'
}

cmd_summary() {
  printf 'run\tsyncs\tmean_ms\tp50_ms\tp90_ms\tp99_ms\tp99.9_ms\tmax_ms\twrite_iops\twrite_KiB_s\truntime_s\n'
  local f
  for f in "$LOG_DIR"/*-run*.log; do one_line "$f" || echo "$(basename "$f" .log) no result"; done
}

step=${1:-}
shift || true
case "$step" in
  setup | down | summary) "cmd_$step" "$@" ;;
  host-loop | host-scratch | runc-block | runc-emptydir | kata-block | kata-virtiofs | kata-nodirect-block | kata-go-block) cmd_run "$step" "${1:?run number}" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
