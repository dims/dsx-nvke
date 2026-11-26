#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 2, part 2: one sample. It runs in a control plane pod (kubectl exec, script on stdin).
# SERVER = the URL of the API server of this pod.
# It prints: the etcd metrics, the API server request counts, the CPU and memory of the etcd and
# kube-apiserver containers from their cgroups, and the memory of the kernel that the pod sees.
echo "### time $(date +%s.%N)"
echo "### etcd"
curl -s --max-time 10 http://127.0.0.1:2381/metrics |
  grep -E '^(etcd_disk_(wal_fsync|backend_commit|wal_write)|etcd_mvcc_db_total_size|etcd_server_(proposals_(committed|applied|failed|pending)|leader_changes|is_leader|slow_apply|slow_read|heartbeat_send_failures|has_leader)|etcd_network_peer_round_trip_time_seconds|process_cpu_seconds_total|process_resident_memory_bytes)'
echo "### time $(date +%s.%N)"
echo "### apiserver"
kubectl --kubeconfig /etc/kubernetes/admin.conf --server "$SERVER" --request-timeout 20s get --raw /metrics |
  grep -E '^(apiserver_request_total|process_cpu_seconds_total|process_resident_memory_bytes|apiserver_storage_objects|apiserver_flowcontrol_rejected_requests_total|apiserver_current_inflight_requests)'
echo "### time $(date +%s.%N)"
echo "### cgroup"
for name in etcd kube-apiserver; do
  id=$(crictl ps --name "^$name\$" -q 2>/dev/null | head -1)
  dir=$(find /sys/fs/cgroup -type d -name "cri-containerd-$id.scope" 2>/dev/null | head -1)
  if [ -n "$id" ] && [ -n "$dir" ]; then
    echo "$name usage_usec $(awk '$1 == "usage_usec" {print $2}' "$dir/cpu.stat") throttled_usec $(awk '$1 == "throttled_usec" {print $2}' "$dir/cpu.stat") memory_current $(cat "$dir/memory.current")"
  else
    echo "$name no-cgroup"
  fi
done
echo "### meminfo"
grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Dirty|Writeback|AnonPages|Shmem):' /proc/meminfo
echo "### loadavg $(cat /proc/loadavg) nproc $(nproc)"
echo "### diskstats"
grep -E ' (vd[a-z]|loop2[0-9]|loop30|nvme1n1) ' /proc/diskstats
echo "### end"
