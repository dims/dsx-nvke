#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 3, path 2, extra variant: the hostPath volume is the socket file itself (type: Socket), not
# its folder. Usage: run-path2-file.sh <runc|RuntimeClass name> <run number>
set -uo pipefail
source /scratch/kata-cp/work/gate3/lib.sh
CLASS=$1
RUN=$2
short=${CLASS#kata-}
POD="sockfile-${short}-r${RUN}"
OUT="$LOGS/path2/hostpath-file-${CLASS}-run${RUN}"
mkdir -p "$OUT"
rc_line=""
[ "$CLASS" = runc ] || rc_line="runtimeClassName: $CLASS"
cat >"$OUT/pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: gate3
  labels: {gate3-test: sock}
spec:
  $rc_line
  serviceAccountName: sock-test
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 2
  containers:
    - name: test
      image: nvke-node:bcc4376f-amd64
      imagePullPolicy: Never
      command: ["/bin/sleep", "infinity"]
      resources:
        requests: {cpu: 100m, memory: 512Mi}
        limits: {cpu: "1", memory: 512Mi}
      volumeMounts:
        - {name: spire-socket-file, mountPath: /spire-file/agent.sock}
        - {name: tools, mountPath: /gate3-bin, readOnly: true}
  volumes:
    - name: spire-socket-file
      hostPath: {path: /run/spire/gate3-agent-sockets/spire-agent.sock, type: Socket}
    - name: tools
      hostPath: {path: /var/lib/gate3/bin, type: Directory}
YAML
px() { k -n "$NS" exec "$POD" -- "$@"; }
{
  say "run: class=$CLASS volume=hostpath-file run=$RUN pod=$POD date=$(date -u +%FT%TZ)"
  ki apply -f - <"$OUT/pod.yaml"
  if ! k -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout="${WAIT:-90s}"; then
    k -n "$NS" get events --field-selector "involvedObject.name=$POD" -o custom-columns=T:.type,R:.reason,M:.message | cut -c1-700
    say "RESULT class=$CLASS volume=hostpath-file run=$RUN: POD DID NOT START"
    k -n "$NS" delete pod "$POD" --wait=true --timeout=120s
    exit 3
  fi
  px uname -r
  px sh -c "findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS /spire-file/agent.sock; ls -la /spire-file/"
  px /gate3-bin/uds-probe stat /spire-file/agent.sock
  px /gate3-bin/uds-probe connect /spire-file/agent.sock
  px /usr/local/bin/spire-agent api fetch x509 -socketPath /spire-file/agent.sock -timeout 10s
  rc=$?
  if [ "$rc" = 0 ]; then say "RESULT class=$CLASS volume=hostpath-file run=$RUN: PASS (X.509 SVID received)"; else say "RESULT class=$CLASS volume=hostpath-file run=$RUN: FAIL (no SVID, exit code $rc)"; fi
  k -n "$NS" delete pod "$POD" --wait=true --timeout=120s
} 2>&1 | tee "$OUT/run.log"
