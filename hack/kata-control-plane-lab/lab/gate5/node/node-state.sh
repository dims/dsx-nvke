#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5: the state of the kind node. It only reads. lib.sh sends it to "bash -s" in the node.
#
#   node-state.sh <namespace of the node pods>
#
# Lines that start with "KV " hold the values that a test must not change:
#   KV <pod> <key>=<value>
# The block between "== SUMMARY" and "== END SUMMARY" holds what the node has (units, containerd
# configuration, handlers, Kata files). lib.sh shows the difference of the block before and after.
NS=${1:-gate4}
K=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
sec() {
  echo
  echo "== $*"
}
unit_line() { echo "$1: $(systemctl show "$1" -p MainPID -p ActiveState -p NRestarts -p ActiveEnterTimestamp | tr '\n' ' ')"; }
# The start time of a process in clock ticks after boot (field 22 of /proc/<pid>/stat).
start_ticks() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }

sec "time"
echo "epoch=$EPOCHREALTIME utc=$(date -u +%FT%TZ)"

echo
echo "== SUMMARY"
unit_line containerd
unit_line kubelet
echo "containerd: $(containerd --version 2>&1)"
echo "kata VERSION file: $(cat /opt/kata/VERSION 2>&1)"
echo "kata shim (rust): $(/opt/kata/runtime-rs/bin/containerd-shim-kata-v2 --version 2>&1 | head -1)"
echo "cloud-hypervisor: $(/opt/kata/bin/cloud-hypervisor --version 2>&1)"
echo "config.toml: $(stat -c 'inode=%i size=%s mtime=%y' /etc/containerd/config.toml 2>&1) sha256=$(sha256sum /etc/containerd/config.toml 2>/dev/null | cut -c1-16)"
echo "config.toml imports line: $(grep -n '^imports' /etc/containerd/config.toml 2>&1)"
for f in $(grep '^imports' /etc/containerd/config.toml 2>/dev/null | grep -o '"[^"]*"' | tr -d '"'); do
  if [ -e "$f" ]; then
    echo "import $f: present, $(stat -c 'inode=%i size=%s mtime=%y' "$f") sha256=$(sha256sum "$f" | cut -c1-16)"
  else
    echo "import $f: MISSING"
  fi
done
echo "/etc/containerd: $(ls /etc/containerd 2>&1 | tr '\n' ' ')"
echo "/etc/containerd/conf.d: $(ls /etc/containerd/conf.d 2>&1 | tr '\n' ' ')"
echo "handlers in the merged containerd configuration: $(containerd config dump 2>/dev/null | grep -E '^[[:space:]]*\[plugins\..*\.runtimes\.[A-Za-z0-9_-]+\]$' | sed -E 's/.*runtimes\.([A-Za-z0-9_-]+)\]$/\1/' | sort -u | tr '\n' ' ')"
echo "handlers that the node reports: $("${K[@]}" get node -o jsonpath='{.items[0].status.runtimeHandlers[*].name}' 2>&1 | tr ' ' '\n' | sort | tr '\n' ' ')"
echo "node labels with kata: $("${K[@]}" get node -o jsonpath='{.items[0].metadata.labels}' 2>&1 | tr ',' '\n' | grep -i kata | tr '\n' ' ')"
echo "runtime classes (name handler memory-overhead kata-version managed-by):"
"${K[@]}" get runtimeclass --no-headers -o custom-columns='NAME:.metadata.name,HANDLER:.handler,MEM:.overhead.podFixed.memory,VERSION:.metadata.annotations.katacontainers\.io/kata-version,MANAGED:.metadata.labels.app\.kubernetes\.io/managed-by' 2>&1 | sed 's/^/   /'
echo "/opt/kata-fix (inode size name):"
find /opt/kata-fix -maxdepth 1 -mindepth 1 -printf '   %i %s %f -> %l\n' 2>&1 | sort -k3
echo "/opt/kata/share/kata-containers (inode size name):"
find /opt/kata/share/kata-containers -maxdepth 1 -mindepth 1 -printf '   %i %s %f -> %l\n' 2>&1 | sort -k3
echo "/opt/kata binaries (inode size name):"
find /opt/kata/bin /opt/kata/libexec /opt/kata/runtime-rs/bin -maxdepth 1 -type f -printf '   %i %s %p\n' 2>&1 | sort -k3
echo "/etc/modules-load.d: $(ls /etc/modules-load.d 2>&1 | tr '\n' ' ')"
echo "helm releases: $("${K[@]}" get secret -A -l owner=helm --no-headers -o custom-columns='NAME:.metadata.name,STATUS:.metadata.labels.status' 2>&1 | tr -s ' ' | tr '\n' ';')"
echo "kata-deploy objects: $("${K[@]}" -n kube-system get daemonset,job,cronjob,pod,configmap --no-headers 2>&1 | awk '/kata-deploy/ {printf "%s(%s) ", $1, $2}')"
echo "== END SUMMARY"

