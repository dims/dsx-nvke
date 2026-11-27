#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 2, exit gate: three flows of NVKE on a cluster of the provider. Each flow starts through
# the NVKE API. Two flows have no API request: the forced certificate renewal and the key rotation.
# For these two the script starts the workflow with the command of the product page (start only).
# Nothing is written into a guest. No workflow is ended, signaled, reset or changed. No database write.
#
# It loads the steps of p2-worker/run.sh (and the scripts under it) and adds:
#   init                 copy the cluster ID, write the pod map, print the state
#   facts <label>        NVKE record of the cluster, certificate end dates, static pods, health
#   g2 <label>           PATCH enableEtcdEncryption: true, watch the workflow, check the Secrets
#   rotate <label>       start RotateEtcdEncryptionKey as the product page says (start only), watch, check
#   g1 <label>           start the forced RenewK8sCertsV2 as the product page says (start only), watch, check
#   upgrade <label> <version> <image>   PATCH the version and the machine template, watch the upgrade
#   pool-upgrade <label> <version> <image>   PATCH the worker pool and record what NVKE does with the worker
#   health <label>       nodes, etcd, NVKE: the pass rules for a healthy cluster
# Usage: LOG_DIR=<run folder> run.sh <step>
set -euo pipefail
. /root/kata-cp/bin/env.sh
export NS=${NS:-d}
export LOG_DIR=${LOG_DIR:-$W/logs/p2g/g-1}
export CLUSTER_RUN=${CLUSTER_RUN:-$W/logs/p2s6b/fix-1}

# shellcheck disable=SC1090
source <(sed '/^step=\${1:-}$/,$d' "$W/p2-worker/run.sh")
export DISK_LOG=$W/logs/p2g/disk.txt
export STORAGE_LOOP_LOG=$W/logs/p2g/storage-loop.out
GATE_LIMIT=${GATE_LIMIT:-2700}

