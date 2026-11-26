#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 3, path 3: steps for a node pod that has its own SPIRE agent with k8s_psat.
# Usage: p3.sh <step> <pod> [arguments]
#   entries <pod>            make the node alias and the host ID entry for the pod (a new UUID for each pod name)
#   up <pod> <class|runc>    make the claim and the pod, wait until the pod runs
#   status <pod> <label>     agent log, server view of the agent, SVID fetch of a workload, token claims
#   fetch <pod>              only the SVID fetch of a workload in the pod
#   token <pod>              only the time claims of the projected token that the container sees
#   del-pod <pod>            delete the pod, keep the claim
#   del-claim <pod>          delete the claim (the agent data)
# Variable TOKEN_SECONDS: life of the projected token (default 600, the minimum).
set -uo pipefail
source /scratch/kata-cp/work/gate3/lib.sh
STEP=$1
POD=$2
OUT="$LOGS/path3"
mkdir -p "$OUT"
SOCK=/tmp/spire-agent/public/api.sock
px() { k -n "$NS" exec "$POD" -- "$@"; }
uuid_of() {
  [ -s "$OUT/$POD-uuid.txt" ] || cat /proc/sys/kernel/random/uuid >"$OUT/$POD-uuid.txt"
  cat "$OUT/$POD-uuid.txt"
}

case "$STEP" in
  entries)
    uuid=$(uuid_of)
    say "node alias for the agent of pod $POD, and the host ID spiffe://$TD/host/$uuid for root in that pod"
    spire entry create -node -spiffeID "spiffe://$TD/node-pod/$POD" -selector k8s_psat:cluster:gate3-pods \
      -selector k8s_psat:agent_ns:gate3 -selector k8s_psat:agent_sa:kata-node -selector "k8s_psat:agent_pod_name:$POD"
    spire entry create -parentID "spiffe://$TD/node-pod/$POD" -spiffeID "spiffe://$TD/host/$uuid" -selector unix:uid:0
    ;;
  up)
    CLASS=$3
    drop=()
    [ "$CLASS" != runc ] || drop+=(-e '/#@runtimeclass$/d')
    sed "${drop[@]}" -e 's/ *#@[a-z]*$//' -e "s/\${POD}/$POD/g" -e "s/\${RUNTIME_CLASS}/$CLASS/" -e "s/\${UUID}/$(uuid_of)/" \
      -e "s/\${TOKEN_SECONDS}/${TOKEN_SECONDS:-600}/" "$G3/51-psat-pod.yaml.tmpl" >"$OUT/$POD-pod.yaml"
    date -u +%FT%TZ >"$OUT/$POD-last-up.txt"
    ki apply -f - <"$OUT/$POD-pod.yaml"
    k -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s || { k -n "$NS" describe pod "$POD" | tail -15; exit 3; }
    k -n "$NS" get pod "$POD" -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,CLASS:.spec.runtimeClassName,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount,START:.status.startTime
    ;;
  status)
    LABEL=$3
    {
      say "status of $POD ($LABEL) at $(date -u +%FT%TZ)"
      k -n "$NS" get pod "$POD" -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,CLASS:.spec.runtimeClassName,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount,START:.status.startTime
      say "kernel of the container: $(px uname -r)"
      say "agent data folder"
      px sh -c 'findmnt -n -o TARGET,FSTYPE /var/lib/spire-agent; ls -la /var/lib/spire-agent'
      say "agent log (attestation lines)"
      k -n "$NS" logs "$POD" 2>&1 | grep -E 'entry:|Starting agent|SVID is not found|No pre-existing|Node attestation|SVID loaded|expired|recovered|reattest|Reattest|re-attest|not active|Starting Workload|level=error|level=warn|Agent is banned|shut' | cut -c1-330 | tail -25
      say "the agents that the server knows"
      spire agent list 2>&1
      say "SVID fetch of a workload (root) in the pod"
      px /usr/local/bin/spire-agent api fetch x509 -socketPath $SOCK -timeout 10s
      echo "exit code of the fetch: $?"
      say "time claims of the projected token in the container (not the token)"
      px sh -c 'p=$(cut -d. -f2 /var/run/secrets/tokens/token | tr "_-" "/+"); while [ $((${#p} % 4)) -ne 0 ]; do p="$p="; done; echo "$p" | base64 -d 2>/dev/null | grep -oE "\"(iat|exp)\":[0-9]+|\"aud\":\[[^]]*\]" | tr "\n" " "; echo; date +"now=%s"'
    } 2>&1 | tee "$OUT/$POD-status-$LABEL.txt"
    ;;
  fetch)
    px /usr/local/bin/spire-agent api fetch x509 -socketPath $SOCK -timeout 10s
    ;;
  token)
    px sh -c 'p=$(cut -d. -f2 /var/run/secrets/tokens/token | tr "_-" "/+"); while [ $((${#p} % 4)) -ne 0 ]; do p="$p="; done; echo "$p" | base64 -d 2>/dev/null | grep -oE "\"(iat|exp)\":[0-9]+" | tr "\n" " "; date +"now=%s"'
    ;;
  del-pod)
    k -n "$NS" delete pod "$POD" --wait=true --timeout=120s
    ;;
  del-claim)
    k -n "$NS" delete pvc "$POD-data" --wait=true --timeout=120s
    ;;
  *)
    echo "unknown step $STEP"
    exit 2
    ;;
esac
