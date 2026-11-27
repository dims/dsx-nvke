#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# One throwaway pod of the class kata-clh-runtime-rs-fix-direct-ovs that is not part of a cluster,
# to prove a guest kernel: the guest boots, and ss-kill-check.sh can run in it. The pod has the
# node image p5 with the command "sleep" (it has ss, python3 and curl), in its own namespace.
# Usage: kernel-pod.sh up [host node] | down
set -u
NS=p2gaps-ktest
POD=ktest
KC=(/root/kata-cp/bin/kubectl --kubeconfig /root/kata-cp/secrets/kubeconfig)
case "${1:-}" in
  up)
    HN=${2:-kata-bb-worker3}
    "${KC[@]}" get namespace "$NS" >/dev/null 2>&1 || "${KC[@]}" create namespace "$NS"
    cat <<YAML | "${KC[@]}" apply -f -
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS, labels: {lab: p2gaps-ktest}}
spec:
  runtimeClassName: kata-clh-runtime-rs-fix-direct-ovs
  restartPolicy: Never
  nodeSelector: {kubernetes.io/hostname: $HN}
  terminationGracePeriodSeconds: 2
  automountServiceAccountToken: false
  enableServiceLinks: false
  containers:
    - name: c
      image: docker.io/library/nvke-node-podvm:bcc4376f-p5
      imagePullPolicy: Never
      securityContext: {privileged: true}
      command: ["sleep", "1500"]
      resources: {limits: {cpu: "1", memory: 1Gi}}
YAML
    t0=$(date +%s)
    if "${KC[@]}" -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=240s >/dev/null 2>&1; then
      echo "the pod is Ready after $(( $(date +%s) - t0 )) s on $("${KC[@]}" -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}'), pod IP $("${KC[@]}" -n "$NS" get pod "$POD" -o jsonpath='{.status.podIP}')"
      "${KC[@]}" -n "$NS" exec "$POD" -- sh -c 'echo "guest kernel: $(uname -r) built $(uname -v)"; echo "tcp_diag_destroy in the kernel: $(grep -c -w tcp_diag_destroy /proc/kallsyms), inet_diag symbols: $(grep -c " inet_diag_" /proc/kallsyms), openvswitch symbols: $(grep -c " ovs_" /proc/kallsyms)"'
    else
      echo "FAIL the pod is not Ready after 240 s"
      "${KC[@]}" -n "$NS" get pod "$POD" -o wide
      "${KC[@]}" -n "$NS" get events --sort-by=.lastTimestamp | tail -8 | cut -c1-220
      exit 1
    fi
    ;;
  down)
    "${KC[@]}" -n "$NS" delete pod "$POD" --ignore-not-found --wait=true --timeout=120s
    "${KC[@]}" delete namespace "$NS" --ignore-not-found --wait=true --timeout=120s
    ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