cluster_json() { api get "/api/clusters/$(cluster_id)" | api_body; }
# One line: what NVKE says about the cluster. No secret is in this record.
cluster_line() {
  cluster_json | jq -c '{version: .controlPlaneKubernetesVersion, etcdEncrypted, nextCertRenewalDue,
    conditions: ((.conditions // {}) | to_entries | map(select((.value.status // "") == "True" or (.key | test("certificateRenewal|etcdKeyRotation|updateInProgress|updateFailed"))) | {(.key): (.value | del(.lastTransitionTime))}) | add)}' | cut -c1-900 || true
}

# The static pods of the control plane: node, container, restarts, start time (from the mirror pods).
static_pods() {
  ik a -n kube-system get pods -l tier=control-plane -o json | jq -r '.items[] | "\(.spec.nodeName) \(.metadata.labels.component) image \(.spec.containers[0].image | sub(".*/"; "")) restarts \(.status.containerStatuses[0].restartCount) started \(.status.containerStatuses[0].state.running.startedAt // "-") container \(.status.containerStatuses[0].containerID | sub(".*//"; "") | .[0:12])"' | sort
}

# The end dates of the certificates of each control plane node (public certificates only).
cert_dates() {
  local r
  for r in "${CPS[@]}"; do
    echo "$(pn "$r"): $(pod "$r" sh -c 'for c in apiserver apiserver-kubelet-client apiserver-etcd-client front-proxy-client etcd/server etcd/peer etcd/healthcheck-client; do printf "%s=%s; " "$c" "$(openssl x509 -noout -enddate -in /etc/kubernetes/pki/$c.crt | cut -d= -f2)"; done; for f in admin controller-manager scheduler; do printf "%s.conf=%s; " "$f" "$(awk "/client-certificate-data/ {print \$2}" /etc/kubernetes/$f.conf | base64 -d | openssl x509 -noout -enddate | cut -d= -f2)"; done; printf "ca=%s" "$(openssl x509 -noout -enddate -in /etc/kubernetes/pki/ca.crt | cut -d= -f2)"' 2>&1)"
  done
}

# The first bytes of the value of one of MY test Secrets in etcd. Never more than 48 bytes, cut inside the guest.
raw_secret() { # <name>
  pod a sh -c "$ETCDCTL get /registry/secrets/default/$1 --print-value-only | head -c 48 | tr -c '[:print:]' '.'" 2>/dev/null || true
}

# Lines of the agent journal of each control plane node since a time: time and message only.
agent_lines() { # <since (journalctl form)> <pattern>
  local r
  for r in "${CPS[@]}"; do
    echo "--- $(pn "$r")"
    pod "$r" sh -c "journalctl --no-pager -u nvke-agent --since '$1' | grep -i -E '$2' | sed -n -E 's/.*\"time\":\"([^\"]*)\".*\"msg\":\"([^\"]*)\".*/\\1 \\2/p' | cut -c1-200 | awk '{k=\$0; sub(/^[^ ]+ /, \"\", k); c[k]++; if (c[k] <= 3) print}' | head -${3:-40}" 2>&1 || true
  done
}

cmd_health() {
  local label=${1:-now} fail=0 want ready members healthy nvke
  write_podmap
  want=${#REPLICAS[@]}
  {
    say "health ($label) at $(date -u +%FT%TZ)"
    paste -d' ' "$PODMAP" <(cut -d' ' -f2 "$LOG_DIR/roles.txt")
    cluster_line
    nvke="$(all_nodes) nodes, $(good_nodes) good"
    [ "$(all_nodes)" = "$want" ] && [ "$(good_nodes)" = "$want" ] && echo "ok   NVKE: $nvke" || { echo "FAIL NVKE: $nvke, the pod map has $want"; fail=1; }
    ik a get nodes -o wide | cut -c1-170 | tee "$LOG_DIR/.nodes"
    ready=$(grep -c -E ' Ready +' "$LOG_DIR/.nodes" || true)
    [ "$ready" = "$want" ] && [ "$(grep -c -E ' (NotReady|Unknown)' "$LOG_DIR/.nodes" || true)" = 0 ] && echo "ok   $ready Ready nodes (${#CPS[@]} control plane, ${#WKS[@]} worker)" || { echo "FAIL $ready Ready nodes of $want"; fail=1; }
    etcdctl a member list -w simple | tee "$LOG_DIR/.members" || true
    members=$(grep -c ', started, ' "$LOG_DIR/.members" || true)
    healthy=$(etcdctl a endpoint health --cluster 2>&1 | grep -c 'is healthy' || true)
    [ "$members" = "${#CPS[@]}" ] && [ "$healthy" = "${#CPS[@]}" ] && [ "$(grep -c . "$LOG_DIR/.members")" = "${#CPS[@]}" ] && echo "ok   $members started etcd members, $healthy healthy" || { echo "FAIL etcd: $members started members, $healthy healthy"; fail=1; }
    echo "pods of the new cluster that are not Running or Completed: [$(ik a get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed" {print $1 "/" $2 "=" $4}' | grep -v '^default/p1-t-' | tr '\n' ' ')]"
    placement_table
    [ "$fail" = 0 ] && echo "RESULT health $label: PASS" || echo "RESULT health $label: FAIL"
  } 2>&1 | tee "$LOG_DIR/health-$label.txt"
  grep -q "RESULT health $label: PASS" "$LOG_DIR/health-$label.txt"
}

cmd_facts() {
  local label=${1:-now}
  write_podmap
  {
    say "facts ($label) at $(date -u +%FT%TZ)"
    cluster_line
    say "certificate end dates"
    cert_dates
    say "static pods"
    static_pods
    say "encryption settings of each API server (flag and file names only)"
    for r in "${CPS[@]}"; do echo "$(pn "$r"): $(pod "$r" sh -c 'grep -o -- "--encryption-provider-config[^ ]*" /etc/kubernetes/manifests/kube-apiserver.yaml | tr "\n" " "; ls -la /etc/kubernetes/ 2>/dev/null | grep -i -E "encrypt" | awk "{print \$1, \$NF}" | tr "\n" ";"; ls /etc/kubernetes/pki 2>/dev/null | grep -i encrypt | tr "\n" " "' 2>&1)"; done
  } 2>&1 | tee "$LOG_DIR/facts-$label.txt"
}

# What a flow must not change at the pods of the provider: pod UID, host node, restart count, claims, address.
provider_pods() {
  local r m
  for r in "${REPLICAS[@]}"; do
    m=$(pn "$r")
    k -n "$NS" get pod "$m" -o json | jq -r '"pod \(.metadata.name) uid \(.metadata.uid) node \(.spec.nodeName) restarts \(.status.containerStatuses[0].restartCount) image \(.spec.containers[0].image | sub(".*:"; ""))"'
  done
}

# --- G2: etcd encryption ---------------------------------------------------------------------
cmd_g2() {
  local label=${1:-g2} out fail=0 since jsince wid st line last="" end v
  out="$LOG_DIR/g2-$label.txt"
  write_podmap
  wid="enable-etcd-encryption-$(cluster_id)"
  {
    say "G2 ($label): etcd encryption through the NVKE API, at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") etcd encryption $label"
    cluster_line
    say "a test Secret before the change, and the first bytes of its value in etcd"
    ik a -n default create secret generic p2g-before --from-literal=note=p2g-written-before-the-encryption 2>&1 | tail -1 || true
    echo "p2g-before in etcd: [$(raw_secret p2g-before)]"
    provider_pods >"$LOG_DIR/.g2-pods-before"
    cmd_cp_state "$label-before" >/dev/null
    static_pods >"$LOG_DIR/.g2-static-before" || true
    cat "$LOG_DIR/.g2-static-before"
    cmd_probe_start "g2-$label" $((GATE_LIMIT + 600))
    sleep 5
    since=$(date -u +%FT%TZ)
    jsince=$(date -u '+%F %T')
    printf '{"enableEtcdEncryption": true}\n' >"$LOG_DIR/g2-$label-body.json"
    stamp "g2-$label-patch"
    say "PATCH /api/clusters/$(cluster_id) with enableEtcdEncryption: true, at $(date -u +%T)"
    api patch "/api/clusters/$(cluster_id)" "$LOG_DIR/g2-$label-body.json" >"$LOG_DIR/g2-$label-response.txt" 2>&1 || true
    tail -1 "$LOG_DIR/g2-$label-response.txt"
    if ! grep -q '^HTTP 20[0-9]$' "$LOG_DIR/g2-$label-response.txt"; then
      cut -c1-900 "$LOG_DIR/g2-$label-response.txt"
      cmd_probe_stop "g2-$label" >/dev/null
      echo "RESULT g2 $label: NVKE did not accept the PATCH"
      exit 2
    fi
    # One look each 10 s: the record of NVKE and the state of the workflow.
    end=$(( $(date +%s) + GATE_LIMIT ))
    while [ "$(date +%s)" -lt "$end" ]; do
      sleep 10
      st=$(temporal workflow describe --workflow-id "$wid" --output json 2>/dev/null | jq -r '.workflowExecutionInfo.status // "none"' 2>/dev/null || echo none)
      line="$(cluster_line) | workflow ${st#WORKFLOW_EXECUTION_STATUS_}"
      echo "$(date -u +%T) $line" >>"$LOG_DIR/g2-$label-timeline.txt"
      if [ "$line" != "$last" ]; then echo "$(date -u +%T) $line" | cut -c1-500; last=$line; fi
      case "$st" in *COMPLETED* | *FAILED* | *CANCELED* | *TERMINATED* | *TIMED_OUT*) break ;; esac
    done
    stamp "g2-$label-end"
    sleep 15
    cmd_probe_stop "g2-$label"
    say "the workflow $wid"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *(Status|Type|StartTime|CloseTime|RunTime|HistoryLength)' || echo "no workflow with this ID"
    echo "time from the PATCH to the end of the watch: $(between "g2-$label-patch" "g2-$label-end") s"
    say "workflows since the PATCH"
    workflows_since "$since" "$LOG_DIR/g2-$label-record"
    say "what NVKE says at the end"
    cluster_line
    say "static pods after (the order of the restarts is in the start times)"
    static_pods | tee "$LOG_DIR/.g2-static-after" || true
    say "encryption settings of each API server (flag and file names only)"
    for r in "${CPS[@]}"; do echo "$(pn "$r"): $(pod "$r" sh -c 'grep -o -- "--encryption-provider-config[^ ]*" /etc/kubernetes/manifests/kube-apiserver.yaml | tr "\n" " "' 2>&1)"; done
    say "the agent of each control plane node since the PATCH (time and message only)"
    agent_lines "$jsince" 'kube-vip|encrypt|graceful' 40
    say "the provider log since the PATCH"
    provider_log_since "$since" | head -20 || true
    echo "lines of the provider since the PATCH: $(provider_log_since "$since" | grep -c . || true), error lines: $(provider_log_since "$since" | grep -c ' ERROR ' || true)"
    say "checks"
    [ "$(cluster_json | jq -r '.etcdEncrypted')" = true ] && echo "ok   NVKE reports etcdEncrypted: true" || { echo "FAIL NVKE does not report etcdEncrypted: true"; fail=1; }
    [ "$(cluster_json | jq -r '.conditions.updateInProgress.status // "False"')" != True ] && echo "ok   no update in progress" || { echo "FAIL an update is in progress"; fail=1; }
    [ "$(cluster_json | jq -r '.conditions.updateFailed.status // "False"')" != True ] && echo "ok   no failed update" || { echo "FAIL NVKE reports a failed update: $(cluster_json | jq -c '.conditions.updateFailed')"; fail=1; }
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *Status' | grep -q -i COMPLETED && echo "ok   the workflow is completed" || { echo "FAIL the workflow is not completed"; fail=1; }
    v=$(ik a -n default get secret p2g-before -o jsonpath='{.data.note}' 2>/dev/null | base64 -d 2>/dev/null || true)
    [ "$v" = p2g-written-before-the-encryption ] && echo "ok   the Secret that was written before is readable, with the same value" || { echo "FAIL the Secret p2g-before is not readable"; fail=1; }
    line=$(raw_secret p2g-before)
    echo "p2g-before in etcd now: [$line]"
    ik a -n default create secret generic p2g-after --from-literal=note=p2g-written-after-the-encryption 2>&1 | tail -1 || true
    line=$(raw_secret p2g-after)
    echo "p2g-after in etcd: [$line]"
    case "$line" in k8s:enc:*) echo "ok   the new Secret is stored encrypted (prefix ${line%%:v1:*}:v1)" ;; *) echo "FAIL the new Secret is not stored with an encryption prefix"; fail=1 ;; esac
    provider_pods >"$LOG_DIR/.g2-pods-after"
    if diff "$LOG_DIR/.g2-pods-before" "$LOG_DIR/.g2-pods-after"; then echo "ok   the pods of the provider have no change (UID, host node, restart count, image)"; else echo "note the pods of the provider changed"; fi
    cmd_cp_state "$label-after" >/dev/null
    if diff "$LOG_DIR/cp-state-$label-before.txt" "$LOG_DIR/cp-state-$label-after.txt"; then echo "ok   claims, addresses, etcd members and boot IDs have no change"; else echo "note the state of the control plane changed (lines above)"; fi
    grep -q 'failed: 0$' "$LOG_DIR/probe-g2-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    [ "$fail" = 0 ] && echo "RESULT g2 $label: PASS" || echo "RESULT g2 $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT g2 $label: PASS" "$out"
}

