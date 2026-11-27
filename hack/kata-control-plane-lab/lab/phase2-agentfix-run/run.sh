#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The tests of steps 6 and 7 again, with the fixed NVKE agent in the node image (forms p4 and p5),
# and with NOTHING written by hand into a guest. Each change of the cluster goes through the NVKE API.
# It loads the steps of p2-replace/run.sh (flow, scale, delete-node, rollout, after, placement) and adds:
#   lost-pod <who>          delete one pod by hand, the provider makes it again (the step of step 5)
#   wait-good <n>           wait until NVKE reports n good nodes (one look each 10 s)
#   fix-evidence <label>    on each node: the agent binary, the log line of the fix, the config file
# Usage: LOG_DIR=<run folder> run.sh <step>
set -euo pipefail
. /root/kata-cp/bin/env.sh
A="$(cd "$(dirname "$0")" && pwd)"
export NS=${NS:-d}
export LOG_DIR=${LOG_DIR:-$W/logs/p2s6b/run-1}
export IMG_P2=${IMG_CLUSTER:-docker.io/library/nvke-node-podvm:bcc4376f-p4}   # the image of the cluster
export IMG_P3=${IMG_ROLLOUT:-docker.io/library/nvke-node-podvm:bcc4376f-p5}   # the image of the rollout
export NODE_IMAGE_REF=$IMG_P2                                                 # for the pod check of the provider step
export DISK_LOG=$W/logs/p2s6b/disk.txt
export STORAGE_LOOP_LOG=$W/logs/p2s6b/storage-loop.out

# shellcheck disable=SC1090
source <(sed '/^step=\${1:-}$/,$d' "$W/p2-replace/run.sh")
R=$W/p2-replace       # its request templates
P=$W/p2-provider
HERE=$D
AGENT_SHA256=e465d46ad7a578b1634ca129dc2b0303c76bc6146fc346e937e18371affe8770

# At the start of a cluster the pod map has each Machine with an address. NVKE can be some seconds
# late with its conditions, and the map of p2-replace takes only the good nodes of NVKE.
write_podmap_all() {
  local i=0 m ip hn
  sample 0
  : >"$PODMAP.new"
  while read -r m ip hn; do
    echo "${LETTERS[$i]} $m $ip $hn" >>"$PODMAP.new"
    i=$((i + 1))
  done < <(jqs '$i[0].items | map(select(.status.address)) | sort_by(.status.address | split(".") | map(tonumber)) | .[] | .metadata.name as $x | "\($x) \(.status.address) \(([$p[0].items[] | select(.metadata.name==$x)][0].spec.nodeName) // "none")"')
  mv "$PODMAP.new" "$PODMAP"
  load_podmap
}

# The flow of p2-provider/run.sh. One change: the pod map before the checks has all three Machines.
cmd_flow() {
  local rc=0
  cmd_base
  cmd_probe_start run 1500 || true
  cmd_post
  cmd_wait_pods || rc=1
  if [ "$rc" = 0 ]; then cmd_wait || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_wait_nodes || rc=1; fi
  if [ "$rc" = 0 ]; then write_podmap_all; cat "$PODMAP"; cmd_check final || rc=1; fi
  cmd_probe_stop run || true
  times || true
  cmd_record final || true
  provider_record final || true
  cmd_evidence final || true
  if [ "$rc" = 0 ]; then cmd_endpoint final || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_reach final || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_etcd final || rc=1; fi
  if [ "$rc" = 0 ]; then cmd_names || rc=1; fi
  cmd_provider final || rc=1
  cmd_times || true
  if [ "$rc" = 0 ]; then echo "RESULT flow: PASS"; else echo "RESULT flow: FAIL"; fi
  return "$rc"
}

