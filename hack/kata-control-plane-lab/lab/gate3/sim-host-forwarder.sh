#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 3, path 2: a model of a host side forwarder (as in Kata PR 13162, where the shim opens the
# connection to the host socket). A process on the kind node joins the cgroup of the Kata sandbox
# (the cgroup that holds the shim, virtiofsd and the hypervisor) and calls the Workload API of the
# host SPIRE agent. The agent then attests that process. The log of the agent shows the selectors.
# Usage: sim-host-forwarder.sh <pod name> <label>
set -uo pipefail
source /scratch/kata-cp/work/gate3/lib.sh
POD=$1
LABEL=$2
SID=$(node crictl pods -q --namespace "$NS" --name "$POD" --state ready)
SHIM=$(node pgrep -f "containerd-shim-kata-v2 -id $SID" | head -1)
CG=$(node sh -c "cut -d: -f3 /proc/$SHIM/cgroup")
{
  say "sim ($LABEL): pod $POD, uid $(k -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}'), sandbox $SID"
  say "cgroup of the shim: $CG"
  START=$(date -u +%FT%TZ)
  node sh -c "echo \$\$ > /sys/fs/cgroup$CG/cgroup.procs && echo \"cgroup of the caller: \$(cat /proc/self/cgroup)\" && exec /var/lib/gate3/bin/spire-agent api fetch x509 -socketPath /run/spire/gate3-agent-sockets/spire-agent.sock -timeout 10s"
  echo "exit code: $?"
  sleep 1
  say "log of the host SPIRE agent"
  k -n "$SPIRE_NS" logs ds/spire-agent --since-time="$START" 2>&1 | grep -E 'attested|Fetched|No identity|could not|Failed|failed|error|warn' | sed -E 's/type:\\"([a-z0-9_]+)\\" +value:\\"([^"\\]+)\\"/\1:\2/g' | cut -c1-900
} 2>&1 | tee "$LOGS/path2/sim-host-forwarder-$LABEL.txt"