# The end date of three certificates of each control plane node, as seconds (for a comparison).
cert_epochs() {
  local r
  for r in "${CPS[@]}"; do
    pod "$r" sh -c 'for c in apiserver etcd/server etcd/peer apiserver-etcd-client apiserver-kubelet-client; do echo "$(hostname) $c $(date -d "$(openssl x509 -noout -enddate -in /etc/kubernetes/pki/$c.crt | cut -d= -f2)" +%s)"; done' 2>/dev/null || true
  done
}

# Watch one workflow that is started: one look each 10 s at the record of NVKE and at the workflow
# state. Reads only. It ends when the workflow is closed or at the limit. It never ends a workflow.
watch_workflow() { # <workflow id> <timeline file>
  local wid=$1 file=$2 st line last="" end
  end=$(( $(date +%s) + GATE_LIMIT ))
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 10
    st=$(temporal workflow describe --workflow-id "$wid" --output json 2>/dev/null | jq -r '.workflowExecutionInfo.status // "none"' 2>/dev/null || echo none)
    line="$(cluster_line) | workflow ${st#WORKFLOW_EXECUTION_STATUS_}"
    echo "$(date -u +%T) $line" >>"$file"
    if [ "$line" != "$last" ]; then echo "$(date -u +%T) $line" | cut -c1-700; last=$line; fi
    case "$st" in *COMPLETED* | *FAILED* | *CANCELED* | *TERMINATED* | *TIMED_OUT*) return 0 ;; esac
  done
  echo "the workflow $wid is not closed after $GATE_LIMIT s. I leave it as it is."
  return 1
}

# --- G1: forced certificate renewal, the documented operator start --------------------------------
# controller/docs/certificate-renewal.md:167-189. Start only. No other change of a workflow.
cmd_g1() {
  local label=${1:-g1} out fail=0 since jsince wid r n c
  out="$LOG_DIR/g1-$label.txt"
  write_podmap
  wid="operator-k8s-cert-renewal-$(date -u +%Y%m%dT%H%M%SZ)-$(cat /proc/sys/kernel/random/uuid)"
  {
    say "G1 ($label): forced certificate renewal, at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") certificate renewal $label"
    cluster_line
    say "certificate end dates before"
    cert_dates | tee "$LOG_DIR/g1-$label-certs-before.txt" | cut -c1-330
    cert_epochs >"$LOG_DIR/.g1-epochs-before"
    provider_pods >"$LOG_DIR/.g1-pods-before"
    cmd_cp_state "$label-before" >/dev/null
    static_pods >"$LOG_DIR/.g1-static-before" || true
    cmd_probe_start "g1-$label" $((GATE_LIMIT + 600))
    sleep 5
    since=$(date -u +%FT%TZ)
    jsince=$(date -u '+%F %T')
    echo "$wid" >"$LOG_DIR/g1-$label-workflow-id.txt"
    say "the start, as controller/docs/certificate-renewal.md:183-188 says (the address is temporal.hostPort of the controller config)"
    echo "temporal workflow start --address $TEMPORAL_ADDR --namespace $TEMPORAL_NS --task-queue cloud-workflow-engine-tasks --type RenewK8sCertsV2 --workflow-id $wid --input '{\"clusterID\":\"$(cluster_id)\",\"thresholdDays\":30,\"force\":true}'" | tee "$LOG_DIR/g1-$label-command.txt"
    stamp "g1-$label-start"
    temporal workflow start --task-queue cloud-workflow-engine-tasks --type RenewK8sCertsV2 --workflow-id "$wid" --input "{\"clusterID\":\"$(cluster_id)\",\"thresholdDays\":30,\"force\":true}" 2>&1 | tee "$LOG_DIR/g1-$label-start.txt" | cut -c1-200
    if ! grep -q -i 'RunId' "$LOG_DIR/g1-$label-start.txt"; then
      cmd_probe_stop "g1-$label" >/dev/null
      echo "RESULT g1 $label: the workflow did not start"
      exit 2
    fi
    watch_workflow "$wid" "$LOG_DIR/g1-$label-timeline.txt" || fail=1
    stamp "g1-$label-end"
    sleep 15
    cmd_probe_stop "g1-$label"
    say "the workflow $wid"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *(Status|Type|StartTime|CloseTime|RunTime|HistoryLength)' || echo "no workflow with this ID"
    workflow_timeline "$wid" || true
    grep -v -E 'UpdateNodeConditions|GetNodePoolForNode|GetClusterForNode' "$LOG_DIR/workflow-$wid.txt" 2>/dev/null | sed -E 's/^[0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z/\1/; s/\(scheduled [0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z\)/(scheduled \1)/' | cut -c1-150 || true
    say "other workflows since the start"
    temporal workflow list --query "StartTime > \"$since\"" --limit 30 2>&1 | cut -c1-150 || true
    say "what NVKE says at the end"
    cluster_line
    cluster_json | jq -c '.conditions.certificateRenewal' | cut -c1-900
    say "certificate end dates after"
    cert_dates | tee "$LOG_DIR/g1-$label-certs-after.txt" | cut -c1-330
    cert_epochs >"$LOG_DIR/.g1-epochs-after"
    say "static pods after (the order of the nodes is in the start times)"
    static_pods | tee "$LOG_DIR/.g1-static-after" || true
    say "the agent of each control plane node since the start (time and message only)"
    agent_lines "$jsince" 'kube-vip|renew|cert|graceful|static pod|manifest' 60
    say "the provider log since the start"
    provider_log_since "$since" | head -20 || true
    echo "lines of the provider since the start: $(provider_log_since "$since" | grep -c . || true), error lines: $(provider_log_since "$since" | grep -c ' ERROR ' || true)"
    say "checks"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *Status' | grep -q -i COMPLETED && echo "ok   the renewal workflow is completed" || { echo "FAIL the renewal workflow is not completed"; fail=1; }
    for r in "${CPS[@]}"; do
      n=$(pn "$r")
      for c in apiserver etcd/server etcd/peer; do
        if awk -v n="$n" -v c="$c" 'FNR==NR {if ($1==n && $2==c) b=$3; next} $1==n && $2==c {a=$3} END {exit !(a > b && b > 0)}' "$LOG_DIR/.g1-epochs-before" "$LOG_DIR/.g1-epochs-after"; then
          echo "ok   $n $c: later end date ($(awk -v n="$n" -v c="$c" 'FNR==NR {if ($1==n && $2==c) b=$3; next} $1==n && $2==c {printf "%.1f hours later", ($3-b)/3600}' "$LOG_DIR/.g1-epochs-before" "$LOG_DIR/.g1-epochs-after"))"
        else
          echo "FAIL $n $c: the end date is not later"; fail=1
        fi
      done
    done
    [ "$(cluster_json | jq -r '.conditions.updateInProgress.status // "False"')" != True ] && [ -z "$(cluster_json | jq -r '.conditions.updateInProgress.type // ""')" ] && echo "ok   no update in progress, the lock is free" || { echo "FAIL NVKE reports an update in progress: $(cluster_json | jq -c '.conditions.updateInProgress')"; fail=1; }
    provider_pods >"$LOG_DIR/.g1-pods-after"
    if diff "$LOG_DIR/.g1-pods-before" "$LOG_DIR/.g1-pods-after"; then echo "ok   the pods of the provider have no change (UID, host node, restart count, image)"; else echo "note the pods of the provider changed"; fi
    cmd_cp_state "$label-after" >/dev/null
    if diff "$LOG_DIR/cp-state-$label-before.txt" "$LOG_DIR/cp-state-$label-after.txt"; then echo "ok   claims, addresses, etcd members and boot IDs have no change"; else echo "note the state of the control plane changed (lines above)"; fi
    grep -q 'failed: 0$' "$LOG_DIR/probe-g1-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    [ "$fail" = 0 ] && echo "RESULT g1 $label: PASS" || echo "RESULT g1 $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT g1 $label: PASS" "$out"
}