cmd_wait_good() {
  local n=${1:?count} end
  end=$(( $(date +%s) + ${2:-600} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    sample 1
    if [ "$(all_nodes)" = "$n" ] && [ "$(good_nodes)" = "$n" ] && [ "$(ready_pods)" = "$n" ]; then echo "$(date -u +%T) NVKE reports $n good nodes"; return 0; fi
    sleep 10
  done
  echo "$(date -u +%T) NVKE does not report $n good nodes: $(state_line)"
  return 1
}

# The evidence of the fix on each node of now. No certificate key is read: the lines of the agent
# that are copied are the line of the fix and the line with the kubeadm arguments.
cmd_fix_evidence() {
  local label=${1:-now} out m
  out="$LOG_DIR/fix-evidence-$label.txt"
  mkdir -p "$LOG_DIR/upload-certs-config"
  {
    say "evidence of the agent fix ($label) at $(date -u +%FT%TZ)"
    for m in $(k -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
      echo "--- $m ($(k -n "$CAPI_NS" get podvmmachine "$m" -o jsonpath='{.status.address}'), image $(k -n "$NS" get pod "$m" -o jsonpath='{.spec.containers[0].image}' | sed 's/.*://'))"
      k -n "$NS" exec "$m" -- sh -c 'echo "agent binary: sha256 $(sha256sum /usr/local/bin/nvke-agent | cut -d" " -f1), $(/usr/local/bin/nvke-agent --version 2>&1 | head -1), marker of the image [$(cat /usr/share/podvm/image-form 2>/dev/null)]"
        echo "files by hand: /tmp/kubeadm-init-config.yaml $([ -e /tmp/kubeadm-init-config.yaml ] && echo PRESENT || echo absent). /tmp has: $(ls /tmp | tr "\n" " ")"
        echo "lines of the fix in the agent journal: $(journalctl --no-pager -u nvke-agent | grep -c "wrote the kubeadm config for upload-certs")"
        journalctl --no-pager -u nvke-agent | grep "wrote the kubeadm config for upload-certs" | sed -E "s/.*\"time\":\"([^\"]*)\".*\"path\":\"([^\"]*)\".*\"localAPIEndpoint\":\"([^\"]*)\".*/  \\1 wrote \\2 localAPIEndpoint=\\3/" | tail -6
        journalctl --no-pager -u nvke-agent | grep -o "attempting to run command: name=kubeadm, args=\[init phase upload-certs[^]]*\]" | sort | uniq -c | sed "s/^/  /"
        journalctl --no-pager -u nvke-agent | grep -c "kubeadm update join commands completed successfully" | sed "s/^/  join strings given: /"
        if [ -s /var/lib/nvke/kubeadm-upload-certs-config.yaml ]; then echo "  config file: $(stat -c "%s bytes, mode %a, changed %y" /var/lib/nvke/kubeadm-upload-certs-config.yaml | cut -c1-60)"; grep -n -E "^kind:|advertiseAddress|bindPort|controlPlaneEndpoint|kubernetesVersion|podSubnet|serviceSubnet|certificatesDir" /var/lib/nvke/kubeadm-upload-certs-config.yaml | sed "s/^/    /"; else echo "  config file: absent (this node was not asked)"; fi' 2>&1 | cut -c1-400
      k -n "$NS" exec "$m" -- sh -c 'cat /var/lib/nvke/kubeadm-upload-certs-config.yaml 2>/dev/null' >"$LOG_DIR/upload-certs-config/$m.yaml" 2>/dev/null || true
      [ -s "$LOG_DIR/upload-certs-config/$m.yaml" ] || unlink "$LOG_DIR/upload-certs-config/$m.yaml"
    done
  } 2>&1 | tee "$out"
}

step=${1:-}
shift || true
case "$step" in
  base | post | wait-pods | wait | wait-nodes | check | endpoint | reach | probe-start | probe-stop | names | etcd | provider | times | flow | delete | placement | after | refuse-delete | scale | delete-node | rollout | lost-pod | wait-good | fix-evidence)
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  record | evidence)
    { "cmd_$step" "$@"; provider_record "$@"; } 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  traffic | tunnels)
    node_names
    # shellcheck disable=SC1091
    . "$D/measure.sh"
    "cmd_$step" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  poll) poll_line ;;
  state) sample 1; state_line ;;
  podmap) write_podmap; cat "$PODMAP" ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
