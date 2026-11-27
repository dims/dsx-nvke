#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The start time of one node pod made by hand, for one node image: pod create to "the agent units
# start" at a first start (empty volumes), then one more start with the same volumes.
# The pod has the form of the provider's pod, with test bootstrap data (fake values, the lab form
# of NVKE: three files and the command "systemctl restart nke-agent.service"). With fake SPIRE
# data the agent gets no identity and opens no listener, so the pod has no startup probe and the
# end point of the measure is the end of the unit podvm-bootstrap-final (cloud-init status done).
# In the real runs the listener of the agent came 1.1 to 1.5 s after that point.
# Usage: nodestart.sh <image> <label>     for example nodestart.sh docker.io/library/nvke-node-podvm:bcc4376f-p3 p3
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE_REF=${1:?image}
label=${2:?label}
NS=p2m
M=p2m-cp-$label
ADDRESS=172.28.2.41/16        # on the node network, outside the range of the provider (172.28.1.0/24)
MAC=02:00:ac:1c:02:29
SC=podvm-local-block
OUT=$W/logs/p2s6/nodestart-$label.txt
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
node() { docker exec kata-bb-control-plane "$@"; }
nodei() { docker exec -i kata-bb-control-plane "$@"; }
k() { node "${KC[@]}" "$@"; }
wait_node() { local t=$1; shift; node systemd-run --quiet --wait --collect --expand-environment=no --unit="p2m-wait-$$-$RANDOM" bash -c "for i in \$(seq 1 $t); do if $*; then exit 0; fi; sleep 1; done; exit 1"; }

pod_yaml() {
  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $M
  namespace: $NS
  labels: {cluster.x-k8s.io/cluster-name: p2m, podvm.infrastructure.cluster.x-k8s.io/machine-name: $M}
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"nodenet","namespace":"$NS","ips":["$ADDRESS"],"mac":"$MAC"}]'
spec:
  runtimeClassName: kata-clh-runtime-rs-fix-direct-ovs
  automountServiceAccountToken: false
  enableServiceLinks: false
  terminationGracePeriodSeconds: 20
  containers:
    - name: node
      image: $IMAGE_REF
      imagePullPolicy: Never
      securityContext: {privileged: true}
      env:
        - {name: PODVM_MACHINE_NAME, value: "$M"}
        - {name: PODVM_NODE_ADDRESS, value: "$ADDRESS"}
        - {name: PODVM_NODE_INTERFACE, value: net1}
      resources:
        limits: {cpu: "2", memory: 6Gi}
        requests: {cpu: "2", memory: 6Gi}
      volumeDevices:
        - {name: var, devicePath: /dev/podvm-var}
        - {name: etcd, devicePath: /dev/podvm-etcd}
      volumeMounts:
        - {name: bootstrap, mountPath: /etc/podvm/bootstrap, readOnly: true}
  volumes:
    - {name: var, persistentVolumeClaim: {claimName: $M-var}}
    - {name: etcd, persistentVolumeClaim: {claimName: $M-etcd}}
    - {name: bootstrap, secret: {secretName: $M-bootstrap, items: [{key: value, path: value}]}}
YAML
}
claims_yaml() {
  local n s
  for n in "var 20Gi" "etcd 8Gi"; do
    set -- $n
    cat <<YAML
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $M-$1, namespace: $NS}
spec:
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  storageClassName: $SC
  resources: {requests: {storage: $2}}
YAML
  done
}

