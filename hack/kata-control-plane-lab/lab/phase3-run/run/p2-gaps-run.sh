#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 2 gaps: the tests of the guard for the shared address (gap 1) and of the capacity signal
# (gap 2). The pass rules 1 to 7 are in notes/hosted/phase2-gaps-design.md, section 4.
#
# Each change of the cluster goes through the NVKE API. Two flows have no API request: the forced
# certificate renewal and the key rotation. For these two the script starts the workflow with the
# command of the product page (start only), with the functions of p2-gate/run.sh, exactly as the
# last test did. Nothing is written into a guest. No workflow is ended, signaled, reset or changed.
# No database write.
#
# It loads the steps of p2-gate/run.sh (and the scripts under it) and adds:
#   gate-facts <label>           each node: image, probe of the pod, agent flags, probe program, gate file, kernel
#   probe-start <label> [s], probe-stop <label>   one call to the shared address each second, one line for each call
#   ready-start <label> [s], ready-stop <label>   the watch of the Ready condition of each Node, one line for each change.
#                                With it run ep-watch.sh (pods and ready endpoints of the shared Service) and
#                                agent-gate-watch.sh (the gate lines of the agents). gate-report <label> prints the gate table
#   t1 <label>                   pass rule 1: the forced certificate renewal
#   enc <label>                  etcd encryption on through the NVKE API (the key rotation needs it), with both watches
#   t2 <label>                   pass rule 2: the key rotation
#   cp-rollout <label> [image]   pass rule 3: rollout of the three control plane nodes to another image
#                                through the NVKE API, with the watch for the pass rules 5 to 7
#   free-place <label>           pass rule 7: free the volume place of the pending surge node through the NVKE API
#   gap2-check <label> <free|wait>   the pass rules 5, 6 and 7 against the watch file of a rollout
#   t4 <label>                   pass rule 4: the forced renewal on a cluster whose probe does not read the gate
#   kernel-check <pod> <kind node>   the throwaway ss -K check in a guest (ss-kill-check.sh)
# Usage: LOG_DIR=<run folder> run.sh <step>
set -euo pipefail
. /root/kata-cp/bin/env.sh
GAPS="$(cd "$(dirname "$0")" && pwd)"
export NS=${NS:-d}
export LOG_DIR=${LOG_DIR:-$W/logs/p2gaps/c-1}
export IMG_CLUSTER=${IMG_CLUSTER:-docker.io/library/nvke-node-podvm:bcc4376f-p6}   # the image of the cluster
export IMG_ROLLOUT=${IMG_ROLLOUT:-docker.io/library/nvke-node-podvm:bcc4376f-p7}   # the image of the first rollout
export IMG_WORKER=${IMG_WORKER:-$IMG_CLUSTER}
export CLUSTER_RUN=${CLUSTER_RUN:-$LOG_DIR}

# shellcheck disable=SC1090
source <(sed '/^step=\${1:-}$/,$d' "$W/p2-gate/run.sh")
export DISK_LOG=$W/logs/p2gaps/disk.txt
export STORAGE_LOOP_LOG=$W/logs/p2gaps/storage-loop.out
ROLLOUT_LIMIT=${ROLLOUT_LIMIT:-5400}      # a rollout that waits two times for the 15 minute rule of NVKE
PROBE_PROGRAM=${PROBE_PROGRAM:-/usr/local/bin/podvm-endpoint-ready}
# The one settings file of the image build has the gate file.
# shellcheck disable=SC1091
. "$GAPS/image/endpoint-gate.env"

# The provider check of step 4 (p2-provider/run.sh, cmd_provider) has the readiness probe of the old
# provider in its pod rules: an HTTPS call of the kubelet. The new provider runs the probe program.
# Replace only that rule. The rest of the function stays as it is.
eval "$(declare -f cmd_provider | sed 's|(\$c.readinessProbe.httpGet.path == "/readyz"), (\$c.readinessProbe.httpGet.port == 6443), (\$c.readinessProbe.httpGet.scheme == "HTTPS"), (\$c.readinessProbe.periodSeconds == 2),|((\$c.readinessProbe.exec.command // []) \| index("'"$PROBE_PROGRAM"'") != null),|')"
declare -f cmd_provider | grep -q 'readinessProbe.exec.command' || echo "WARN the probe rule of the provider check was not replaced" >&2

# --- the call to the shared address each second -------------------------------------------------
# A transient systemd unit in the kind node of the machine, as in the earlier tests. The line form
# is new: one line for each call with the time (UTC) and the HTTP code, or "no answer" when no
# answer came in 2 s. The steps of the earlier scripts (g1, rotate, g2) call these three functions.
probe_file() { echo "/var/tmp/p2gaps-probe-$1.log"; }
cmd_probe_start() {
  local label=${1:-run} secs=${2:-1200} target=${3:-$ENDPOINT} f
  f=$(probe_file "$label")
  node systemd-run --quiet --collect --expand-environment=no --unit="p2gaps-probe-$label-$$" \
    bash -c "end=\$((\$(date +%s) + $secs)); : > $f; while [ \$(date +%s) -lt \$end ]; do t=\$(date -u +%FT%T.%3NZ); c=\$(curl -sk --max-time 2 -o /dev/null -w '%{http_code}' https://$target/readyz); [ \"\$c\" = 000 ] && c='no answer'; echo \"\$t \$c\" >> $f; sleep 1; done"
  echo "p2gaps-probe-$label-$$" >"$LOG_DIR/.probe-unit-$label"
  echo "$target" >"$LOG_DIR/.probe-target-$label"
  say "probe $label started in the kind node of the machine (unit $(cat "$LOG_DIR/.probe-unit-$label"), target $target, limit $secs s)"
}
# probe_summary <file>: one line for each time range with the same answer, then the totals.
probe_summary() {
  awk 'function show() { printf "%s  %s to %s  %4d calls\n", (st=="200" ? "answer 200" : "FAILED " st), substr(t0, 12, 8), substr(t1, 12, 8), c }
       { code=$2; for (i=3; i<=NF; i++) code=code " " $i
         n++; by[code]++
         if (code=="200") g++; else b++
         if (NR>1 && code!=st) { show(); c=0 }
         if (c==0) t0=$1
         st=code; t1=$1; c++ }
       END { if (n) show(); s=""; for (x in by) s=s sprintf(" [%s] %d", x, by[x]); printf "by answer:%s\n", s; printf "calls %d, answer 200: %d, failed: %d\n", n, g, b }' "$1"
}
cmd_probe_stop() {
  local label=${1:-run} f
  f=$(probe_file "$label")
  node systemctl stop "$(cat "$LOG_DIR/.probe-unit-$label").service" 2>/dev/null || true
  node cat "$f" >"$LOG_DIR/probe-$label.txt"
  say "probe $label: one call each second to https://$(cat "$LOG_DIR/.probe-target-$label")/readyz from the kind node. One line for each call is in probe-$label.txt"
  probe_summary "$LOG_DIR/probe-$label.txt" | tee "$LOG_DIR/probe-$label-summary.txt"
  echo "each call with another answer than 200 (at most 60 lines):"
  awk '$2!="200"' "$LOG_DIR/probe-$label.txt" | head -60
}