# --- G2, second part: the key rotation, the documented operator start ---------------------------
# controller/docs/etcd-encryption-key-rotation.md:162-194. Start only. No other change of a workflow.
key_secret_fields() { k -n nvke-controller get secret "etcd-encryption-key-$(cluster_id)" -o json 2>/dev/null | jq -r '.data | keys | join(" ")' 2>/dev/null || echo "no key Secret"; }
cmd_rotate() {
  local label=${1:-rotate} out fail=0 since jsince wid line v f
  out="$LOG_DIR/rotate-$label.txt"
  write_podmap
  wid="etcd-key-rotation-$(cluster_id)-$(date -u +%Y%m%dT%H%M%SZ)"
  {
    say "G2 ($label): rotation of the etcd encryption key, at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") key rotation $label"
    say "what the page asks before the start"
    cluster_line
    [ "$(cluster_json | jq -r '.etcdEncrypted')" = true ] && [ -z "$(cluster_json | jq -r '.conditions.updateInProgress.type // ""')" ] || { echo "RESULT rotate $label: the cluster is not encrypted or has an update in progress. Not started"; exit 2; }
    echo "Kubernetes version of the API servers: $(ik a version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion') (the page asks for 1.34 or newer)"
    echo "agent of each control plane node: $(for r in "${CPS[@]}"; do pod "$r" sh -c '/usr/local/bin/nvke-agent --version 2>&1 | head -1' | sed 's/NVKE Agent Version: //'; done | sort | uniq -c | tr '\n' ' '). The page gives two ways to prove the identity RPC: grpcurl with the client identity of the controller, or the probe of the prepare phase. I rely on the probe."
    echo "fields of the key Secret of the controller (names only): $(key_secret_fields)"
    # The page: keep the whole key Secret with the etcd backups before the start. The copy goes to the mode 700 folder and is never printed.
    f="$SEC/etcd-encryption-key-$(cluster_id)-before-$label.yaml"
    ( umask 077; k -n nvke-controller get secret "etcd-encryption-key-$(cluster_id)" -o yaml >"$f" )
    echo "copy of the key Secret before the start: $(stat -c '%s bytes, mode %a' "$f") in the secrets folder (not printed)"
    say "a test Secret before the rotation, and the first bytes of its value in etcd (prefix and key name)"
    ik a -n default create secret generic "p2g-rot-before-$label" --from-literal=note=p2g-written-before-the-rotation 2>&1 | tail -1 || true
    echo "p2g-rot-before-$label in etcd: [$(raw_secret "p2g-rot-before-$label" | cut -c1-40)]"
    provider_pods >"$LOG_DIR/.rot-pods-before"
    cmd_cp_state "$label-before" >/dev/null
    static_pods >"$LOG_DIR/.rot-static-before" || true
    cmd_probe_start "rot-$label" $((GATE_LIMIT + 600))
    sleep 5
    since=$(date -u +%FT%TZ)
    jsince=$(date -u '+%F %T')
    echo "$wid" >"$LOG_DIR/rotate-$label-workflow-id.txt"
    say "the start, as controller/docs/etcd-encryption-key-rotation.md:186-194 says"
    echo "temporal workflow start --address $TEMPORAL_ADDR --namespace $TEMPORAL_NS --type RotateEtcdEncryptionKey --task-queue cloud-workflow-engine-tasks --workflow-id $wid --id-reuse-policy RejectDuplicate --id-conflict-policy Fail --input '{\"clusterID\":\"$(cluster_id)\"}'" | tee "$LOG_DIR/rotate-$label-command.txt"
    stamp "rot-$label-start"
    temporal workflow start --type RotateEtcdEncryptionKey --task-queue cloud-workflow-engine-tasks --workflow-id "$wid" --id-reuse-policy RejectDuplicate --id-conflict-policy Fail --input "{\"clusterID\":\"$(cluster_id)\"}" 2>&1 | tee "$LOG_DIR/rotate-$label-start.txt" | cut -c1-200
    if ! grep -q -i 'RunId' "$LOG_DIR/rotate-$label-start.txt"; then
      cmd_probe_stop "rot-$label" >/dev/null
      echo "RESULT rotate $label: the workflow did not start"
      exit 2
    fi
    watch_workflow "$wid" "$LOG_DIR/rotate-$label-timeline.txt" || fail=1
    stamp "rot-$label-end"
    sleep 15
    cmd_probe_stop "rot-$label"
    say "the workflow $wid"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *(Status|Type|StartTime|CloseTime|RunTime|HistoryLength)' || echo "no workflow with this ID"
    workflow_timeline "$wid" || true
    grep -v -E 'UpdateNodeConditions|GetNodePoolForNode|GetClusterForNode' "$LOG_DIR/workflow-$wid.txt" 2>/dev/null | sed -E 's/^[0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z/\1/; s/\(scheduled [0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z\)/(scheduled \1)/' | cut -c1-150 || true
    say "what NVKE says at the end"
    cluster_line
    cluster_json | jq -c '.conditions.etcdKeyRotation' | cut -c1-600
    echo "fields of the key Secret of the controller (names only): $(key_secret_fields)"
    say "static pods after (a rotation reloads the keys and restarts nothing)"
    static_pods >"$LOG_DIR/.rot-static-after" || true
    if diff "$LOG_DIR/.rot-static-before" "$LOG_DIR/.rot-static-after"; then echo "ok   no static pod has a new container"; else echo "note static pods changed (lines above)"; fi
    say "the agent of each control plane node since the start (time and message only)"
    agent_lines "$jsince" 'encrypt|rotation|key|kube-vip' 40
    say "the provider log since the start"
    provider_log_since "$since" | head -20 || true
    echo "lines of the provider since the start: $(provider_log_since "$since" | grep -c . || true), error lines: $(provider_log_since "$since" | grep -c ' ERROR ' || true)"
    say "checks"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *Status' | grep -q -i COMPLETED && echo "ok   the rotation workflow is completed" || { echo "FAIL the rotation workflow is not completed"; fail=1; }
    [ "$(cluster_json | jq -r '.conditions.etcdKeyRotation.state // ""')" = succeeded ] && echo "ok   NVKE reports the rotation as succeeded" || { echo "FAIL NVKE reports the rotation as $(cluster_json | jq -c '.conditions.etcdKeyRotation')"; fail=1; }
    [ -z "$(cluster_json | jq -r '.conditions.updateInProgress.type // ""')" ] && echo "ok   no update in progress, the lock is free" || { echo "FAIL NVKE reports an update in progress: $(cluster_json | jq -c '.conditions.updateInProgress')"; fail=1; }
    v=$(ik a -n default get secret "p2g-rot-before-$label" -o jsonpath='{.data.note}' 2>/dev/null | base64 -d 2>/dev/null || true)
    [ "$v" = p2g-written-before-the-rotation ] && echo "ok   the Secret that was written before is readable, with the same value" || { echo "FAIL the Secret p2g-rot-before-$label is not readable"; fail=1; }
    line=$(raw_secret "p2g-rot-before-$label" | cut -c1-40)
    echo "p2g-rot-before-$label in etcd now: [$line]"
    ik a -n default create secret generic "p2g-rot-after-$label" --from-literal=note=p2g-written-after-the-rotation 2>&1 | tail -1 || true
    v=$(raw_secret "p2g-rot-after-$label" | cut -c1-40)
    echo "p2g-rot-after-$label in etcd: [$v]"
    case "$v" in k8s:enc:*) echo "ok   the new Secret is stored encrypted" ;; *) echo "FAIL the new Secret is not stored with an encryption prefix"; fail=1 ;; esac
    provider_pods >"$LOG_DIR/.rot-pods-after"
    if diff "$LOG_DIR/.rot-pods-before" "$LOG_DIR/.rot-pods-after"; then echo "ok   the pods of the provider have no change (UID, host node, restart count, image)"; else echo "note the pods of the provider changed"; fi
    cmd_cp_state "$label-after" >/dev/null
    if diff "$LOG_DIR/cp-state-$label-before.txt" "$LOG_DIR/cp-state-$label-after.txt"; then echo "ok   claims, addresses, etcd members and boot IDs have no change"; else echo "note the state of the control plane changed (lines above)"; fi
    grep -q 'failed: 0$' "$LOG_DIR/probe-rot-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    [ "$fail" = 0 ] && echo "RESULT rotate $label: PASS" || echo "RESULT rotate $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT rotate $label: PASS" "$out"
}

