#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Lab storage for the pod VM provider, in the place of a storage driver.
# Twelve loop devices of the lab machine are six Machine places: each place is one device of
# 20 GiB (/var) and one of 8 GiB (etcd). Each host node (worker) gets two places, so one cluster
# of three Machines has one place on each host node, and each host node keeps one spare place
# for a new Machine. A volume has no claim reference. The class binds at the first use of a pod.
#
# Usage: storage.sh <step>
#   up       the storage class, wipe the twelve devices, make the twelve volumes
#   status   the volumes with phase, claim and device
#   reset    for each volume that is Released or Failed: delete it, wipe its device, make it again
#   down     delete the volumes and the class (only when no volume is Bound)
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
SC=${SC:-podvm-local-block}
KIND_NODE=${KIND_NODE:-kata-bb-control-plane}
LOOP_MAP=$W/disks/loop-map.txt
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# device -> "image file, use, size, host node"
declare -A PLACE=(
  [/dev/loop60]="var-0.img var 20Gi kata-bb-worker"   [/dev/loop63]="etcd-0.img etcd 8Gi kata-bb-worker"
  [/dev/loop66]="var-3.img var 20Gi kata-bb-worker"   [/dev/loop69]="etcd-3.img etcd 8Gi kata-bb-worker"
  [/dev/loop61]="var-1.img var 20Gi kata-bb-worker2"  [/dev/loop64]="etcd-1.img etcd 8Gi kata-bb-worker2"
  [/dev/loop67]="var-4.img var 20Gi kata-bb-worker2"  [/dev/loop70]="etcd-4.img etcd 8Gi kata-bb-worker2"
  [/dev/loop62]="var-2.img var 20Gi kata-bb-worker3"  [/dev/loop65]="etcd-2.img etcd 8Gi kata-bb-worker3"
  [/dev/loop68]="var-5.img var 20Gi kata-bb-worker3"  [/dev/loop71]="etcd-5.img etcd 8Gi kata-bb-worker3"
)
pv_name() { echo "podvm-${1#/dev/}"; }

check_devices() {
  local d img la
  la=$(node losetup -a)
  for d in "${!PLACE[@]}"; do
    read -r img _ <<<"${PLACE[$d]}"
    grep -q "^$d .*/$img " "$LOOP_MAP" || die "$d is not $img in $LOOP_MAP"
    grep -q "^$d: .*/$img)" <<<"$la" || die "$d is not $img in the kind node"
  done
}

# No volume of another test uses one of the devices.
check_free() {
  local users
  users=$(k get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.local.path}{"\n"}{end}' | awk '$2 != ""' | grep -v '^podvm-loop' | grep -E " /dev/loop(6[0-9]|7[01])\$" || true)
  [ -z "$users" ] || die "a volume of another test uses a device: $users"
}

make_pv() {
  local d=$1 img use size host
  read -r img use size host <<<"${PLACE[$d]}"
  PV=$(pv_name "$d") DEV=$d USE=$use SIZE=$size HOST_NODE=$host SC=$SC envsubst '$PV $DEV $USE $SIZE $HOST_NODE $SC' <"$HERE/pv.yaml.tmpl" | nodei "${KC[@]}" apply -f - >/dev/null
}

# Wait until the kubelet of the host node has let go of the device of a volume, then wipe it.
wipe() {
  local d=$1 pv i
  pv=$(pv_name "$d")
  for i in $(seq 1 60); do
    node losetup -a | grep -q -E "volumeDevices/$pv[/)]" || break
    sleep 1
  done
  node wipefs -a "$d" >/dev/null
  [ -z "$(node blkid -p -o value -s TYPE "$d" 2>/dev/null || true)" ] || die "$d still has a filesystem signature"
}

cmd_up() {
  local d
  check_devices
  check_free
  SC=$SC envsubst '$SC' <"$HERE/storageclass.yaml" | nodei "${KC[@]}" apply -f -
  for d in "${!PLACE[@]}"; do
    if k get pv "$(pv_name "$d")" >/dev/null 2>&1; then echo "$(pv_name "$d") exists"; continue; fi
    wipe "$d"
    make_pv "$d"
  done
  cmd_status
}

cmd_status() {
  k get pv -l podvm.lab/use -o custom-columns=NAME:.metadata.name,USE:.metadata.labels.podvm\\.lab/use,SIZE:.spec.capacity.storage,HOST:.metadata.labels.podvm\\.lab/host-node,DEVICE:.spec.local.path,PHASE:.status.phase,CLAIM:.spec.claimRef.name --sort-by=.metadata.labels.podvm\\.lab/host-node
  echo "phases: $(k get pv -l podvm.lab/use -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
}

cmd_reset() {
  local d pv phase n=0
  check_devices
  for d in "${!PLACE[@]}"; do
    pv=$(pv_name "$d")
    phase=$(k get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || echo Absent)
    case "$phase" in
      Released | Failed | Absent)
        [ "$phase" = Absent ] || k delete pv "$pv" --wait=true >/dev/null
        wipe "$d"
        make_pv "$d"
        echo "$pv ($d): was $phase, device wiped, volume made again"
        n=$((n + 1))
        ;;
    esac
  done
  echo "volumes made again: $n"
  cmd_status
}

cmd_down() {
  if k get pv -l podvm.lab/use -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -q Bound; then die "a volume is Bound"; fi
  k delete pv -l podvm.lab/use --wait=true
  k delete storageclass "$SC" --ignore-not-found
}

step=${1:-}
case "$step" in
  up | status | reset | down) "cmd_$step" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