# --- the watch of the Ready condition of each Node ---------------------------------------------
# The kubeconfig of the new cluster, in the secrets folder of the machine (mode 700). Never printed.
kubeconfig_file() {
  local f="$SEC/kubeconfig-$CLUSTER_NAME" r
  for r in "${CPS[@]}"; do
    if ( umask 077; pod "$r" cat /etc/kubernetes/admin.conf >"$f.new" 2>/dev/null ) && grep -q '^kind: Config' "$f.new"; then mv "$f.new" "$f"; break; fi
  done
  [ -s "$f" ] || return 1
  echo "$f"
}
cmd_ready_start() {
  local label=${1:?label} secs=${2:-10800} f kc
  f="$LOG_DIR/ready-$label.txt"
  # The watch of the pods and of the EndpointSlice of the shared Service, and the collector of the
  # gate lines of the agents. Both run on the machine and read the host cluster.
  : >"$LOG_DIR/ep-$label.txt"
  : >"$LOG_DIR/agent-gate-$label.txt"
  NS="$NS" setsid nohup "$GAPS/ep-watch.sh" "$LOG_DIR/ep-$label.txt" "$secs" </dev/null >>"$LOG_DIR/ep-$label.err" 2>&1 &
  NS="$NS" setsid nohup "$GAPS/agent-gate-watch.sh" "$LOG_DIR/agent-gate-$label.txt" "$secs" </dev/null >>"$LOG_DIR/agent-gate-$label.err" 2>&1 &
  kc=$(kubeconfig_file) || { echo "WARN no kubeconfig of the new cluster. The Ready watch $label does not run"; return 1; }
  : >"$f"
  setsid nohup "$GAPS/ready-watch.sh" "$kc" "$f" "$secs" </dev/null >>"$LOG_DIR/ready-$label.err" 2>&1 &
  echo $! >"$LOG_DIR/.ready-pid-$label"
  say "watch of the Ready condition of each Node started on the machine (ready-$label.txt, one look each second through the shared address)"
}
# ready_ranges <watch file>: one line for each time range in which a Node that was Ready was not
# Ready: <node> <role> <states> <from> <to> [open|gone]. A new Node that is not Ready yet is no range.
ready_ranges() {
  awk '$2=="node" && $5 ~ /^Ready=/ { n=$3; st=substr($5, 7); was=substr($6, 5)
         if (st!="True" && was=="True") { from[n]=$1; r[n]=$4; s[n]=st }
         else if (st!="True" && (n in from)) { s[n]=s[n] "," st }
         else if (st=="True" && (n in from)) { print n, r[n], s[n], from[n], $1; delete from[n] } }
       $2=="node" && $5=="gone" { n=$3; if (n in from) { print n, r[n], s[n], from[n], $1, "gone"; delete from[n] } }
       $2=="watch" && $3=="stop" { for (n in from) print n, r[n], s[n], from[n], $1, "open" }' "$1"
}
cmd_ready_stop() {
  local label=${1:?label} f i
  f="$LOG_DIR/ready-$label.txt"
  touch "$f.stop" "$LOG_DIR/agent-gate-$label.txt.stop"
  sleep 4
  if [ -s "$LOG_DIR/ep-$label.txt.pgid" ]; then kill -TERM -- "-$(cat "$LOG_DIR/ep-$label.txt.pgid")" 2>/dev/null || true; fi
  for i in 1 2 3 4 5 6 7 8 9 10; do if grep -q ' watch stop$' "$f"; then break; fi; sleep 1; done
  say "Ready watch $label: each change (UTC)"
  cat "$f"
  say "time ranges in which a Node that was Ready was not Ready"
  ready_ranges "$f" | tee "$LOG_DIR/ready-$label-ranges.txt"
  [ -s "$LOG_DIR/ready-$label-ranges.txt" ] || echo "none"
  echo "time in which the list of the Nodes did not come: $(grep -c ' api no answer$' "$f" || true) start(s)"
  cmd_gate_report "$label"
}
# The health gate of one test: the table of gate-report.py, then each gate line of the agents.
cmd_gate_report() {
  local label=${1:?label}
  say "the health gate, node by node ($label). Times are UTC. Seconds count from the closed gate"
  python3 "$GAPS/gate-report.py" "$LOG_DIR/agent-gate-$label.txt" "$LOG_DIR/ep-$label.txt" | tee "$LOG_DIR/gate-report-$label.txt" || true
  say "gate lines of the agents ($label): time, node, message"
  jq -R -r 'split(" ") as $f | (($f[1:] | join(" ")) | fromjson?) as $o | select($o != null) | "\($o.time[11:23]) \($f[0]) \($o.msg)\(if $o.peerIP then " " + $o.peerIP + ":" + ($o.peerPort | tostring) else "" end)\(if $o.backendAddress then " backend " + $o.backendAddress else "" end)\(if $o.error then " error=" + ($o.error | tostring) else "" end)"' "$LOG_DIR/agent-gate-$label.txt" 2>/dev/null | sort | cut -c1-330 | tee "$LOG_DIR/gate-lines-$label.txt" | head -150 || true
  say "pods and ready endpoints of the shared Service ($label): each change"
  grep -v ' watch start$' "$LOG_DIR/ep-$label.txt" | cut -c1-260 | head -120 || true
}

# --- pass rules 1 and 2 -------------------------------------------------------------------------
# The time range of the renewal of each control plane node, from the end date of its API server
# certificate: kubeadm makes a certificate for 365 days, so the renewal on a node started 365 days
# before the new end date. The range of a node ends when the renewal of the next node starts, or
# at the end of the watch of the workflow.
renewal_windows() { # <label>: lines "<node> <start epoch> <end epoch>"
  local label=$1 wend
  wend=$(awk -v l="g1-$label-end" '$2==l {print int($1)}' "$LOG_DIR/times.txt" | tail -1)
  awk '$2=="apiserver" {print $1, $3 - 31536000}' "$LOG_DIR/.g1-epochs-after" | sort -k2,2n |
    awk -v wend="${wend:-0}" '{n[NR]=$1; s[NR]=$2} END {for (i=1; i<=NR; i++) print n[i], s[i], (i<NR ? s[i+1] : wend)}' >"$LOG_DIR/renewal-windows-$label.txt"
  while read -r n s e; do echo "renewal of $n: $(date -u -d "@$s" +%T) to $(date -u -d "@$e" +%T)"; done <"$LOG_DIR/renewal-windows-$label.txt"
}
# rule_gap1 <rule number> <label> <probe label> <renewal|other>
# Rule: no Node goes NotReady, apart from the node under the operation. Each call gets 200.
rule_gap1() {
  local rule=$1 label=$2 pl=$3 kind=${4:-other} fail=0 review=0 bad calls name role st from to rest e0 e1 s e
  say "pass rule $rule ($label)"
  calls=$(grep -c . "$LOG_DIR/probe-$pl.txt" || true)
  bad=$(awk '$2!="200"' "$LOG_DIR/probe-$pl.txt" | grep -c . || true)
  if [ "$calls" -gt 0 ] && [ "$bad" = 0 ]; then echo "ok   each of the $calls calls to the shared address got 200"; else echo "FAIL $bad of $calls calls to the shared address did not get 200"; fail=1; fi
  [ -s "$LOG_DIR/ready-$label.txt" ] || { echo "FAIL no Ready watch file"; fail=1; }
  if [ "$kind" = renewal ]; then renewal_windows "$label"; fi
  while read -r name role st from to rest; do
    [ -n "$name" ] || continue
    if [ "$role" = worker ]; then echo "FAIL the worker Node $name was not Ready ($st) from $from to $to $rest"; fail=1; continue; fi
    if [ "$kind" != renewal ]; then
      echo "REVIEW the control plane Node $name was not Ready ($st) from $from to $to $rest. Only the node under the operation may be not Ready: compare with the phase table of the workflow"; review=1; continue
    fi
    e0=$(date -u -d "$from" +%s); e1=$(date -u -d "$to" +%s)
    read -r s e < <(awk -v n="$name" '$1==n {print $2, $3}' "$LOG_DIR/renewal-windows-$label.txt") || true
    # 90 s before the start: the guard closes the gate before the renewal. 60 s after the end: the kubelet reports late.
    if [ -n "${s:-}" ] && [ -z "$rest" ] && [ "$e0" -ge $((s - 90)) ] && [ "$e1" -le $((e + 60)) ]; then
      echo "ok   the control plane Node $name was not Ready ($st) from $from to $to, inside its own renewal"
    else
      echo "FAIL the control plane Node $name was not Ready ($st) from $from to $to $rest, outside its own renewal"; fail=1
    fi
  done <"$LOG_DIR/ready-$label-ranges.txt"
  [ -s "$LOG_DIR/ready-$label-ranges.txt" ] || echo "ok   no Node that was Ready lost Ready"
  if [ "$fail" = 1 ]; then echo "RESULT pass rule $rule ($label): FAIL"; elif [ "$review" = 1 ]; then echo "RESULT pass rule $rule ($label): REVIEW (a control plane Node was not Ready)"; else echo "RESULT pass rule $rule ($label): PASS"; fi
  [ "$fail" = 0 ]
}

# The lines of the agent about the gate, since a time.
gate_lines() { agent_lines "$1" 'gate|endpoint|quiet|socket|withdraw|kube-vip' "${2:-40}"; }
# The gate file on each control plane node: it must not exist outside an operation.
gate_files() {
  local r
  for r in "${CPS[@]}"; do echo "$(pn "$r"): gate file $(pod "$r" sh -c "if [ -e $GATE_FILE ]; then echo PRESENT; else echo absent; fi" 2>&1), pod ready $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)"; done
}