# One start: make the pod, wait for the end of the commands unit, print the times.
one_start() {
  local what=$1 t0 t1
  t0=$(date +%s.%N)
  pod_yaml | nodei "${KC[@]}" apply -f - >/dev/null
  k -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$M" --timeout=300s >/dev/null
  wait_node 300 "${KC[*]} -n $NS exec $M -- systemctl is-active --quiet podvm-bootstrap-final >/dev/null 2>&1" || echo "the commands unit did not end in 300 s"
  t1=$(date +%s.%N)
  echo "--- $label, $what: pod $M on $(k -n "$NS" get pod "$M" -o jsonpath='{.spec.nodeName}'), image $(k -n "$NS" get pod "$M" -o jsonpath='{.status.containerStatuses[0].image}')"
  echo "pod made at $(date -u -d "@$t0" +%T.%3N), seen done by the script after $(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.1f", b-a}') s (the look is one each second)"
  k -n "$NS" get pod "$M" -o json | jq -r '"pod created \(.metadata.creationTimestamp), scheduled \([.status.conditions[] | select(.type=="PodScheduled") | .lastTransitionTime] | join("")), container running \(.status.containerStatuses[0].state.running.startedAt)"'
  k -n "$NS" logs "$M" 2>/dev/null | grep -a 'PODVM:' | tr -d '\r' | grep -E 'start at|first use|state is ready' | cut -c1-150
  k -n "$NS" exec "$M" -- sh -c 'journalctl -b --no-pager -o short-precise -u podvm-bootstrap -u podvm-bootstrap-final | grep RESULT | cut -c1-210
    echo "agent unit started: $(journalctl -b --no-pager -o short-precise -u nvke-agent | grep -m1 "Started nvke-agent" | cut -c8-22), SPIRE agent unit started: $(journalctl -b --no-pager -o short-precise -u spire-agent | grep -m1 "Started spire-agent" | cut -c8-22)"
    echo "boot: $(systemd-analyze 2>&1 | head -1)"
    echo "slowest units: $(systemd-analyze blame --no-pager 2>/dev/null | head -4 | tr -s " " | tr "\n" ";")"
    echo "unit nke-container-cni-images: active=$(systemctl is-active nke-container-cni-images) condition=$(systemctl show -p ConditionResult --value nke-container-cni-images), package file $(ls /usr/lib/nvke/e2e/ 2>/dev/null | tr "\n" " ")"
    echo "images in containerd: $(crictl images -q 2>/dev/null | wc -l), OVN images: $(crictl images 2>/dev/null | grep -c -i ovn), /var used: $(df -h --output=used /var | tail -1 | tr -d " ")"
    echo "cloud-init: $(cloud-init status | head -1), systemd: $(systemctl is-system-running), failed units: $(systemctl --failed --no-legend --plain | wc -l)"' 2>&1
  # pod create (API time, 1 s steps) to the end of the commands unit (journal time)
  local c d
  c=$(k -n "$NS" get pod "$M" -o jsonpath='{.metadata.creationTimestamp}')
  d=$(k -n "$NS" exec "$M" -- sh -c 'journalctl -b --no-pager -o short-iso-precise -u podvm-bootstrap-final | grep RESULT | tail -1 | cut -d" " -f1')
  echo "MEASURE $label $what: pod create to status done $(awk -v a="$t0" -v b="$(date -u -d "$d" +%s.%N)" 'BEGIN {printf "%.1f", b-a}') s (pod made $(date -u -d "@$t0" +%T.%3N), done $(date -u -d "$d" +%T.%3N))"
}

{
  echo "== node start with $IMAGE_REF ($label) at $(date -u +%FT%TZ)"
  "$W/p2-replace/disk.sh" "node start $label"
  for n in $WORKERS; do echo "$n: image $(docker exec "$n" crictl inspecti -o json "$IMAGE_REF" 2>/dev/null | jq -r '.status.id + " " + (.status.size|tostring)' | cut -c8-40)"; done
  k create namespace "$NS" --dry-run=client -o yaml | nodei "${KC[@]}" apply -f - >/dev/null
  NS=$NS envsubst '$NS' <"$W/d/endpoint-run/nad.yaml.tmpl" | nodei "${KC[@]}" apply -f - >/dev/null
  nodei "${KC[@]}" -n "$NS" create secret generic "$M-bootstrap" --from-file=value=/dev/stdin --dry-run=client -o yaml <"$W/p2-image/out/fixtures/lab.userdata.yaml" | nodei "${KC[@]}" apply -f - >/dev/null
  claims_yaml | nodei "${KC[@]}" apply -f - >/dev/null
  one_start "first start, empty volumes"
  k -n "$NS" get pvc -o custom-columns=CLAIM:.metadata.name,VOLUME:.spec.volumeName --no-headers | tr '\n' ';'; echo
  k -n "$NS" delete pod "$M" --wait=true >/dev/null
  one_start "later start, same volumes"
  k -n "$NS" delete pod "$M" --wait=true >/dev/null
  k -n "$NS" delete pvc "$M-var" "$M-etcd" --wait=true >/dev/null
  k -n "$NS" delete secret "$M-bootstrap" >/dev/null
  "$W/p2-provider/storage.sh" reset | grep -E 'made again|phases'
} 2>&1 | tee "$OUT"
