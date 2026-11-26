#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Run one small pod with a Kata RuntimeClass and show that it has a different kernel from the host.
# Use: 10-kata-test-pod.sh <runtime class> [image]
# It runs kubectl in the kind node, so it opens no TCP connection from the host.
set -uo pipefail

RC=${1:?runtime class, for example kata-clh-runtime-rs}
NODE=kata-cp-control-plane
K="docker exec -i $NODE kubectl --kubeconfig /etc/kubernetes/admin.conf"
# An image that is in the kind node already and has a shell.
IMAGE=${2:-$(docker exec $NODE crictl images -o json | jq -r '.images[].repoTags[]' | grep local-path-helper | head -1)}
POD=kata-test-${RC#kata-}

echo "host kernel: $(uname -r)"
echo "runtime class: $RC, image: $IMAGE"

$K delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1
$K apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  runtimeClassName: $RC
  restartPolicy: Never
  containers:
    - name: c
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "echo guest kernel: \$(uname -r); grep MemTotal /proc/meminfo; echo cpus: \$(nproc); cat /proc/cmdline; sleep 3600"]
      resources:
        limits:
          cpu: "1"
          memory: 512Mi
EOF

start=$(date +%s)
if $K wait --for=condition=Ready "pod/$POD" --timeout=180s; then
  echo "ready after $(( $(date +%s) - start )) s"
  $K logs "$POD"
  echo "== processes of the sandbox in the kind node"
  docker exec $NODE sh -c "ps -eo pid,rss,args | grep -E 'cloud-hypervisor|qemu-system|virtiofsd|containerd-shim-kata' | grep -v grep | cut -c1-220"
  rc=0
else
  echo "NOT READY"
  # Long lines have Rust stack traces. Keep the start of each line.
  $K describe pod "$POD" | tail -12 | cut -c1-700
  echo "== containerd log of the kind node"
  docker exec $NODE journalctl -u containerd --since "-4min" --no-pager | grep -i -E 'kata|error|fail' | tail -8 | cut -c1-500
  rc=1
fi
exit $rc