# --- G3: a cluster with an older Kubernetes version, then the upgrade ---------------------------
K8S_VERSION=${K8S_VERSION:-1.36.4}
# The request of p2-replace, with the Kubernetes version of this run. The image comes from IMG_CLUSTER.
cmd_post() {
  export NS IP_API POD_CIDR SERVICE_CIDR CLUSTER_NAME RUNTIME_CLASS RANGE_CIDR MACHINE_TEMPLATE
  MACHINE_TEMPLATE=$(machine_template "$IMG_P2")
  envsubst '$NS $IP_API $POD_CIDR $SERVICE_CIDR $CLUSTER_NAME $RUNTIME_CLASS $RANGE_CIDR $MACHINE_TEMPLATE' <"$R/request.json.tmpl" | jq --arg v "$K8S_VERSION" '.controlPlaneKubernetesVersion = $v' >"$LOG_DIR/request.json"
  jq -e . "$LOG_DIR/request.json" >/dev/null || die "the request is not JSON"
  say "POST /api/clusters ($CLUSTER_NAME), Kubernetes $K8S_VERSION, desiredCount 3, maxSurge 1, enableCPNodeRecycling true, image ${IMG_P2##*:}"
  stamp post
  date -u +%FT%T.%3NZ >"$LOG_DIR/post-time.txt"
  api post /api/clusters "$LOG_DIR/request.json" >"$LOG_DIR/post-response.txt" 2>&1 || true
  tail -1 "$LOG_DIR/post-response.txt"
  grep -q '^HTTP 20[012]$' "$LOG_DIR/post-response.txt" || { cut -c1-900 "$LOG_DIR/post-response.txt"; die "the API did not accept the request"; }
  api_body <"$LOG_DIR/post-response.txt" | jq -r '.id' >"$LOG_DIR/cluster-id.txt"
  say "cluster ID $(cluster_id)"
  api_body <"$LOG_DIR/post-response.txt" | jq -c '{name, id, controlPlaneKubernetesVersion, controlPlaneEndpoint, enableCPNodeRecycling}' || true
}