# What must be true before a test of gap 1: the image, the probe of the pod, the three flags of the
# agent, the probe program, the gate file, the guest kernel. Reads only.
cmd_gate_facts() {
  local label=${1:-now} out fail=0 r m probe
  out="$LOG_DIR/gate-facts-$label.txt"
  write_podmap
  {
    say "gate facts ($label) at $(date -u +%FT%TZ)"
    echo "provider: $(k -n "$PROVIDER_NS" get deployment podvm-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'), NVKE controller: $(k -n nvke-controller get deployment nvke-controller -o jsonpath='{.spec.template.spec.containers[0].image}')"
    "$GAPS/kernel/kernel-switch.sh" status
    for r in "${REPLICAS[@]}"; do
      m=$(pn "$r")
      echo "--- $m"
      probe=$(k -n "$NS" get pod "$m" -o json | jq -c '.spec.containers[0].readinessProbe')
      echo "pod: image $(k -n "$NS" get pod "$m" -o jsonpath='{.spec.containers[0].image}' | sed 's/.*://'), host node $(k -n "$NS" get pod "$m" -o jsonpath='{.spec.nodeName}'), readiness probe $probe"
      pod "$r" sh -c 'echo "guest: marker [$(cat /usr/share/podvm/image-form 2>/dev/null)], kernel built $(uname -v), tcp_diag_destroy in the kernel: $(grep -c -w tcp_diag_destroy /proc/kallsyms), /boot config: $(grep -c -E "^CONFIG_(INET_DIAG|INET_TCP_DIAG|INET_DIAG_DESTROY)=y" /boot/config-$(uname -r)) of 3"
        echo "agent: $(/usr/local/bin/nvke-agent --version 2>&1 | head -1), sha256 $(sha256sum /usr/local/bin/nvke-agent | cut -c1-16), started $(systemctl show nvke-agent -p ExecMainStartTimestamp --value)"
        echo "agent process: $(ps -o args= -C nvke-agent | cut -c1-400)"
        f='"$PROBE_PROGRAM"'; if [ -e $f ]; then echo "probe program: mode $(stat -c %a $f), reads a gate file: $(grep -c -F "[ -e " $f)"; else echo "probe program: none"; fi
        echo "gate folder: $(ls -ld '"$(dirname "$GATE_FILE")"' | cut -c1-10) on $(findmnt -n -T '"$(dirname "$GATE_FILE")"' -o SOURCE,FSTYPE | tr -s " "), gate file: $(if [ -e '"$GATE_FILE"' ]; then echo PRESENT; else echo absent; fi)"' 2>&1 | tee "$LOG_DIR/.gate-facts-$r"
      if printf '%s\n' "${CPS[@]}" | grep -q -x "$r"; then
        jq -e --arg p "$PROBE_PROGRAM" '(.exec.command // []) | index($p) != null' <<<"$probe" >/dev/null && echo "ok   the readiness probe of the pod runs $PROBE_PROGRAM" || { echo "FAIL the readiness probe of the pod does not run $PROBE_PROGRAM"; fail=1; }
        for f in $AGENT_GATE_FLAGS; do grep -q -F -- "$f" "$LOG_DIR/.gate-facts-$r" || { echo "FAIL the agent process has no $f"; fail=1; }; done
        grep -q 'gate file: absent' "$LOG_DIR/.gate-facts-$r" || { echo "FAIL the gate file exists"; fail=1; }
      fi
      grep -q 'tcp_diag_destroy in the kernel: [1-9]' "$LOG_DIR/.gate-facts-$r" || { echo "FAIL the guest kernel has no socket destroy (INET_DIAG_DESTROY)"; fail=1; }
    done
    [ "$fail" = 0 ] && echo "RESULT gate-facts $label: PASS" || echo "RESULT gate-facts $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT gate-facts $label: PASS" "$out"
}

# --- pass rule 1: the forced certificate renewal -------------------------------------------------
cmd_t1() {
  local label=${1:-t1} rc=0 jsince
  write_podmap
  jsince=$(date -u '+%F %T')
  cmd_ready_start "$label" || true
  # p2-gate/run.sh: the documented operator start, as in the last test. The subshell keeps "set -e"
  # in force inside the step, as it was when the step ran by itself.
  set +e
  ( set -e; cmd_g1 "$label" )
  rc=$?
  set -e
  cmd_ready_stop "$label"
  say "the gate, from the agent of each control plane node"
  gate_lines "$jsince" 60
  gate_files
  rule_gap1 1 "$label" "g1-$label" renewal 2>&1 | tee "$LOG_DIR/rule1-$label.txt" || true
  grep -q "RESULT pass rule 1 ($label): PASS" "$LOG_DIR/rule1-$label.txt" || rc=1
  echo "RESULT t1 $label: workflow step $(grep -o "RESULT g1 $label: [A-Z]*" "$LOG_DIR/g1-$label.txt" | tail -1 | sed 's/.*: //'), $(grep '^RESULT pass rule' "$LOG_DIR/rule1-$label.txt")"
  return "$rc"
}

# --- etcd encryption on, then pass rule 2: the key rotation -------------------------------------
cmd_enc() {
  local label=${1:-enc} rc=0 jsince
  write_podmap
  jsince=$(date -u '+%F %T')
  cmd_ready_start "$label" || true
  # p2-gate/run.sh: PATCH enableEtcdEncryption through the NVKE API.
  set +e
  ( set -e; cmd_g2 "$label" )
  rc=$?
  set -e
  cmd_ready_stop "$label"
  say "the gate, from the agent of each control plane node"
  gate_lines "$jsince" 60
  gate_files
  rule_gap1 "2 (encryption on)" "$label" "g2-$label" other 2>&1 | tee "$LOG_DIR/rule2enc-$label.txt" || true
  return "$rc"
}
cmd_t2() {
  local label=${1:-t2} rc=0 jsince
  write_podmap
  jsince=$(date -u '+%F %T')
  cmd_ready_start "$label" || true
  # p2-gate/run.sh: the documented operator start, as in the last test.
  set +e
  ( set -e; cmd_rotate "$label" )
  rc=$?
  set -e
  cmd_ready_stop "$label"
  say "the gate, from the agent of each control plane node"
  gate_lines "$jsince" 60
  gate_files
  rule_gap1 2 "$label" "rot-$label" other 2>&1 | tee "$LOG_DIR/rule2-$label.txt" || true
  grep -q "RESULT pass rule 2 ($label): PASS" "$LOG_DIR/rule2-$label.txt" || rc=1
  echo "RESULT t2 $label: workflow step $(grep -o "RESULT rotate $label: [A-Z]*" "$LOG_DIR/rotate-$label.txt" | tail -1 | sed 's/.*: //'), $(grep '^RESULT pass rule' "$LOG_DIR/rule2-$label.txt")"
  return "$rc"
}

# --- pass rules 3 and 5 to 7: the rollout, with the watch of the capacity signal ----------------
# The free volume places of each host node, and the pods of the cluster on it.
full_domains() {
  jqs '[$v[0].items[] | {h: .metadata.labels["podvm.lab/host-node"], u: .metadata.labels["podvm.lab/use"], ph: .status.phase}] | group_by(.h)
    | map((.[0].h) as $h | "\($h | sub("kata-bb-"; "")): free Machine places \([([.[] | select(.u=="var" and .ph=="Available")] | length), ([.[] | select(.u=="etcd" and .ph=="Available")] | length)] | min), pods of the cluster [\([$p[0].items[] | select(.spec.nodeName==$h) | .metadata.name[-11:]] | join(" "))]")
    | join("; ")'
}
# One look at the JSON files of "sample": a line for each change of
#   pvmm       the Ready condition of each PodVMMachine: status, reason, message
#   nvke-node  each node of the NVKE API: the conditions that are True, and the pending message
#   machine    each Machine of Cluster API: failure domain and phase
#   pod        each pod of the cluster: phase, host node, the message of the scheduler
#   cluster    the failure domains that NVKE marked, and the upgrade and recycling conditions
#   controller lines of the controller log about a pending node or a failure domain
gap2_lines() { # <label>
  local label=$1 f d t
  f="$LOG_DIR/gap2-$label-watch.txt"
  d="$LOG_DIR/.gap2-$label"
  mkdir -p "$d"
  [ -e "$d/last.txt" ] || : >"$d/last.txt"
  [ -e "$d/ctl-seen.txt" ] || : >"$d/ctl-seen.txt"
  t=$(date -u +%FT%TZ)
  cluster_json >"$d/cl.new" 2>/dev/null && jq -e . "$d/cl.new" >/dev/null 2>&1 && mv "$d/cl.new" "$d/cl.json"
  [ -s "$d/cl.json" ] || echo '{}' >"$d/cl.json"
  {
    jqs '$m[0].items as $ms | $i[0].items[] | .metadata.name as $x | ((.status.conditions // []) | map(select(.type=="Ready")) | .[0] // {}) as $c
      | "pvmm \($x) domain=\(([$ms[] | select(.metadata.name==$x)][0].spec.failureDomain) // "-") Ready=\($c.status // "none") reason=\($c.reason // "-") message=\(($c.message // "") | gsub("\n"; " ") | .[0:260])"'
    jqs '($n[0].nodes // [])[] | "nvke-node \(.name) \(if .controlPlane then "control-plane" else "worker" end) true=[\([.conditions | to_entries[] | select(.value.status=="True") | .key] | join(","))] pending-message=\((.conditions.pending.message // "") | gsub("\n"; " ") | .[0:300])"'
    jqs '$m[0].items[] | "machine \(.metadata.name) domain=\(.spec.failureDomain // "-") phase=\(.status.phase // "-") role=\(if ((.metadata.labels // {}) | has("cluster.x-k8s.io/control-plane")) then "cp" else "worker" end)\(if .metadata.deletionTimestamp then " deleting" else "" end) \((((.status.conditions // []) + (.status.v1beta2.conditions // [])) | map(select(.type=="InfrastructureReady")) | .[0] // {}) | "InfrastructureReady=\(.status // "none") reason=\(.reason // "-") message=\((.message // "") | gsub("\n"; " ") | .[0:220])")"'
    jqs '$p[0].items[] | ((.status.conditions // []) | map(select(.type=="PodScheduled")) | .[0] // {}) as $c
      | "pod \(.metadata.name) phase=\(.status.phase // "-") host=\(.spec.nodeName // "-") ready=\(.status.containerStatuses[0].ready // false) scheduled=\($c.status // "-") \($c.reason // "") \(($c.message // "") | gsub("\n"; " ") | .[0:220])\(if .metadata.deletionTimestamp then " terminating" else "" end)"'
    jq -r '"cluster unplaceable=\((.conditions.unplaceableFailureDomains // .unplaceableFailureDomains // null) | tojson) upgrading=\(.conditions.controlPlaneUpgrading.status // "-") recycling=\(.conditions.cpNodesRecycling.status // "-") [\((.conditions.cpNodesRecycling.message // "") | .[0:160])]"' "$d/cl.json" 2>/dev/null || true
  } >"$d/now.txt" 2>/dev/null || true
  # New and changed lines. An object that is gone gets one line.
  grep -v -x -F -f "$d/last.txt" "$d/now.txt" | sed "s/^/$t /" >>"$f" || true
  awk 'FNR==NR {k[$1 " " $2]=1; next} !(($1 " " $2) in k) && $1!="cluster" {print $1, $2, "gone"}' "$d/now.txt" "$d/last.txt" | sed "s/^/$t /" >>"$f" || true
  cp "$d/now.txt" "$d/last.txt"
  # The controller log of the last 45 s: lines about a pending node or a failure domain, each line one time.
  k -n nvke-controller logs deployment/nvke-controller --since=45s 2>/dev/null | grep -i -E 'stuck pending|re-plac|unplaceable|FailureDomainUnavailable|failure domain|out of capacity|Recorded delete' | mask | cut -c1-520 >"$d/ctl-now.txt" || true
  grep -v -x -F -f "$d/ctl-seen.txt" "$d/ctl-now.txt" >"$d/ctl-new.txt" || true
  if [ -s "$d/ctl-new.txt" ]; then sed "s/^/$t controller /" "$d/ctl-new.txt" >>"$f"; cat "$d/ctl-new.txt" >>"$d/ctl-seen.txt"; fi
}

cmd_cp_rollout() {
  local label=${1:?label} img=${2:-$IMG_ROLLOUT} out fail=0 since before line end ok=0 total ntotal i=0 n r
  out="$LOG_DIR/cp-rollout-$label.txt"
  write_podmap
  total=${#REPLICAS[@]}
  # Phase 3: a worker of another provider (a NicoMachine) is a node and a Machine, and it is no pod
  # of this provider. The count of NVKE nodes and of Machines at the start is the count at the end.
  sample 1
  ntotal=$(all_nodes)
  [ "$ntotal" -ge "$total" ] || ntotal=$total
  {
    say "rollout ($label) of the control plane to the image ${img##*:} through the NVKE API, at $(date -u +%FT%TZ)"
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") cp-rollout $label"
    pgrep -f "storage-loop[.]sh" >/dev/null && echo "the storage loop runs" || echo "WARN the storage loop does not run: a Released volume is not made again"
    cluster_line
    before=$(for r in "${CPS[@]}"; do pn "$r"; done | tr '\n' ' ')
    echo "control plane Machines before: $before"
    placement_table
    echo "host nodes: $(full_domains)"
    cmd_cp_state "$label-before" >/dev/null
    jq -n --argjson t "$(machine_template "$img")" '{controlPlaneConfig: {infra: {machineTemplate: $t}}}' >"$LOG_DIR/cp-rollout-$label-body.json"
    cmd_ready_start "rollout-$label" || true
    cmd_probe_start "rollout-$label" $((ROLLOUT_LIMIT + 600))
    sleep 5
    since=$(date -u +%FT%TZ)
    echo "$since" >"$LOG_DIR/cp-rollout-$label-since.txt"
    sample 1
    gap2_lines "$label"
    stamp "rollout-$label-patch"
    say "PATCH /api/clusters/$(cluster_id) with the machine template (image ${img##*:}), at $(date -u +%T)"
    api patch "/api/clusters/$(cluster_id)" "$LOG_DIR/cp-rollout-$label-body.json" >"$LOG_DIR/cp-rollout-$label-response.txt" 2>&1 || true
    tail -1 "$LOG_DIR/cp-rollout-$label-response.txt"
    if ! grep -q '^HTTP 20[0-9]$' "$LOG_DIR/cp-rollout-$label-response.txt"; then
      cut -c1-900 "$LOG_DIR/cp-rollout-$label-response.txt"
      cmd_probe_stop "rollout-$label" >/dev/null
      cmd_ready_stop "rollout-$label" >/dev/null
      echo "RESULT cp-rollout $label: NVKE did not accept the PATCH"
      exit 2
    fi
    # One look each 10 s. The end: no old control plane Machine is left, each node of NVKE is good,
    # each pod is ready, and each control plane pod runs the new image.
    end=$(( $(date +%s) + ROLLOUT_LIMIT ))
    while [ "$(date +%s)" -lt "$end" ]; do
      sample 1
      gap2_lines "$label"
      line="$(state_line) | $(rollout_line)"
      echo "$(date -u +%T) $line" >>"$LOG_DIR/cp-rollout-$label-timeline.txt"
      if [ $((i % 6)) = 0 ]; then echo "$(date -u +%T) $line" | cut -c1-420; fi
      if [ "$(jqs --arg b "$before" '[$i[0].items[].metadata.name | select(. as $x | ($b | split(" ")) | index($x))] | length')" = 0 ] && [ "$(all_nodes)" = "$ntotal" ] && [ "$(good_nodes)" = "$ntotal" ] && [ "$(ready_pods)" = "$total" ] && [ "$(jqs '$m[0].items | length')" = "$ntotal" ] \
        && [ "$(jqs --arg img "$img" '[$p[0].items[] | select(.metadata.labels["cluster.x-k8s.io/control-plane"] != null) | select(.spec.containers[0].image==$img)] | length')" = "${#CPS[@]}" ] \
        && [ "$(jqs '[($n[0].nodes // [])[] | select(.controlPlane==true) | select(.controlPlaneRollout.pending==true)] | length')" = 0 ]; then ok=$((ok + 1)); else ok=0; fi
      [ "$ok" -ge 2 ] && break
      i=$((i + 1))
      sleep 10
    done
    if [ "$ok" -ge 2 ]; then stamp "rollout-$label-done"; echo "three new control plane nodes with the image ${img##*:}, $ntotal good nodes ($total pods of the provider), $(between "rollout-$label-patch" "rollout-$label-done") s after the PATCH"; else echo "FAIL the rollout is not over after $ROLLOUT_LIMIT s"; fail=1; fi
    sleep 20
    cmd_probe_stop "rollout-$label"
    cmd_ready_stop "rollout-$label"
    write_podmap
    say "what NVKE says at the end"
    cluster_line
    cluster_json | jq -c '.conditions.controlPlaneUpgrading, .conditions.cpNodesRecycling' | cut -c1-300
    echo "after: $(state_line)"
    echo "control plane Machines now: $(for r in "${CPS[@]}"; do pn "$r"; done | tr '\n' ' ')"
    placement_table
    echo "host nodes: $(full_domains)"
    say "the order: each new pod and each deleted pod (from the provider log)"
    provider_log_since "$since" | grep -E 'Gave an address|Made the pod|Node agent answers, reported|released its address|nschedulable|FailureDomain' | cut -c1-200 || true
    echo "error lines of the provider: $(provider_log_since "$since" | grep -c ' ERROR ' || true)"
    say "the gate at each teardown, from the agent of the nodes of now"
    gate_lines "$(date -u -d "$since" '+%F %T')" 30
    gate_files
    say "the watch for the pass rules 5 to 7 (gap2-$label-watch.txt): lines of a pending node"
    grep -E ' (pvmm|nvke-node) .*(FailureDomainUnavailable|Unschedulable|pending-message=.)| controller | cluster unplaceable=[^n]' "$LOG_DIR/gap2-$label-watch.txt" | grep -v 'pending-message=$' | cut -c1-420 | head -60 || echo "no pending node in this rollout"
    say "workflows since the PATCH"
    workflows_since "$since" "$LOG_DIR/cp-rollout-$label-record" | cut -c1-200
    say "the storage loop during the rollout"
    awk -v s="$(date -u -d "$since" +%T)" '$1 >= s' "$STORAGE_LOOP_LOG" 2>/dev/null | tail -14 || true
    say "scheduling events of the pods"
    k -n "$NS" get events --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,OBJ:.involvedObject.name,REASON:.reason,MESSAGE:.message 2>/dev/null | grep -E 'FailedScheduling' | tail -8 | cut -c1-230 || echo "no FailedScheduling event"
    say "pass rule 3 ($label)"
    n=$(awk '$2!="200"' "$LOG_DIR/probe-rollout-$label.txt" | grep -c . || true)
    if [ "$n" = 0 ] && [ -s "$LOG_DIR/probe-rollout-$label.txt" ]; then echo "ok   each of the $(grep -c . "$LOG_DIR/probe-rollout-$label.txt") calls to the shared address got 200"; echo "RESULT pass rule 3 ($label): PASS"; else echo "FAIL $n of $(grep -c . "$LOG_DIR/probe-rollout-$label.txt") calls to the shared address did not get 200"; echo "RESULT pass rule 3 ($label): FAIL"; fail=1; fi
    [ "$fail" = 0 ] && echo "RESULT cp-rollout $label: PASS" || echo "RESULT cp-rollout $label: FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT cp-rollout $label: PASS" "$out"
}

# --- pass rule 7: a volume place gets free before the 15 minutes of NVKE ------------------------
# The surge Machine of a rollout has the failure domain of a host node whose two Machine places
# are taken (one control plane node and the worker). Free the place through the NVKE API, with a
# worker in the cluster at each moment: pool count 2 (a second worker on another host node), pool
# count 1, DELETE of the worker on the full host node. Then the pod must start and the reason
# FailureDomainUnavailable must go away. This step runs beside the rollout loop, so give it its
# own run folder (the driver p2gaps-t3.sh does that).
cmd_free_place() {
  local label=${1:-free} out surge wold woldid created age domain i fail=0
  out="$LOG_DIR/free-place-$label.txt"
  write_podmap
  {
    say "free a volume place ($label), at $(date -u +%FT%TZ)"
    surge=$(k -n "$NS" get pods -o json | jq -r '[.items[] | select(.status.phase=="Pending") | select(.metadata.labels["cluster.x-k8s.io/control-plane"] != null) | .metadata.name] | join(" ")')
    echo "pending control plane pods of the provider: [$surge]"
    [ -n "$surge" ] && [ "$(wc -w <<<"$surge")" = 1 ] || { echo "RESULT free-place $label: not exactly one pending control plane pod. Nothing done"; exit 2; }
    created=$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$surge" -o jsonpath='{.metadata.creationTimestamp}')
    domain=$(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$surge" -o jsonpath='{.spec.failureDomain}')
    age=$(( $(date +%s) - $(date -u -d "$created" +%s) ))
    echo "the surge Machine $surge was made at $created ($age s ago), failure domain $domain"
    echo "PodVMMachine: $(k -n "$CAPI_NS" get podvmmachine "$surge" -o json | jq -c '[.status.conditions[]? | {type, status, reason, message: ((.message // "") | .[0:260])}]')"
    echo "Machine: $(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$surge" -o json | jq -c '[((.status.conditions // []) + (.status.v1beta2.conditions // []))[] | select(.type=="InfrastructureReady") | {type, status, reason, message: ((.message // "") | .[0:260])}]')"
    echo "the surge in NVKE: $(api get "/api/nodes/$(node_id "$surge")" | api_body | jq -c '{name, conditions: [.conditions | to_entries[] | select(.value.status=="True") | "\(.key)[\(.value.message // "")]"]}' | cut -c1-600)"
    echo "host nodes: $(full_domains)"
    # The rule of NVKE acts 15 minutes after the node went pending. Start only with time to spare.
    [ "$age" -lt "${FREE_LATEST:-600}" ] || { echo "RESULT free-place $label: the surge is pending for $age s. That is too near to the 15 minutes of NVKE. Nothing done"; exit 2; }
    wold=$(k -n "$NS" get pods -o json | jq -r --arg d "$domain" '[.items[] | select(.spec.nodeName==$d) | select(.metadata.labels["cluster.x-k8s.io/control-plane"] == null) | .metadata.name] | join(" ")')
    woldid=$(node_id "$wold")
    echo "the worker on that host node: $wold (NVKE node $woldid)"
    [ -n "$woldid" ] && [ "$(wc -w <<<"$wold")" = 1 ] || { echo "RESULT free-place $label: not exactly one worker on that host node. Nothing done"; exit 2; }
    say "1. pool count 2: a second worker, on a host node with a free place"
    printf '{"desiredNodeCount": 2}\n' >"$LOG_DIR/free-$label-count2.json"
    api patch "/api/nodePools/$(pool_id)" "$LOG_DIR/free-$label-count2.json" 2>&1 | tail -1
    for i in $(seq 1 60); do
      sample 1
      [ "$(worker_nodes)" = 2 ] && [ "$(jqs "$JQ_DEFS"'[($n[0].nodes // [])[] | select(.controlPlane != true) | select(good)] | length')" = 2 ] && break
      sleep 10
    done
    echo "$(date -u +%T) workers in NVKE: $(worker_nodes), state: $(state_line | cut -c1-600)"
    [ "$(jqs "$JQ_DEFS"'[($n[0].nodes // [])[] | select(.controlPlane != true) | select(good)] | length')" = 2 ] || { echo "FAIL the second worker is not good. Nothing more done"; echo "RESULT free-place $label: FAIL"; exit 1; }
    say "2. pool count 1 (NVKE removes no node for that), then DELETE of the worker $wold on the full host node"
    printf '{"desiredNodeCount": 1}\n' >"$LOG_DIR/free-$label-count1.json"
    api patch "/api/nodePools/$(pool_id)" "$LOG_DIR/free-$label-count1.json" 2>&1 | tail -1
    sleep 10
    stamp "free-$label-delete"
    say "DELETE /api/nodes/$woldid at $(date -u +%T)"
    api delete "/api/nodes/$woldid" 2>&1 | tail -1
    for i in $(seq 1 120); do
      [ -n "$(k -n "$NS" get pod "$surge" -o jsonpath='{.spec.nodeName}' 2>/dev/null)" ] && { stamp "free-$label-scheduled"; break; }
      sleep 5
    done
    age=$(( $(date +%s) - $(date -u -d "$created" +%s) ))
    echo "$(date -u +%T) the surge pod: $(k -n "$NS" get pod "$surge" -o jsonpath='{.status.phase}{" on "}{.spec.nodeName}' 2>/dev/null), $(between "free-$label-delete" "free-$label-scheduled") s after the DELETE of the worker, $age s after the Machine was made"
    for i in $(seq 1 60); do
      [ "$(k -n "$CAPI_NS" get podvmmachine "$surge" -o json 2>/dev/null | jq -r '[.status.conditions[]? | select(.type=="Ready") | .reason] | join("")')" != FailureDomainUnavailable ] && break
      sleep 5
    done
    echo "PodVMMachine now: $(k -n "$CAPI_NS" get podvmmachine "$surge" -o json | jq -c '[.status.conditions[]? | {type, status, reason, message: ((.message // "") | .[0:200])}]')"
    echo "Machine now: $(k -n "$CAPI_NS" get machine.cluster.x-k8s.io "$surge" -o json | jq -c '[((.status.conditions // []) + (.status.v1beta2.conditions // []))[] | select(.type=="InfrastructureReady") | {type, status, reason, message: ((.message // "") | .[0:200])}]')"
    k -n "$NS" get events --field-selector "involvedObject.name=$surge" --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,COUNT:.count,REASON:.reason,MESSAGE:.message | grep -E 'Scheduled|FailedScheduling|Started' | tail -4 | cut -c1-260 || true
    sample 1
    echo "the surge in NVKE: $(api get "/api/nodes/$(node_id "$surge")" | api_body | jq -c '{name, conditions: [.conditions | to_entries[] | select(.value.status=="True") | "\(.key)[\(.value.message // "")]"]}' | cut -c1-500)"
    echo "workers in NVKE: $(worker_nodes)"
    [ -n "$(k -n "$NS" get pod "$surge" -o jsonpath='{.spec.nodeName}' 2>/dev/null)" ] && [ "$age" -lt 900 ] || fail=1
    [ "$(k -n "$CAPI_NS" get podvmmachine "$surge" -o json 2>/dev/null | jq -r '[.status.conditions[]? | select(.type=="Ready") | .reason] | join("")')" != FailureDomainUnavailable ] || fail=1
    [ "$fail" = 0 ] && echo "RESULT free-place $label: the surge pod has a host node before the 15 minutes, and the reason FailureDomainUnavailable is gone" || echo "RESULT free-place $label: FAIL"
  } 2>&1 | tee "$out"
}

# The pass rules 5, 6 and 7 against the watch file of a rollout.
#   free: an operator step freed the place before the 15 minutes (rules 5 and 7)
#   wait: no operator step. NVKE must place the node in another domain by itself (rules 5 and 6)
cmd_gap2_check() {
  local label=${1:?label} mode=${2:?free or wait} f out fail5=0 fail6=0 fail7=0 surges s t0 t1 dom freed="" n6=0 n7=0
  f="$LOG_DIR/gap2-$label-watch.txt"
  out="$LOG_DIR/gap2-check-$label.txt"
  {
    say "pass rules 5 to 7 ($label, $mode) from $(basename "$f")"
    surges=$(awk '$2=="pvmm" && /reason=FailureDomainUnavailable/ {print $3}' "$f" | sort -u | tr '\n' ' ')
    # The surge whose place the operator step freed (rule 7). Each other surge is a case of rule 6.
    freed=$(sed -n 's/^the surge Machine \([^ ]*\) was made.*/\1/p' "$LOG_DIR/free-$label/free-place-$label.txt" 2>/dev/null | head -1 || true)
    echo "Machine whose volume place the operator step freed: [${freed:-none}]"
    echo "Machines that the provider reported with the reason FailureDomainUnavailable: [$surges]"
    [ -n "$surges" ] || { echo "FAIL no Machine got the reason FailureDomainUnavailable. No failure domain was full in this rollout"; fail5=1; fail6=1; fail7=1; }
    for s in $surges; do
      echo "--- $s"
      grep -E " (pvmm|nvke-node|machine|pod) $s " "$f" | cut -c1-460
      dom=$(awk -v s="$s" '$2=="pvmm" && $3==s {sub(/^domain=/, "", $4); print $4; exit}' "$f")
      t0=$(awk -v s="$s" '$2=="pvmm" && $3==s && /reason=FailureDomainUnavailable/ {print $1; exit}' "$f")
      # Rule 5: NVKE shows the message of the provider on the node.
      if grep -E " nvke-node $s " "$f" | grep -q -E 'pending-message=.*(nodes are available|persistent volumes|FailureDomainUnavailable|nschedulable)'; then echo "ok   rule 5: the node list of NVKE has the message of the provider on $s"; else echo "FAIL rule 5: the node list of NVKE has no message of the provider on $s"; fail5=1; fi
      if [ "$s" != "$freed" ]; then
        n6=$((n6 + 1))
        # Rule 6: NVKE removes the node and places a new node in another domain, with no operator step.
        t1=$(awk -v s="$s" '($2=="pvmm" || $2=="machine") && $3==s && $4=="gone" {print $1; exit}' "$f")
        if [ -n "$t1" ]; then echo "ok   rule 6: NVKE removed $s (domain $dom) $(( $(date -u -d "$t1" +%s) - $(date -u -d "$t0" +%s) )) s after the provider reported the reason"; else echo "FAIL rule 6: $s was not removed"; fail6=1; fi
        grep -E ' controller ' "$f" | grep -i -E 'stuck pending|re-plac|Recorded delete' | cut -c1-420 | head -6 || true
        grep -q -i -E ' controller .*(stuck pending|re-plac|Recorded delete)' "$f" || { echo "FAIL rule 6: no line of the controller about a node that it places again"; fail6=1; }
        # At the end no control plane Machine is in the domain that was full: the node is in another domain.
        awk '$2=="machine" {if ($4=="gone") delete last[$3]; else last[$3]=$0} END {for (x in last) print last[x]}' "$f" | awk '$6=="role=cp" {sub(/^domain=/, "", $4); print $3 "@" $4}' | sort >"$LOG_DIR/.gap2-$label-final.txt"
        echo "control plane Machines at the end: $(tr '\n' ' ' <"$LOG_DIR/.gap2-$label-final.txt")"
        if [ -s "$LOG_DIR/.gap2-$label-final.txt" ] && ! grep -q "@$dom\$" "$LOG_DIR/.gap2-$label-final.txt"; then echo "ok   rule 6: no control plane Machine is in the domain $dom at the end. The node is in another domain"; else echo "FAIL rule 6: a control plane Machine is in the domain $dom at the end, or there is no Machine"; fail6=1; fi
        echo "host nodes with more than one control plane Machine at the end (the effect that the design note names): [$(sed 's/.*@//' "$LOG_DIR/.gap2-$label-final.txt" | sort | uniq -c | awk '$1>1 {print $2 "=" $1}' | tr '\n' ' ')]"
      else
        n7=$((n7 + 1))
        # Rule 7: the pod starts and the reason goes away, before the 15 minutes.
        t1=$(awk -v s="$s" -v t="$t0" '$2=="pvmm" && $3==s && $1>t && !/reason=FailureDomainUnavailable/ && $4!="gone" {print $1; exit}' "$f")
        if [ -n "$t1" ] && [ $(( $(date -u -d "$t1" +%s) - $(date -u -d "$t0" +%s) )) -lt 900 ]; then echo "ok   rule 7: the reason of $s went away $(( $(date -u -d "$t1" +%s) - $(date -u -d "$t0" +%s) )) s after the provider reported it: $(awk -v s="$s" -v t="$t1" '$2=="pvmm" && $3==s && $1==t {print $5, $6}' "$f")"; else echo "FAIL rule 7: the reason of $s did not go away before the 15 minutes"; fail7=1; fi
        grep -E " pod $s " "$f" | grep -q -E 'phase=Running' && echo "ok   rule 7: the pod of $s runs" || { echo "FAIL rule 7: the pod of $s does not run"; fail7=1; }
        grep -E " (pvmm|machine) $s gone" "$f" >/dev/null && { echo "FAIL rule 7: $s was removed"; fail7=1; }
      fi
    done
    grep -q "RESULT cp-rollout $label: PASS" "$LOG_DIR/cp-rollout-$label.txt" 2>/dev/null && echo "ok   the rollout ended" || { echo "FAIL the rollout did not end"; fail6=1; fail7=1; }
    [ "$fail5" = 0 ] && echo "RESULT pass rule 5 ($label): PASS" || echo "RESULT pass rule 5 ($label): FAIL"
    if [ "$n6" -gt 0 ] || [ "$mode" = wait ]; then [ "$fail6" = 0 ] && [ "$n6" -gt 0 ] && echo "RESULT pass rule 6 ($label): PASS ($n6 Machine)" || echo "RESULT pass rule 6 ($label): FAIL"; fi
    if [ "$n7" -gt 0 ] || [ "$mode" = free ]; then [ "$fail7" = 0 ] && [ "$n7" -gt 0 ] && echo "RESULT pass rule 7 ($label): PASS" || echo "RESULT pass rule 7 ($label): FAIL"; fi
  } 2>&1 | tee "$out"
}

# --- pass rule 4: the gate fails safe -------------------------------------------------------------
# The cluster of this test has control plane pods whose probe program does not read the gate file
# (the image p8-nogate). The agent closes its gate, the pod stays ready, the Service sends new
# connections to the node, and the quiet window check of the agent must fail. Then the renewal must
# not start: no certificate changes and no static pod restarts. The start of the workflow is the
# documented operator start, as in t1. The script reads what NVKE does with the failed cycle.
cmd_t4() {
  local label=${1:-t4} out fail=0 pre=0 since jsince wid r n kc
  out="$LOG_DIR/t4-$label.txt"
  write_podmap
  wid="operator-k8s-cert-renewal-$(date -u +%Y%m%dT%H%M%SZ)-$(cat /proc/sys/kernel/random/uuid)"
  {
    say "pass rule 4 ($label): forced certificate renewal on a cluster whose probe does not read the gate, at $(date -u +%FT%TZ)"
    for r in "${CPS[@]}"; do
      n=$(pod "$r" sh -c "grep -c -F '[ -e ' $PROBE_PROGRAM; true" 2>/dev/null | head -1)
      echo "$(pn "$r"): image $(k -n "$NS" get pod "$(pn "$r")" -o jsonpath='{.spec.containers[0].image}' | sed 's/.*://'), lines of the probe program that read a gate file: ${n:-?} (rule: 0), readiness probe $(k -n "$NS" get pod "$(pn "$r")" -o json | jq -c '.spec.containers[0].readinessProbe')"
      [ "${n:-1}" = 0 ] || pre=1
    done
    [ "$pre" = 0 ] || { echo "RESULT t4 $label: a probe program reads the gate file. This is not the cluster for this test. Not started"; exit 2; }
    WAIT=1 "$W/p2-replace/disk.sh" "$(basename "$LOG_DIR") t4 $label"
    cluster_line
    cert_epochs >"$LOG_DIR/.t4-epochs-before"
    static_pods >"$LOG_DIR/.t4-static-before" || true
    provider_pods >"$LOG_DIR/.t4-pods-before"
    gate_files
    cmd_ready_start "t4-$label" || true
    cmd_probe_start "t4-$label" $((GATE_LIMIT + 600))
    # Clients with a long-lived connection through the shared address, on the machine: a watch each.
    if kc=$(kubeconfig_file); then
      setsid nohup "$GAPS/watch-clients.sh" start "$kc" "$LOG_DIR/clients-$label" "${T4_CLIENTS:-12}" </dev/null >>"$LOG_DIR/clients-$label.err" 2>&1 &
    else
      echo "WARN no kubeconfig. The clients with a long-lived connection do not run"
    fi
    sleep 20
    echo "clients with a long-lived connection (a watch each): $(grep -c ' connects$' "$LOG_DIR/clients-$label/clients.txt" 2>/dev/null || true) started, $(grep -c 'connection ended' "$LOG_DIR/clients-$label/clients.txt" 2>/dev/null || true) ended so far"
    for r in "${CPS[@]}"; do echo "$(pn "$r"): established sockets of remote clients on eth0 port 6443: $(pod "$r" sh -c 'a=$(ip -o -4 addr show dev eth0 scope global | awk "{print \$4}" | cut -d/ -f1); ss -Htan state established src "$a" sport = :6443 | wc -l' 2>&1)"; done
    since=$(date -u +%FT%TZ)
    jsince=$(date -u '+%F %T')
    echo "$wid" >"$LOG_DIR/t4-$label-workflow-id.txt"
    say "the start, as controller/docs/certificate-renewal.md:183-188 says"
    echo "temporal workflow start --address $TEMPORAL_ADDR --namespace $TEMPORAL_NS --task-queue cloud-workflow-engine-tasks --type RenewK8sCertsV2 --workflow-id $wid --input '{\"clusterID\":\"$(cluster_id)\",\"thresholdDays\":30,\"force\":true}'" | tee "$LOG_DIR/t4-$label-command.txt"
    stamp "t4-$label-start"
    temporal workflow start --task-queue cloud-workflow-engine-tasks --type RenewK8sCertsV2 --workflow-id "$wid" --input "{\"clusterID\":\"$(cluster_id)\",\"thresholdDays\":30,\"force\":true}" 2>&1 | tee "$LOG_DIR/t4-$label-start.txt" | cut -c1-200
    if ! grep -q -i 'RunId' "$LOG_DIR/t4-$label-start.txt"; then
      cmd_probe_stop "t4-$label" >/dev/null
      cmd_ready_stop "t4-$label" >/dev/null
      echo "RESULT t4 $label: the workflow did not start"
      exit 2
    fi
    watch_workflow "$wid" "$LOG_DIR/t4-$label-timeline.txt" || echo "note the workflow is not closed. I leave it as it is"
    stamp "t4-$label-end"
    sleep 45
    cmd_probe_stop "t4-$label"
    cmd_ready_stop "t4-$label"
    "$GAPS/watch-clients.sh" stop "$LOG_DIR/clients-$label" || true
    say "the clients with a long-lived connection: each connection that ended since the start of the workflow"
    awk -v s="$since" '$1 >= s && /connection ended/' "$LOG_DIR/clients-$label/clients.txt" 2>/dev/null | cut -c1-220 | head -60 || true
    say "the workflow $wid"
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *(Status|Type|StartTime|CloseTime|RunTime|HistoryLength)' || echo "no workflow with this ID"
    workflow_timeline "$wid" || true
    grep -v -E 'UpdateNodeConditions|GetNodePoolForNode|GetClusterForNode' "$LOG_DIR/workflow-$wid.txt" 2>/dev/null | sed -E 's/^[0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z/\1/; s/\(scheduled [0-9-]+T([0-9:]+\.[0-9]{3})[0-9]*Z\)/(scheduled \1)/' | cut -c1-150 || true
    say "what NVKE says at the end"
    cluster_line
    cluster_json | jq -c '.conditions.certificateRenewal, .conditions.updateInProgress' | cut -c1-900
    say "the gate, from the agent of each control plane node since the start (time and message only)"
    gate_lines "$jsince" 60 | tee "$LOG_DIR/t4-$label-agent.txt"
    gate_files | tee "$LOG_DIR/.t4-gates-after"
    say "checks"
    cert_epochs >"$LOG_DIR/.t4-epochs-after"
    if [ -s "$LOG_DIR/.t4-epochs-before" ] && diff "$LOG_DIR/.t4-epochs-before" "$LOG_DIR/.t4-epochs-after"; then echo "ok   no certificate has another end date: the renewal did not start on any node"; else echo "FAIL a certificate has another end date: the renewal started"; fail=1; fi
    static_pods >"$LOG_DIR/.t4-static-after" || true
    if diff "$LOG_DIR/.t4-static-before" "$LOG_DIR/.t4-static-after"; then echo "ok   no static pod has a new container"; else echo "FAIL static pods changed (lines above)"; fail=1; fi
    # The agent writes no log line for a failed quiet window. The text of the failed check is in the
    # status of its operation, and NVKE copies it into the message of the cycle.
    cluster_json | jq -r '.conditions.certificateRenewal.message // ""' | grep -q 'quiet window failed' && echo "ok   the quiet window check of the agent failed: $(cluster_json | jq -r '.conditions.certificateRenewal.message // ""' | sed -E 's/.*(failed at step)/\1/' | cut -c1-400)" || { echo "FAIL the message of the cycle does not name the quiet window check"; fail=1; }
    [ "$(cluster_json | jq -r '.conditions.certificateRenewal.state // ""')" = failed ] && echo "ok   NVKE reports the cycle as failed: $(cluster_json | jq -c '.conditions.certificateRenewal | {phase, failedNodeID, message}' | cut -c1-500)" || { echo "FAIL NVKE does not report the cycle as failed: $(cluster_json | jq -c '.conditions.certificateRenewal' | cut -c1-300)"; fail=1; }
    temporal workflow describe --workflow-id "$wid" 2>&1 | grep -E '^ *Status' | grep -q -i -E 'COMPLETED|FAILED' && echo "ok   the workflow is closed" || echo "note the workflow is not closed"
    [ -z "$(cluster_json | jq -r '.conditions.updateInProgress.type // ""')" ] && echo "ok   no update in progress, the lock is free" || echo "note NVKE keeps the lock: $(cluster_json | jq -c '.conditions.updateInProgress' | cut -c1-300). This cluster goes away with a DELETE through the NVKE API"
    grep -q 'gate file PRESENT' "$LOG_DIR/.t4-gates-after" && echo "note a gate file is left after the failed operation (lines above)" || echo "ok   no gate file is left after the failed operation"
    provider_pods >"$LOG_DIR/.t4-pods-after"
    if diff "$LOG_DIR/.t4-pods-before" "$LOG_DIR/.t4-pods-after"; then echo "ok   the pods of the provider have no change (UID, host node, restart count, image)"; else echo "note the pods of the provider changed"; fi
    grep -q 'failed: 0$' "$LOG_DIR/probe-t4-$label-summary.txt" && echo "ok   the shared address answered each call with 200" || echo "note the shared address has calls that are not 200"
    [ "$fail" = 0 ] && echo "RESULT pass rule 4 ($label): PASS" || echo "RESULT pass rule 4 ($label): FAIL"
  } 2>&1 | tee "$out"
  grep -q "RESULT pass rule 4 ($label): PASS" "$out"
}

# --- the test of the fix for the encryption join defect ----------------------------------------
# section_of <ClusterConfiguration file>: the apiServer part as lines. The names of the flags, and
# the volumes with name, host path and type. No value of a flag.
section_of() {
  awk '/^apiServer:/{f=1;next} /^[a-zA-Z]/{f=0} f' "$1" >"$LOG_DIR/.section"
  awk '/^  extraArgs:/{g=1;next} /^  [a-zA-Z]/{g=0} g && /name:/ {print "flag " $NF}' "$LOG_DIR/.section" | sort
  awk '/^  extraVolumes:/{g=1;next} /^  [a-zA-Z]/{g=0} g' "$LOG_DIR/.section" |
    awk 'function out() { if (n) print "volume name=" nm " hostPath=" hp " pathType=" pt }
         /^  - /{out(); n=1; nm="-"; hp="-"; pt="-"}
         {for (i=1; i<NF; i++) { if ($i=="name:") nm=$(i+1); if ($i=="hostPath:") hp=$(i+1); if ($i=="pathType:") pt=$(i+1) }}
         END {out()}' | sort
}
# Record the apiServer part of the ClusterConfiguration in the kubeadm-config ConfigMap of the new cluster.
cmd_apiserver_section() {
  local label=${1:?label} f
  f="$LOG_DIR/kubeadm-clusterconfiguration-$label.yaml"
  write_podmap
  ik "${CPS[0]}" -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' >"$f"
  say "kubeadm-config ConfigMap, apiServer part ($label) at $(date -u +%FT%TZ): $(grep -m1 '^apiVersion:' "$f")"
  section_of "$f" | tee "$LOG_DIR/apiserver-section-$label.txt"
  echo "flags: $(grep -c '^flag ' "$LOG_DIR/apiserver-section-$label.txt"), volumes: $(grep -c '^volume ' "$LOG_DIR/apiserver-section-$label.txt")"
}
# Pass rule of the fix for the ConfigMap: each flag and volume from before is still there, the two
# encryption flags and the volume enc are added, and no volume names the file that no code makes.
cmd_section_check() {
  local before=${1:?label before} after=${2:?label after} old=${3:-} fail=0 b a n
  b="$LOG_DIR/apiserver-section-$before.txt"; a="$LOG_DIR/apiserver-section-$after.txt"
  {
    say "the apiServer part before ($before) and after ($after) encryption was turned on"
    n=$(grep -v -x -F -f "$a" "$b" | grep -c . || true)
    [ "$n" = 0 ] && echo "ok   each of the $(grep -c . "$b") lines from before is still there" || { echo "FAIL $n lines from before are gone:"; grep -v -x -F -f "$a" "$b"; fail=1; }
    echo "lines that are new:"; grep -v -x -F -f "$b" "$a" || true
    grep -q -x 'flag encryption-provider-config' "$a" && grep -q -x 'flag encryption-provider-config-automatic-reload' "$a" && echo "ok   the two encryption flags are there" || { echo "FAIL an encryption flag is missing"; fail=1; }
    grep -q -x 'volume name=enc hostPath=/etc/kubernetes/kube-api-encryption pathType=DirectoryOrCreate' "$a" && echo "ok   the volume enc for the folder /etc/kubernetes/kube-api-encryption is there" || { echo "FAIL the volume enc is missing"; fail=1; }
    grep -q 'hostPath=/etc/kubernetes/encryption-config.yaml' "$a" && { echo "FAIL a volume for the file /etc/kubernetes/encryption-config.yaml is there"; fail=1; } || echo "ok   no volume for the file /etc/kubernetes/encryption-config.yaml"
    [ "$(grep -v -x -F -f "$b" "$a" | grep -c . || true)" = 3 ] && echo "ok   exactly three lines are new" || echo "note the count of new lines is not three"
    if [ -n "$old" ] && [ -s "$old" ]; then
      say "for comparison: the same part of the cluster c-1, where the old agent turned encryption on"
      section_of "$old"
    fi
    [ "$fail" = 0 ] && echo "RESULT section-check: PASS" || echo "RESULT section-check: FAIL"
  } 2>&1 | tee "$LOG_DIR/section-check.txt"
  grep -q 'RESULT section-check: PASS' "$LOG_DIR/section-check.txt"
}
# The flags of the running API server of each control plane node, from its mirror pod: the names,
# and one checksum over the names and values without the flag --advertise-address (it differs for each node).
cmd_apiserver_flags() {
  local label=${1:?label}
  write_podmap
  ik "${CPS[0]}" -n kube-system get pods -l component=kube-apiserver -o json >"$LOG_DIR/.apiserver-pods.json"
  jq -r '.items[] | .spec.nodeName as $n | .spec.containers[0].command[1:][] | "\($n) \(.)"' "$LOG_DIR/.apiserver-pods.json" | sort >"$LOG_DIR/apiserver-flags-$label-full.txt"
  say "flags of the running API servers ($label) at $(date -u +%FT%TZ)"
  for n in $(cut -d' ' -f1 "$LOG_DIR/apiserver-flags-$label-full.txt" | sort -u); do
    echo "$n: $(grep -c "^$n " "$LOG_DIR/apiserver-flags-$label-full.txt") flags, with --encryption-provider-config: $(grep -c "^$n --encryption-provider-config=" "$LOG_DIR/apiserver-flags-$label-full.txt"), checksum of the flags without --advertise-address: $(grep "^$n " "$LOG_DIR/apiserver-flags-$label-full.txt" | cut -d' ' -f2- | grep -v '^--advertise-address=' | sort | md5sum | cut -c1-12), image $(jq -r --arg n "$n" '.items[] | select(.spec.nodeName==$n) | .spec.containers[0].image | sub(".*/"; "")' "$LOG_DIR/.apiserver-pods.json"), started $(jq -r --arg n "$n" '.items[] | select(.spec.nodeName==$n) | .status.containerStatuses[0].state.running.startedAt // "-"' "$LOG_DIR/.apiserver-pods.json"), restarts $(jq -r --arg n "$n" '.items[] | select(.spec.nodeName==$n) | .status.containerStatuses[0].restartCount' "$LOG_DIR/.apiserver-pods.json")"
  done | tee "$LOG_DIR/apiserver-flags-$label.txt"
  cut -d' ' -f2- "$LOG_DIR/apiserver-flags-$label-full.txt" | grep -v '^--advertise-address=' | sort -u >"$LOG_DIR/apiserver-flags-$label-set.txt"
}
# Pass rule of the fix for the new nodes: the API server of each new node has the flag
# --encryption-provider-config and the same other flags as the old nodes had.
cmd_flags_check() {
  local old=${1:?label old} new=${2:?label new} fail=0 n
  {
    say "the flags of the API servers of the new nodes ($new) against the old nodes ($old)"
    cat "$LOG_DIR/apiserver-flags-$new.txt"
    n=$(awk '{print $1}' "$LOG_DIR/apiserver-flags-$new.txt" | grep -c . || true)
    [ "$(grep -c 'with --encryption-provider-config: 1,' "$LOG_DIR/apiserver-flags-$new.txt" || true)" = "$n" ] && [ "$n" = "${#CPS[@]}" ] && echo "ok   each of the $n API servers runs with --encryption-provider-config" || { echo "FAIL not each API server has --encryption-provider-config"; fail=1; }
    [ -z "$(comm -12 <(awk '{print $1}' "$LOG_DIR/apiserver-flags-$old.txt" | sed 's/:$//' | sort) <(awk '{print $1}' "$LOG_DIR/apiserver-flags-$new.txt" | sed 's/:$//' | sort))" ] && echo "ok   each node of now is a new node" || { echo "FAIL an old node is still there"; fail=1; }
    if diff "$LOG_DIR/apiserver-flags-$old-set.txt" "$LOG_DIR/apiserver-flags-$new-set.txt" >"$LOG_DIR/.flags-diff"; then
      echo "ok   the new nodes have the same $(grep -c . "$LOG_DIR/apiserver-flags-$new-set.txt") flags with the same values as the old nodes (without --advertise-address)"
    else
      echo "FAIL the flags differ. Names of the flags that differ: $(grep -E '^[<>]' "$LOG_DIR/.flags-diff" | sed -E 's/^([<>]) (--[a-z0-9-]+).*/\1\2/' | sort -u | tr '\n' ' ')"; fail=1
    fi
    [ "$fail" = 0 ] && echo "RESULT flags-check: PASS" || echo "RESULT flags-check: FAIL"
  } 2>&1 | tee "$LOG_DIR/flags-check.txt"
  grep -q 'RESULT flags-check: PASS' "$LOG_DIR/flags-check.txt"
}
# Pass rule of the fix for the join: each JoinNode workflow since a time is completed, and its
# KubeadmJoin activity ran one time.
cmd_join_check() {
  local label=${1:?rollout label} since fail=0 wid st n=0 line
  since=$(cat "$LOG_DIR/cp-rollout-$label-since.txt")
  {
    say "JoinNode workflows since the PATCH of the rollout $label ($since)"
    temporal workflow list --query "WorkflowType=\"JoinNode\" AND StartTime > \"$since\"" --limit 30 2>&1 | tee "$LOG_DIR/.join-list" | cut -c1-140
    while read -r st wid _; do
      case "$wid" in join-node-*) ;; *) continue ;; esac
      n=$((n + 1))
      line=$(temporal workflow show --workflow-id "$wid" --output json 2>/dev/null | jq -r '(.events // .) as $e | ($e | map(select(.activityTaskScheduledEventAttributes != null) | {key: (.eventId | tostring), value: .activityTaskScheduledEventAttributes.activityType.name}) | from_entries) as $n | [$e[] | select(.activityTaskStartedEventAttributes != null) | select($n[(.activityTaskStartedEventAttributes.scheduledEventId | tostring)] == "KubeadmJoin") | (.activityTaskStartedEventAttributes.attempt // 1)] | "KubeadmJoin started \(length) time(s), highest attempt \(max // 0)"' 2>/dev/null || echo "no history")
      echo "$wid: $st, $line"
      [ "$st" = Completed ] || fail=1
      case "$line" in "KubeadmJoin started 1 time(s), highest attempt 1") ;; *) fail=1 ;; esac
    done <"$LOG_DIR/.join-list"
    [ "$n" -ge "${#CPS[@]}" ] || { echo "FAIL only $n JoinNode workflows"; fail=1; }
    [ "$fail" = 0 ] && echo "RESULT join-check: PASS ($n JoinNode workflows, each completed with one KubeadmJoin attempt)" || echo "RESULT join-check: FAIL"
  } 2>&1 | tee "$LOG_DIR/join-check-$label.txt"
  grep -q 'RESULT join-check: PASS' "$LOG_DIR/join-check-$label.txt"
}
# A new Secret through the API, and the first bytes of its value in etcd (the check of the last
# encryption test). Then the Secret is deleted.
cmd_secret_check() {
  local name=${1:-p2gaps-encfix-after} v line
  write_podmap
  {
    say "a new Secret after the rollout, at $(date -u +%FT%TZ)"
    ik a -n default create secret generic "$name" --from-literal=note=p2gaps-written-after-the-rollout 2>&1 | tail -1 || true
    line=$(raw_secret "$name" | cut -c1-40)
    echo "$name in etcd (first bytes): [$line]"
    v=$(ik a -n default get secret "$name" -o jsonpath='{.data.note}' 2>/dev/null | base64 -d 2>/dev/null || true)
    [ "$v" = p2gaps-written-after-the-rollout ] && echo "ok   the Secret is readable through the API, with the same value" || echo "FAIL the Secret is not readable"
    ik a -n default delete secret "$name" 2>&1 | tail -1 || true
    case "$line" in k8s:enc:*) echo "ok   the new Secret is stored encrypted (prefix ${line%%:v1:*}:v1), not as plain text"; echo "RESULT secret-check: PASS" ;; *) echo "FAIL the new Secret is not stored with an encryption prefix"; echo "RESULT secret-check: FAIL" ;; esac
  } 2>&1 | tee "$LOG_DIR/secret-check.txt"
  grep -q 'RESULT secret-check: PASS' "$LOG_DIR/secret-check.txt"
}

cmd_kernel_check() { OUT="$LOG_DIR" "$GAPS/ss-kill-check.sh" "${1:?guest pod}" "${2:?client kind node}" "${3:-47611}" "${4:-ss-kill}"; }

step=${1:-}
shift || true
case "$step" in
  gate-facts | gate-report | apiserver-section | section-check | apiserver-flags | flags-check | join-check | secret-check | t1 | enc | t2 | cp-rollout | free-place | gap2-check | t4 | kernel-check | ready-start | ready-stop | init | facts | health | g1 | rotate | g2 | upgrade | pool-upgrade | pool-post | pool-wait | pool-delete | worker-delete | pool-scale | cp-state | w1 | w2 | placement | wait-good | probe-start | probe-stop | flow | delete | base | post)
    mkdir -p "$LOG_DIR"
    "cmd_${step//-/_}" "$@" 2>&1 | tee -a "$LOG_DIR/run.log"
    exit "${PIPESTATUS[0]}"
    ;;
  state) sample 1; state_line ;;
  line) cluster_line ;;
  podmap) write_podmap; paste -d' ' "$PODMAP" <(cut -d' ' -f2 "$LOG_DIR/roles.txt") ;;
  *) sed -n '2,26p' "$0"; exit 1 ;;
esac
