#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Start the kind node image with systemd as PID 1 in a Kata pod, then test `kubectl exec`.
# Use: 12-kata-systemd-exec-test.sh <runtime class> <0|1>
# The second argument says if the wrapper makes the child cgroup "init" before systemd starts.
# The pod has no block volume, so the inner containerd uses the native snapshotter. It is a test of systemd and exec only.
set -uo pipefail

RC=${1:?runtime class}
INIT_CG=${2:?0 or 1}
NODE=kata-cp-control-plane
K="docker exec -i $NODE kubectl --kubeconfig /etc/kubernetes/admin.conf"
POD=systemd-exec-test

$K delete pod $POD --ignore-not-found --wait=true >/dev/null 2>&1
$K apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  runtimeClassName: $RC
  restartPolicy: Never
  containers:
    - name: node
      image: docker.io/kindest/node:v1.36.4
      imagePullPolicy: Never
      securityContext: {privileged: true}
      resources: {limits: {cpu: "2", memory: 3Gi}}
      env:
        - {name: KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER, value: native}
        - {name: MAKE_INIT_CGROUP, value: "$INIT_CG"}
      command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "wrapper: root filesystem type: \$(stat -f -c %T /kind)"
          mknod -m 600 /dev/kmsg c 1 11
          sysctl -q -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576
          if [ "\$MAKE_INIT_CGROUP" = 1 ]; then mkdir -p /sys/fs/cgroup/init; echo "wrapper: made /sys/fs/cgroup/init"; fi
          exec /usr/local/bin/entrypoint /sbin/init
      volumeMounts:
        - {name: run, mountPath: /run}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - name: run
      emptyDir: {medium: Memory}
    - name: tmp
      emptyDir: {medium: Memory}
EOF

$K wait --for=condition=Ready pod/$POD --timeout=180s || { $K describe pod $POD | tail -8 | cut -c1-600; exit 1; }
sleep 25
echo "== pod log (wrapper and kind entrypoint)"
$K logs $POD 2>&1 | cut -c1-200 | head -40
echo "== exec test"
$K exec $POD -- sh -c 'echo "exec works. state: $(systemctl is-system-running 2>&1)"; echo "cgroup of this process: $(cat /proc/self/cgroup)"; echo "subtree_control of the container root: $(cat /sys/fs/cgroup/cgroup.subtree_control)"; ls /sys/fs/cgroup | grep -E "^(init|init.scope|system.slice|kubelet|kubelet.slice)$" | tr "\n" " "; echo; echo "containerd: $(systemctl is-active containerd)"; systemctl --failed --no-legend 2>&1 | head -8' 2>&1 | cut -c1-400
echo "exec exit code: $?"
echo "== pod state"
$K get pod $POD -o jsonpath='{.status.phase} restarts={.status.containerStatuses[0].restartCount}{"\n"}'
