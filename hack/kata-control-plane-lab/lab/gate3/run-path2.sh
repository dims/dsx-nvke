#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 3, path 2: one run of the host socket test.
# Usage: run-path2.sh <runc|RuntimeClass name> <hostpath|csi> <run number> [keep]
# The pod mounts the Workload API socket folder of the host SPIRE agent. The script records what
# the container sees for the socket file, the errno of connect(), and the result of
# "spire-agent api fetch x509". With "hostpath" it also runs the reverse test: a process in the
# pod binds a socket in a shared folder, and a process on the kind node connects to it.
# With "keep" the pod stays for more tests.
set -uo pipefail
source /scratch/kata-cp/work/gate3/lib.sh

CLASS=$1
VOL=$2
RUN=$3
KEEP=${4:-}
short=${CLASS#kata-}
POD="sock-${VOL}-${short}-r${RUN}"
OUT="$LOGS/path2/${VOL}-${CLASS}-run${RUN}"
mkdir -p "$OUT"
SOCK=/spire-agent-socket/spire-agent.sock

render() {
  local drop=()
  [ "$CLASS" != runc ] || drop+=(-e '/#@runtimeclass$/d')
  if [ "$VOL" = hostpath ]; then drop+=(-e '/#@csi$/d'); ro=false; else drop+=(-e '/#@hostpath$/d'); ro=true; fi
  sed "${drop[@]}" -e 's/ *#@[a-z]*$//' -e "s/\${POD}/$POD/" -e "s/\${RUNTIME_CLASS}/$CLASS/" -e "s/\${READONLY}/$ro/" "$G3/30-sock-pod.yaml.tmpl"
}
px() { k -n "$NS" exec "$POD" -- "$@"; }

{
  say "run: class=$CLASS volume=$VOL run=$RUN pod=$POD date=$(date -u +%FT%TZ)"
  render >"$OUT/pod.yaml"
  START=$(date -u +%FT%TZ)
  ki apply -f - <"$OUT/pod.yaml"
  if ! k -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout="${WAIT:-120s}"; then
    say "the pod is not Ready. Describe and events:"
    k -n "$NS" describe pod "$POD" | tail -40
    k -n "$NS" get pod "$POD" -o yaml >"$OUT/pod-status.yaml"
    node sh -c "journalctl -u containerd --since '3 minutes ago' --no-pager | grep -iE 'error|fail' | tail -30" >"$OUT/containerd-errors.txt" 2>&1
    say "RESULT class=$CLASS volume=$VOL run=$RUN: POD DID NOT START"
    [ -n "$KEEP" ] || k -n "$NS" delete pod "$POD" --wait=true --timeout=120s
    exit 3
  fi
  k -n "$NS" get pod "$POD" -o wide
  say "kernel of the container, and kernel of the kind node"
  px uname -r
  node uname -r
  say "the mount of the socket folder in the container"
  px sh -c "findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS /spire-agent-socket; ls -la /spire-agent-socket/; stat -c '%n: %F, mode %a, inode %i, device %D' $SOCK"
  say "probe: lstat and statfs of the socket file"
  px /gate3-bin/uds-probe stat $SOCK
  say "probe: connect()"
  px /gate3-bin/uds-probe connect $SOCK
  echo "exit code of the probe: $?"
  say "spire-agent api fetch x509 through the socket"
  px /usr/local/bin/spire-agent api fetch x509 -socketPath $SOCK -timeout 10s
  rc=$?
  echo "exit code of spire-agent api fetch: $rc"
  say "Unix sockets that the kernel of the container knows (its network namespace)"
  px sh -c 'echo "lines in /proc/net/unix: $(grep -c . /proc/net/unix)"; echo "lines with spire: $(grep -c spire /proc/net/unix)"; ss -xl 2>&1 | head -20'
  if [ "$VOL" = hostpath ]; then
    say "reverse test: a process in the pod binds /gate3-shared/$POD.sock"
    px sh -c "nohup /gate3-bin/uds-probe listen /gate3-shared/$POD.sock >/tmp/listen.log 2>&1 & sleep 1; cat /tmp/listen.log"
    say "reverse test: a second process in the pod connects"
    px /gate3-bin/uds-probe connect "/gate3-shared/$POD.sock"
    say "reverse test: a process on the kind node (host kernel) looks at the same file and connects"
    node /var/lib/gate3/bin/uds-probe stat "/var/lib/gate3/shared/$POD.sock"
    node /var/lib/gate3/bin/uds-probe connect "/var/lib/gate3/shared/$POD.sock"
    px cat /tmp/listen.log
  fi
  say "host SPIRE agent log since the pod start (lines about a workload call)"
  k -n "$SPIRE_NS" logs ds/spire-agent --since-time="$START" 2>&1 | grep -vE 'Synchronize|synchroniz|Entry created|Entry updated|Renewing|Updated X509|Cache|cache' | cut -c1-400 | tail -20
  if [ "$rc" = 0 ]; then
    say "RESULT class=$CLASS volume=$VOL run=$RUN: PASS (X.509 SVID received)"
  else
    say "RESULT class=$CLASS volume=$VOL run=$RUN: FAIL (no SVID, exit code $rc)"
  fi
  if [ -z "$KEEP" ]; then
    k -n "$NS" delete pod "$POD" --wait=true --timeout=120s
    node sh -c "[ ! -e /var/lib/gate3/shared/$POD.sock ] || unlink /var/lib/gate3/shared/$POD.sock"
  fi
} 2>&1 | tee "$OUT/run.log"