# Versions that the nodes of the new cluster report.
node_versions() { ik a get nodes -o json | jq -r '.items[] | "\(.metadata.name) kubelet \(.status.nodeInfo.kubeletVersion) \(if (.metadata.labels | has("node-role.kubernetes.io/control-plane")) then "control-plane" else "worker" end) ready \([.status.conditions[] | select(.type=="Ready") | .status] | join(""))"' | sort; }

cmd_upgrade() {
  local label=${1:?label} ver=${2:?version} img=${3:?image} out fail=0 since jsince before line end ok=0 total up i=0 n r wid
  out="$LOG_DIR/upgrade-$label.txt"
  write_podmap
  total=${#REPLICAS[@]}
  {
    say "G3 ($label): upgrade of the control plane to Kubernetes $ver with the image ${img##*:}, at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") upgrade $label"
    cluster_line
    node_versions
    before=$(for r in "${CPS[@]}"; do pn "$r"; done | tr '\n' ' ')
    echo "control plane Machines before: $before"
    placement_table
    static_pods | cut -c1-150 || true
    cmd_cp_state "$label-before" >/dev/null
    jq -n --arg v "$ver" --argjson t "$(machine_template "$img")" '{controlPlaneKubernetesVersion: $v, controlPlaneConfig: {infra: {machineTemplate: $t}}}' >"$LOG_DIR/upgrade-$label-body.json"
    cmd_probe_start "upgrade-$label" $((GATE_LIMIT + 600))
    sleep 5
    since=$(date -u +%FT%TZ)
    jsince=$(date -u '+%F %T')
    stamp "upgrade-$label-patch"
    say "PATCH /api/clusters/$(cluster_id) with controlPlaneKubernetesVersion $ver and the machine template (image ${img##*:}), at $(date -u +%T)"
    api patch "/api/clusters/$(cluster_id)" "$LOG_DIR/upgrade-$label-body.json" >"$LOG_DIR/upgrade-$label-response.txt" 2>&1 || true
    tail -1 "$LOG_DIR/upgrade-$label-response.txt"
    if ! grep -q '^HTTP 20[0-9]$' "$LOG_DIR/upgrade-$label-response.txt"; then
      cut -c1-900 "$LOG_DIR/upgrade-$label-response.txt"
      cmd_probe_stop "upgrade-$label" >/dev/null
      echo "RESULT upgrade $label: NVKE did not accept the PATCH"
      exit 2
    fi
    # One look each 10 s. The end: NVKE says the upgrade is over, no old control plane Machine is left, each node is good.
    end=$(( $(date +%s) + GATE_LIMIT ))
    while [ "$(date +%s)" -lt "$end" ]; do
      sample 1
      up=$(cluster_json | jq -r '"\(.conditions.controlPlaneUpgrading.status // "False") [\(.conditions.controlPlaneUpgrading.message // "")]"' 2>/dev/null || echo "?")
      line="$(state_line) | upgrading $up | $(rollout_line)"
      echo "$(date -u +%T) $line" >>"$LOG_DIR/upgrade-$label-timeline.txt"
      if [ $((i % 6)) = 0 ]; then echo "$(date -u +%T) $line" | cut -c1-420; fi
      if [ "${up%% *}" != True ] && [ "$(jqs --arg b "$before" '[$i[0].items[].metadata.name | select(. as $x | ($b | split(" ")) | index($x))] | length')" = 0 ] && [ "$(all_nodes)" = "$total" ] && [ "$(good_nodes)" = "$total" ] && [ "$(ready_pods)" = "$total" ]; then ok=$((ok + 1)); else ok=0; fi
      [ "$ok" -ge 2 ] && break
      i=$((i + 1))
      sleep 10
    done
    if [ "$ok" -ge 2 ]; then stamp "upgrade-$label-done"; echo "NVKE reports the upgrade as over, with $total good nodes, $(between "upgrade-$label-patch" "upgrade-$label-done") s after the PATCH"; else echo "FAIL the upgrade is not over after $GATE_LIMIT s"; fail=1; fi
    sleep 15
    cmd_probe_stop "upgrade-$label"
    write_podmap
    say "what NVKE says at the end"
    cluster_line
    cluster_json | jq -c '.conditions.controlPlaneUpgrading, .conditions.cpNodesRecycling' | cut -c1-300
    echo "after: $(state_line)"
    echo "control plane Machines now: $(for r in "${CPS[@]}"; do pn "$r"; done | tr '\n' ' ')"
    say "the nodes of the new cluster"
    node_versions | tee "$LOG_DIR/.upgrade-nodes"
    n=$(grep -c " kubelet v$ver control-plane ready True" "$LOG_DIR/.upgrade-nodes" || true)
    [ "$n" = "${#CPS[@]}" ] && echo "ok   each of the ${#CPS[@]} control plane nodes runs kubelet v$ver and is Ready" || { echo "FAIL $n control plane nodes run kubelet v$ver"; fail=1; }
    say "static pods"
    static_pods | cut -c1-150 | tee "$LOG_DIR/.upgrade-static" || true
    n=$(grep -c -E " (kube-apiserver|kube-controller-manager|kube-scheduler) image [a-z-]+:v$ver " "$LOG_DIR/.upgrade-static" || true)
    [ "$n" = $((3 * ${#CPS[@]})) ] && echo "ok   each API server, controller manager and scheduler runs the image of v$ver" || { echo "FAIL $n static pods of v$ver, rule $((3 * ${#CPS[@]}))"; fail=1; }
    say "the pods of the provider"
    for r in "${REPLICAS[@]}"; do k -n "$NS" get pod "$(pn "$r")" -o json | jq -r '"\(.metadata.name) image \(.spec.containers[0].image | sub(".*:"; "")) node \(.spec.nodeName) restarts \(.status.containerStatuses[0].restartCount)"'; done | tee "$LOG_DIR/.upgrade-pods"
    n=$(for r in "${CPS[@]}"; do grep "^$(pn "$r") image ${img##*:} " "$LOG_DIR/.upgrade-pods"; done | grep -c . || true)
    [ "$n" = "${#CPS[@]}" ] && echo "ok   each control plane pod runs the image ${img##*:}" || { echo "FAIL $n control plane pods run the image ${img##*:}"; fail=1; }
    say "the add-on step and the kubeadm ConfigMap step of NVKE"
    for wid in "update-kubeadm-configmap-$(cluster_id)-$ver" "kubeadm-upgrade-$(cluster_id)-$ver"; do
      echo "$wid: $(temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *(Status|RunTime)' | tr -s ' ' | tr '\n' ' ')"
      workflow_timeline "$wid" || true
      grep -v -E 'UpdateNodeConditions|GetNodePoolForNode|GetClusterForNode' "$LOG_DIR/workflow-$wid.txt" 2>/dev/null | sed -E 's/^[0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z/\1/; s/\(scheduled [0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z\)/(scheduled \1)/' | cut -c1-150 || true
    done
    temporal workflow describe --workflow-id "kubeadm-upgrade-$(cluster_id)-$ver" 2>&1 | grep -E '^ *Status' | grep -q -i COMPLETED && echo "ok   the add-on workflow of NVKE is completed" || { echo "FAIL the add-on workflow is not completed"; fail=1; }
    echo "kubeadm-config ConfigMap: $(ik a -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep -E '^kubernetesVersion' | tr '\n' ' ')"
    echo "add-ons: $(ik a -n kube-system get daemonsets,deployments -o json | jq -r '[.items[] | "\(.kind)/\(.metadata.name)=\(.spec.template.spec.containers[0].image | sub(".*/"; ""))"] | join(" ")')"
    say "the order: each new pod and each deleted pod (from the provider log)"
    provider_log_since "$since" | grep -E 'Gave an address|Made the pod|Node agent answers, reported|released its address' | cut -c1-160 || true
    echo "error lines of the provider: $(provider_log_since "$since" | grep -c ' ERROR ' || true). Lines with the finalizer fault: $(k -n "$PROVIDER_NS" logs deployment/podvm-controller-manager --since-time="$since" 2>/dev/null | grep -c 'failed to remove the finalizer' || true)"
    say "times when two pods of the cluster were on one host node (from the time line)"
    awk '{t=$1; s=$0; sub(/.*\| pods /, "", s); sub(/ \| claims.*/, "", s); n=split(s, a, " "); delete h; dbl=""; for (j=1; j<=n; j++) { split(a[j], b, /[@=]/); h[b[2]]++ } for (x in h) if (h[x] > 1) dbl=dbl " " x "=" h[x]; if (dbl != "") print t, dbl }' "$LOG_DIR/upgrade-$label-timeline.txt" | awk '{k=$2 " " $3 " " $4; if (k != last) {if (last != "") print first " to " prev ": " last; first=$1; last=k} prev=$1} END {if (last != "") print first " to " prev ": " last}' || true
    say "workflows since the PATCH"
    workflows_since "$since" "$LOG_DIR/upgrade-$label-record"
    say "the storage loop during the upgrade"
    awk -v s="$(date -u -d "$since" +%T)" '$1 >= s' "$STORAGE_LOOP_LOG" 2>/dev/null | tail -14 || true
    say "scheduling events of the pods"
    k -n "$NS" get events --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,OBJ:.involvedObject.name,REASON:.reason,MESSAGE:.message 2>/dev/null | grep -E 'FailedScheduling' | tail -8 | cut -c1-230 || echo "no FailedScheduling event"
    grep -q 'failed: 0$' "$LOG_DIR/probe-upgrade-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    [ "$fail" = 0 ] && echo "RESULT upgrade $label: PASS" || echo "RESULT upgrade $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT upgrade $label: PASS" "$out"
}

# The worker pool: PATCH the version and the machine template, with a recycle budget, and record what NVKE does.
cmd_pool_upgrade() {
  local label=${1:?label} ver=${2:?version} img=${3:?image} since w m i
  write_podmap
  w=${WKS[0]}; m=$(pn "$w")
  {
    say "worker pool ($label): PATCH kubernetesVersion $ver and the machine template (image ${img##*:}), recycleBudget 1, maxSurge 1, at $(date -u +%FT%TZ)"
    api get "/api/nodePools/$(pool_id)" | api_body | jq -c '{name, kubernetesVersion, desiredNodeCount, currentNodeSetID, recycleBudget, maxSurge, autoModeDisabled, image: (.infra.machineTemplate.spec.template.spec.image | sub(".*:"; ""))}'
    echo "node sets of the pool: $(api get "/api/nodeSets?nodePoolID=$(pool_id)" | api_body | jq -c '[(.nodeSets // .)[]? | {id: .id[0:8], kubernetesVersion, deprecated: (.conditions.deprecated.status // null)}]' 2>/dev/null | cut -c1-400)"
    jq -n --arg v "$ver" --argjson t "$(machine_template "$img")" '{kubernetesVersion: $v, recycleBudget: 1, maxSurge: 1, infra: {machineTemplate: $t}}' >"$LOG_DIR/pool-upgrade-$label-body.json"
    since=$(date -u +%FT%TZ)
    api patch "/api/nodePools/$(pool_id)" "$LOG_DIR/pool-upgrade-$label-body.json" >"$LOG_DIR/pool-upgrade-$label-response.txt" 2>&1 || true
    tail -1 "$LOG_DIR/pool-upgrade-$label-response.txt"
    grep -q '^HTTP 20[0-9]$' "$LOG_DIR/pool-upgrade-$label-response.txt" || { cut -c1-900 "$LOG_DIR/pool-upgrade-$label-response.txt"; echo "RESULT pool-upgrade $label: NVKE did not accept the PATCH"; exit 2; }
    # Three minutes: what NVKE does with the worker by itself.
    for i in 1 2 3 4 5 6; do
      sleep 30
      sample 1
      echo "$(date -u +%T) $(state_line | cut -c1-260) | conditions of the worker Node: $(ik a get node "$m" -o json 2>/dev/null | jq -r '[.status.conditions[] | select(.type | test("Recycle|recycle|nvke|nke")) | "\(.type)=\(.status)"] | join(" ")')"
    done
    api get "/api/nodePools/$(pool_id)" | api_body | jq -c '{name, kubernetesVersion, desiredNodeCount, currentNodeSetID, recycleBudget, maxSurge, image: (.infra.machineTemplate.spec.template.spec.image | sub(".*:"; ""))}'
    echo "node sets of the pool: $(api get "/api/nodeSets?nodePoolID=$(pool_id)" | api_body | jq -c '[(.nodeSets // .)[]? | {id: .id[0:8], kubernetesVersion, deprecated: (.conditions.deprecated.status // null)}]' 2>/dev/null | cut -c1-400)"
    echo "the worker in NVKE: $(api get "/api/nodes/$(node_id "$m")" | api_body | jq -c '{name, nodeSetID: (.nodeSetID // null), conditions: [.conditions | to_entries[] | select(.value.status=="True") | .key]}' | cut -c1-400)"
    echo "workflows since the PATCH: $(temporal workflow list --query "StartTime > \"$since\"" --limit 20 2>&1 | awk 'NR>1 {print $3 "=" $1}' | tr '\n' ' ')"
    node_versions
  } 2>&1 | tee "$LOG_DIR/pool-upgrade-$label.txt"
}

# --- G3: the upgrade waits for a volume place ----------------------------------------------------
# The surge Machine of the upgrade has the failure domain of a host node whose two Machine places
# are taken (one control plane node and the worker). This step records that state, then frees the
# place through the NVKE API with a worker in the cluster at each moment: pool count 2 (a second
# worker on another host node), pool count 1, DELETE of the worker on the full host node.
cmd_g3_unblock() {
  local label=${1:-unblock} out surge wold woldid created waitto fail=0 i since
  out="$LOG_DIR/g3-$label.txt"
  write_podmap
  {
    say "G3 ($label): the upgrade waits, at $(date -u +%FT%TZ)"
    surge=$(k -n "$NS" get pods -o json | jq -r '[.items[] | select(.status.phase=="Pending") | .metadata.name] | join(" ")')
    echo "pending pods of the provider: [$surge]"
    [ -n "$surge" ] && [ "$(wc -w <<<"$surge")" = 1 ] || { echo "RESULT g3-unblock $label: not exactly one pending pod. Nothing done"; exit 2; }
    cluster_line
    echo "state: $(state_line)"
    k -n "$CAPI_NS" get machines.cluster.x-k8s.io -o custom-columns=NAME:.metadata.name,DOMAIN:.spec.failureDomain,PHASE:.status.phase,CREATED:.metadata.creationTimestamp
    k -n "$NS" get pods -o wide | cut -c1-120
    k -n "$NS" get pvc -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,VOLUME:.spec.volumeName | grep -F "$surge" || true
    k -n "$NS" get events --field-selector "involvedObject.name=$surge" --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,COUNT:.count,REASON:.reason,MESSAGE:.message | tail -4 | cut -c1-330
    "$P/storage.sh" status | tail -14
    echo "the surge in NVKE: $(api get "/api/nodes/$(node_id "$surge")" | api_body | jq -c '{name, conditions: [.conditions | to_entries[] | select(.value.status=="True") | "\(.key)[\(.value.message // "")]"]}' | cut -c1-500)"
    created=$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$surge" -o jsonpath='{.metadata.creationTimestamp}')
    echo "the surge Machine $surge was made at $created, failure domain $(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$surge" -o jsonpath='{.spec.failureDomain}')"
    # The worker on the host node of that failure domain.
    wold=$(k -n "$NS" get pods -o json | jq -r --arg d "$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$surge" -o jsonpath='{.spec.failureDomain}')" '[.items[] | select(.spec.nodeName==$d) | select(.metadata.labels | has("cluster.x-k8s.io/control-plane") | not) | .metadata.name] | join(" ")')
    woldid=$(node_id "$wold")
    echo "the worker on that host node: $wold (NVKE node $woldid)"
    [ -n "$woldid" ] || { echo "RESULT g3-unblock $label: no worker on that host node. Nothing done"; exit 2; }
    say "1. pool count 2: a second worker, on a host node with a free place"
    since=$(date -u +%FT%TZ)
    printf '{"desiredNodeCount": 2}\n' >"$LOG_DIR/g3-$label-count2.json"
    api patch "/api/nodePools/$(pool_id)" "$LOG_DIR/g3-$label-count2.json" 2>&1 | tail -1
    for i in $(seq 1 60); do
      sample 1
      [ "$(worker_nodes)" = 2 ] && [ "$(jqs "$JQ_DEFS"'[($n[0].nodes // [])[] | select(.controlPlane != true) | select(good)] | length')" = 2 ] && break
      sleep 10
    done
    echo "$(date -u +%T) workers in NVKE: $(worker_nodes), state: $(state_line | cut -c1-600)"
    [ "$(jqs "$JQ_DEFS"'[($n[0].nodes // [])[] | select(.controlPlane != true) | select(good)] | length')" = 2 ] || { echo "FAIL the second worker is not good. Nothing more done"; echo "RESULT g3-unblock $label: FAIL"; exit 1; }
    say "2. wait until the surge has been pending for 16 minutes (NVKE has a 15 minute rule for a stuck pending node)"
    waitto=$(( $(date -u -d "$created" +%s) + 960 ))
    while [ "$(date +%s)" -lt "$waitto" ]; do sleep 20; done
    echo "$(date -u +%T) the surge pod: $(k -n "$NS" get pod "$surge" -o jsonpath='{.status.phase}'), Machine phase $(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$surge" -o jsonpath='{.status.phase}')"
    echo "the surge in NVKE: $(api get "/api/nodes/$(node_id "$surge")" | api_body | jq -c '{name, conditions: [.conditions | to_entries[] | select(.value.status=="True") | "\(.key)[\(.value.message // "")]"]}' | cut -c1-500)"
    cluster_line
    echo "controller log lines about a stuck or re-placed node since the surge was made: $(k -n nvke-controller logs deployment/nvke-controller --since-time="$created" 2>/dev/null | grep -c -i -E 'stuck pending|re-placing|unplaceable|out of capacity' || true)"
    echo "Machines of the control plane now: $(k -n "$CAPI_NS" get machines.cluster.x-k8s.io -l cluster.x-k8s.io/control-plane -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.failureDomain}{"/"}{.status.phase}{" "}{end}')"
    say "3. pool count 1 (NVKE removes no node for that), then DELETE of the worker $wold on the full host node"
    printf '{"desiredNodeCount": 1}\n' >"$LOG_DIR/g3-$label-count1.json"
    api patch "/api/nodePools/$(pool_id)" "$LOG_DIR/g3-$label-count1.json" 2>&1 | tail -1
    sleep 10
    stamp "g3-$label-delete"
    say "DELETE /api/nodes/$woldid at $(date -u +%T)"
    api delete "/api/nodes/$woldid" 2>&1 | tail -1
    for i in $(seq 1 90); do
      [ "$(k -n "$NS" get pod "$surge" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && { stamp "g3-$label-surge-running"; break; }
      sleep 5
    done
    echo "$(date -u +%T) the surge pod: $(k -n "$NS" get pod "$surge" -o jsonpath='{.status.phase}{" on "}{.spec.nodeName}'), $(between "g3-$label-delete" "g3-$label-surge-running") s after the DELETE of the worker"
    k -n "$NS" get events --field-selector "involvedObject.name=$surge" --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,COUNT:.count,REASON:.reason,MESSAGE:.message | grep -E 'Scheduled|FailedScheduling|Started' | tail -4 | cut -c1-260 || true
    sample 1
    echo "state: $(state_line)"
    echo "workers in NVKE: $(worker_nodes)"
    [ "$(k -n "$NS" get pod "$surge" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && echo "RESULT g3-unblock $label: the surge pod runs" || echo "RESULT g3-unblock $label: FAIL the surge pod does not run"
  } 2>&1 | tee "$out"
}

step=${1:-}
shift || true
case "$step" in
  init | facts | health | g1 | rotate | g2 | upgrade | pool-upgrade | g3-unblock | pool-post | pool-wait | pool-delete | worker-delete | pool-scale | cp-state | w1 | w2 | placement | wait-good | probe-start | probe-stop | flow | delete | base | post)
    mkdir -p "$LOG_DIR"
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  state) sample 1; state_line ;;
  line) cluster_line ;;
  podmap) write_podmap; paste -d' ' "$PODMAP" <(cut -d' ' -f2 "$LOG_DIR/roles.txt") ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