sec "all pods of the host cluster"
"${K[@]}" get pods -A -o wide 2>&1

sec "node pods ($NS)"
"${K[@]}" -n "$NS" get pods -o wide 2>&1
"${K[@]}" -n "$NS" get endpointslices 2>&1

sec "sandboxes and containers in containerd"
crictl pods --namespace "$NS" 2>&1
crictl ps -a --label io.kubernetes.pod.namespace="$NS" 2>&1

sec "values of each node pod"
for p in $("${K[@]}" -n "$NS" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "KV $p pod_uid=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.metadata.uid}')"
  echo "KV $p pod_ip=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.status.podIP}')"
  echo "KV $p restarts=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  echo "KV $p container_id=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.status.containerStatuses[0].containerID}')"
  echo "KV $p container_started=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')"
  echo "KV $p ready_since=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"/"}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
  echo "KV $p runtime_class=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.spec.runtimeClassName}')"
  sb=$(crictl pods -q --state ready --label io.kubernetes.pod.namespace="$NS" --label io.kubernetes.pod.name="$p" 2>/dev/null | head -1)
  echo "KV $p sandbox_id=$sb"
  echo "KV $p sandbox_handler=$(crictl inspectp -o go-template --template '{{.status.runtimeHandler}}' "$sb" 2>/dev/null)"
  [ -n "$sb" ] || continue
  # The Kata processes of the sandbox: each one has the sandbox ID in its arguments.
  for pid in $(ps -eo pid=,args= | grep -F "$sb" | grep -v grep | awk '{print $1}'); do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
    case "$exe" in
      *containerd-shim-kata*) kind=shim ;;
      *virtiofsd*) kind=virtiofsd ;;
      *cloud-hypervisor* | *qemu-system*) kind=hypervisor ;;
      *) continue ;;
    esac
    echo "KV $p $kind.$pid=start-ticks:$(start_ticks "$pid")"
    echo "INFO $p $kind pid=$pid started=$(ps -o lstart= -p "$pid") exe=$exe"
    echo "INFO $p $kind pid=$pid open files in /opt: $(find "/proc/$pid/fd" -maxdepth 1 -lname '/opt/*' -printf '%l\n' 2>/dev/null | sort -u | tr '\n' ' ')"
    echo "INFO $p $kind pid=$pid mapped files in /opt: $(awk '$6 ~ /^\/opt/ {print $6 ($7 != "" ? "_" $7 : "")}' "/proc/$pid/maps" 2>/dev/null | sort -u | tr '\n' ' ')"
  done
done

sec "all Kata processes in the node (pid, start, program)"
for pid in $(ps -eo pid=,comm= | awk '$2 ~ /^(containerd-shim|virtiofsd|cloud-hyperviso|qemu-system)/ {print $1}'); do
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
  case "$exe" in /opt/kata*) echo "$pid $(ps -o lstart= -p "$pid") $exe" ;; esac
done

sec "processes in the root cgroup of the node (a kubelet start of a kind node needs this list to be empty)"
for pid in $(grep -v '^0$' /sys/fs/cgroup/cgroup.procs); do echo "$pid $(ps -o args= -p "$pid" 2>/dev/null | cut -c1-120)"; done

sec "loop devices that the kubelet holds"
losetup -a 2>/dev/null | grep volumeDevices | sort

sec "memory of the pod cgroups"
for cg in /sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-pod*.slice; do
  [ -d "$cg" ] || continue
  echo "$(basename "$cg"): current $(($(cat "$cg/memory.current") / 1048576)) MiB, max $(cat "$cg/memory.max"), $(grep -E '^oom_kill ' "$cg/memory.events")"
done
