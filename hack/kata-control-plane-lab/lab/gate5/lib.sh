#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5 harness: settings and functions that each script uses. Source this file.
#
# Rules that the functions obey:
# - Each kubectl, crictl and curl call runs in the kind node (docker exec). The host opens no
#   TCP connection to the cluster. The one exception is helm, which a test script calls one time.
# - Each loop and each action runs as a systemd unit of the kind node (systemd-run), never with
#   "docker exec -d". The kubelet unit of a kind node does not start while the root cgroup of
#   the node holds a process (/kind/bin/create-kubelet-cgroup-v2.sh). Measured on 2026-11-26:
#   on the running node a "docker exec" process is in the cgroup /init.scope (the cgroup of
#   PID 1), and the root cgroup is empty. A "docker exec" that starts before systemd moved PID 1
#   there (right after "docker start") is in the root cgroup. That was the fault of cold start
#   run 1 of gate 4. The action scripts still read the root cgroup before a kubelet restart,
#   and the host starts no "docker exec" for some seconds around an action (see wait_action).
# - No command stops a process by its name. Units stop with "systemctl stop".
set -uo pipefail
export LC_ALL=C # one sort order for sort, comm and join

NODE=${NODE:-kata-cp-control-plane}
NS=${NS:-gate4}
REPLICAS=(a b c)
IP_API=172.30.255.210
declare -A IPS=([a]=172.30.255.211 [b]=172.30.255.212 [c]=172.30.255.213)

WORK=/scratch/kata-cp/work/gate5
LOG_ROOT=${LOG_ROOT:-/scratch/kata-cp/logs/gate5}
G4_DIR=/home/dsrinivas/notes/hosted/lab/gate4 # read only
HOST_KUBECONFIG=/scratch/kata-cp/kubeconfig
VALUES=${VALUES:-/home/dsrinivas/notes/hosted/lab/kata-deploy-values.yaml}
HELM_NS=kube-system
HELM_RELEASE=kata-deploy
CHART_OCI=oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy
# A local chart file is used when it exists, so that helm makes no registry request.
CHART_431=${CHART_431:-$WORK/charts/kata-deploy-4.3.1.tgz}
CHART_440=${CHART_440:-$WORK/charts/kata-deploy-4.4.0.tgz}
FIX_PLAN=/scratch/kata-cp/images/kata-fix/plan

CLASS_RECORD=kata-clh-runtime-rs-fix-direct # the class of record (patched agent, direct I/O)
# The class of the replicas while Kata 4.3.1 is installed: the stock handler kata-clh-runtime-rs
# (stock runtime, stock guest image) with a memory overhead of 512 Mi. The overhead is a value
# of the RuntimeClass object. The kubelet adds it to the limit of the pod cgroup, and Kata does
# not read it. With the stock 130 Mi the pod cgroup can kill the hypervisor (gate 1).
CLASS_STOCK=${CLASS_STOCK:-kata-clh-runtime-rs-ovh512}
OVERHEAD_CLASSES=/home/dsrinivas/notes/hosted/lab/gate1-nvke/runtimeclasses-overhead.yaml # read only

READYZ_INTERVAL=${READYZ_INTERVAL:-0.5} # seconds between two calls of one target
BASELINE=${BASELINE:-20}                # seconds of loop data before the action
AFTER=${AFTER:-45}                      # seconds of loop data after the action
ND_ROOT=/run/g5                         # in the kind node (tmpfs)
GD=/run/g5                              # in each guest (tmpfs)

n() { docker exec "$NODE" "$@"; }
ni() { docker exec -i "$NODE" "$@"; }
k() { n kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
ki() { ni kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
pod() { # pod <r> <command...>: a command in the node pod of replica r
  local r=$1
  shift
  k -n "$NS" exec "cp-$r-0" -- "$@"
}
podi() { # the same, with stdin
  local r=$1
  shift
  ki -n "$NS" exec -i "cp-$r-0" -- "$@"
}
say() { echo "== $*"; }
die() {
  echo "ERROR: $*" >&2
  exit 1
}
now() { date +%s.%N; }
stamp() { printf '%s %s\n' "$(now)" "$1" >>"$OUT/times.txt"; }
stamp_of() { awk -v n="$1" '$2==n {x=$1} END {print x}' "$OUT/times.txt" 2>/dev/null; }

# init_run <test> <run>: the log folder of one run, and the folder of the run in the node.
init_run() {
  TEST=$1
  RUN=$2
  RUN_ID="$TEST-$RUN"
  OUT="$LOG_ROOT/$RUN_ID"
  ND="$ND_ROOT/$RUN_ID"
  [ ! -e "$OUT/times.txt" ] || die "$OUT has a run already. Use another run name."
  mkdir -p "$OUT"
  # One test at a time: two tests on the same node spoil the numbers of each other.
  exec 9>"$LOG_ROOT/.lock"
  flock -n 9 || die "another gate 5 test runs (lock $LOG_ROOT/.lock)"
  exec > >(tee -a "$OUT/run.log") 2>&1
  trap on_exit EXIT
  say "$RUN_ID at $(date -u +%FT%TZ), logs in $OUT"
  stamp run-start
}

# A script that stops early must not leave its loops in the node and in the guests, and each
# run must leave one line in progress.txt.
LOOPS_RUNNING=0
RESULT_DONE=0
on_exit() {
  if [ "$LOOPS_RUNNING" = 1 ]; then
    echo "the script ends while the loops run. Stop them."
    loops_stop
  fi
  if [ "$RESULT_DONE" = 0 ]; then
    echo "RESULT $RUN_ID: FAIL (the script ended before its last step)"
    sleep 1
    progress_line "FAIL (ended early)"
  fi
}

# progress_line <verdict>: one line for $LOG_ROOT/progress.txt: time, test, run, verdict and
# the main numbers of the run. The main session reads that file.
kv_of() { grep "^cp-$2-0 $3=" "$OUT/state-$1/kv.txt" 2>/dev/null | cut -d= -f2-; } # kv_of <label> <r> <key>
pid_of() { # pid_of <label> <unit>: the main PID of a unit in a node summary
  sed -n '/^== SUMMARY/,/^== END SUMMARY/p' "$OUT/state-$1/node.txt" 2>/dev/null | awk -v u="$2: MainPID=" 'index($0, u) == 1 {split(substr($0, length(u) + 1), x, " "); print x[1]}'
}
progress_line() {
  local verdict=$1 s="" r same=0 causes
  if [ -s "$OUT/analysis.txt" ]; then
    s="$s calls: $(awk '/^(shared|a|b|c): [0-9]+ calls/ {g = "?"; for (i = 1; i <= NF; i++) if ($i == "calls:") g = $(i + 1); printf "%s longest gap %s s, %s of %s failed; ", $1, g, $4, $2}' "$OUT/analysis.txt")"
  fi
  if [ -s "$OUT/state-before/kv.txt" ] && [ -s "$OUT/state-after/kv.txt" ]; then
    for r in "${REPLICAS[@]}"; do [ -n "$(kv_of before "$r" boot_id)" ] && [ "$(kv_of before "$r" boot_id)" = "$(kv_of after "$r" boot_id)" ] && same=$((same + 1)); done
    s="$s etcd leader/term $(kv_of before a etcd_leader)/$(kv_of before a etcd_raft_term) -> $(kv_of after a etcd_leader)/$(kv_of after a etcd_raft_term);"
    s="$s pod restarts $(kv_of before a restarts),$(kv_of before b restarts),$(kv_of before c restarts) -> $(kv_of after a restarts),$(kv_of after b restarts),$(kv_of after c restarts);"
    s="$s guest boot IDs the same: $same of 3;"
    s="$s containerd PID $(pid_of before containerd) -> $(pid_of after containerd); kubelet PID $(pid_of before kubelet) -> $(pid_of after kubelet);"
  fi
  causes=$(grep -E '^FAIL|^ERROR:' "$OUT/run.log" 2>/dev/null | sort -u | head -4 | cut -c1-200 | tr '\n' '|')
  printf '%s %s %s %s.%s%s logs: %s\n' "$(date -u +%FT%TZ)" "$TEST" "$RUN" "$verdict" "$s" "${causes:+ causes: $causes}" "$OUT" >>"$LOG_ROOT/progress.txt"
}

# The files of a script folder go to the node with "tee", so that no shell string is necessary.
node_put() { ni tee "$2" <"$1" >/dev/null; }
guest_put() { # guest_put <r> <local file> <path in the guest>
  podi "$1" tee "$3" <"$2" >/dev/null
}

# node_unit <unit> <args...>: a transient systemd unit in the kind node.
# --expand-environment=no: systemd must not replace ${...} in the arguments.
node_unit() {
  local unit=$1
  shift
  n systemd-run --quiet --collect --expand-environment=no --unit="$unit" "$@"
}

# Checks before a test. They only read.
preflight() {
  local r x
  say "preflight"
  free -g | sed -n 1,2p
  for r in "${REPLICAS[@]}"; do
    x=$(k -n "$NS" get pod "cp-$r-0" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.spec.runtimeClassName}' 2>&1)
    echo "cp-$r-0: ready and class: $x"
    case "$x" in "True "*) ;; *) die "the pod cp-$r-0 is not ready" ;; esac
  done
  x=$(n systemctl list-units --all --no-legend 'g5-*' | awk '{print $1}' | tr '\n' ' ')
  [ -z "$x" ] || die "units of an earlier run are in the node: $x. Stop them first (g5.sh loops-stop-all)."
  x=$(k get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if ($4 != "Running" || a[1] != a[2]) print $1 "/" $2 " " $3 " " $4}')
  if [ -n "$x" ]; then echo "WARNING: pods of the host cluster that do not run or are not ready:"; echo "$x"; fi
  x=$(k get pods -A -o jsonpath='{range .items[?(@.spec.runtimeClassName)]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.runtimeClassName}{"\n"}{end}' 2>/dev/null | grep -v "^$NS/" || true)
  if [ -n "$x" ]; then echo "NOTE: pods of other namespaces with a RuntimeClass (the test acts on their node):"; echo "$x"; fi
}

# ---- loops -------------------------------------------------------------------------------

loops_start() {
  local r t0 g t1
  say "start the loops (kind node: units g5-readyz and g5-k8s, each guest: unit g5-guest)"
  LOOPS_RUNNING=1
  n mkdir -p "$ND"
  node_put "$WORK/node/node-loops.sh" "$ND/node-loops.sh"
  node_unit g5-readyz bash "$ND/node-loops.sh" readyz "$ND" "$READYZ_INTERVAL" "$IP_API" "${IPS[a]}" "${IPS[b]}" "${IPS[c]}" ||
    die "cannot start the unit g5-readyz"
  node_unit g5-k8s bash "$ND/node-loops.sh" k8s "$ND" 1 "$NS" "$NODE" || die "cannot start the unit g5-k8s"
  for r in "${REPLICAS[@]}"; do
    pod "$r" mkdir -p "$GD" || die "no exec in cp-$r-0"
    guest_put "$r" "$WORK/node/guest-sampler.sh" "$GD/guest-sampler.sh"
    pod "$r" systemd-run --quiet --collect --expand-environment=no --unit=g5-guest bash "$GD/guest-sampler.sh" "$GD" ||
      die "cannot start the unit g5-guest in cp-$r-0"
    # The clock of the guest against the clock of the host (the exec itself takes about 0.1 s).
    t0=$(now)
    g=$(pod "$r" date +%s.%N)
    t1=$(now)
    echo "cp-$r host-before=$t0 guest=$g host-after=$t1" >>"$OUT/clock-offsets.txt"
  done
  stamp loops-started
}

# Stop the loops and copy their logs. A guest that is gone gives an empty file.
loops_stop() {
  local r f
  say "stop the loops and copy the logs"
  LOOPS_RUNNING=0
  n systemctl stop g5-readyz.service g5-k8s.service 2>/dev/null || true
  for f in readyz-shared readyz-a readyz-b readyz-c k8s; do
    n cat "$ND/$f.log" >"$OUT/$f.log" 2>/dev/null || true
  done
  for r in "${REPLICAS[@]}"; do
    pod "$r" systemctl stop g5-guest.service 2>/dev/null || true
    for f in heartbeat etcd local-readyz; do
      pod "$r" cat "$GD/$f.log" >"$OUT/guest-$r-$f.log" 2>/dev/null || true
    done
  done
  stamp loops-stopped
  wc -l "$OUT"/readyz-*.log "$OUT"/guest-*-etcd.log | sed 's/^/   /'
}

# ---- an action in the kind node -------------------------------------------------------------

# start_action <script in $WORK/node> [args...]: run the script as the unit g5-action. The
# script waits some seconds first, so that this "docker exec" is gone before the action starts.
start_action() {
  local script=$1
  shift
  node_put "$WORK/node/$script" "$ND/$script"
  stamp action-queued
  n systemd-run --quiet --collect --no-block --expand-environment=no --unit=g5-action bash "$ND/$script" "$ND" "$@" ||
    die "cannot start the unit g5-action"
}

# wait_action <blind seconds> <timeout seconds>: no "docker exec" for the blind time, then one
# short check each 3 seconds.
wait_action() {
  local blind=$1 timeout=$2 t0
  say "wait $blind s with no command in the node, then for the end of the action (at most $timeout s)"
  sleep "$blind"
  t0=$(date +%s)
  until n test -e "$ND/action.done" 2>/dev/null; do
    [ "$(date +%s)" -lt "$((t0 + timeout))" ] || { echo "FAIL: the action did not end in $timeout s"; break; }
    sleep 3
  done
  n cat "$ND/action.log" >"$OUT/action.log" 2>/dev/null || true
  # The stamps of the action go into times.txt too.
  awk '$2 ~ /^(action-start|action-returned|cri-answers|kubelet-active|kubelet-healthz-ok|node-lease-renewed|rollout-done|ABORT)$/ {print $1, $2}' "$OUT/action.log" >>"$OUT/times.txt"
  sed 's/^/   /' "$OUT/action.log"
  if grep -q ' ABORT' "$OUT/action.log"; then return 1; fi
}

# ---- state -----------------------------------------------------------------------------------

# state <label> [identity]: the state of the node and of each replica, in $OUT/state-<label>/.
#   node.txt        what the kind node has (units, containerd configuration, handlers, Kata files)
#   replica-<r>.txt what the guest of replica r has
#   kv.txt          the values that a test must not change, one line "<pod> <key>=<value>"
# With "identity", also the identity files of gate 4 (certificate checksums, etcd members).
state() {
  local label=$1 id=${2:-} d r
  d="$OUT/state-$label"
  mkdir -p "$d"
  say "state $label"
  ni bash -s -- "$NS" <"$WORK/node/node-state.sh" >"$d/node.txt" 2>&1 || echo "WARNING: node-state.sh gave an error"
  n find /opt/kata -xdev \( -type f -o -type l \) -printf '%i %s %T@ %y %p %C@\n' 2>/dev/null | sort -k5 >"$d/opt-kata.lst" || true
  n cat /etc/containerd/config.toml >"$d/containerd-config.toml" 2>&1 || true
  grep '^KV ' "$d/node.txt" | cut -d' ' -f2- >"$d/kv.txt"
  for r in "${REPLICAS[@]}"; do
    podi "$r" bash -s <"$WORK/node/guest-state.sh" >"$d/replica-$r.txt" 2>&1 || echo "WARNING: no guest state of cp-$r-0"
    grep '^KV ' "$d/replica-$r.txt" | cut -d' ' -f2- | sed "s/^/cp-$r-0 /" >>"$d/kv.txt"
  done
  sort -o "$d/kv.txt" "$d/kv.txt"
  if [ "$id" = identity ]; then
    LOG_DIR="$OUT" NS="$NS" OWNER=sts "$G4_DIR/run.sh" identity "$label" >/dev/null 2>&1 || echo "WARNING: identity $label gave an error"
  fi
  stamp "state-$label"
  grep -E '^cp-[abc]-0 (pod_uid|restarts|container_id|pod_ip|boot_id|shim\.[0-9]+|hypervisor\.[0-9]+|etcd_raft_term|etcd_leader)=' "$d/kv.txt" | sed 's/^/   /'
}

# compare <before> <after> [keys that may differ, as an awk regex]: no value of kv.txt may
# change. Prints each difference. Returns 1 when a value differs.
compare() {
  local a="$OUT/state-$1/kv.txt" b="$OUT/state-$2/kv.txt" allow=${3:-^$} out rc=0 r
  out="$OUT/compare-$1-$2.txt"
  {
    say "compare the state $1 and the state $2"
    if diff <(awk -v re="$allow" '{split($2,x,"="); if (x[1] !~ re) print}' "$a") \
      <(awk -v re="$allow" '{split($2,x,"="); if (x[1] !~ re) print}' "$b") >"$OUT/.diff"; then
      echo "no difference in $(grep -c . "$a") values"
    else
      echo "FAIL: values differ (< before, > after):"
      cat "$OUT/.diff"
      rc=1
    fi
    for r in "${REPLICAS[@]}"; do
      [ -s "$OUT/identity-$r-$1.txt" ] && [ -s "$OUT/identity-$r-$2.txt" ] || continue
      if diff "$OUT/identity-$r-$1.txt" "$OUT/identity-$r-$2.txt" >"$OUT/.diff"; then
        echo "cp-$r: identity files are the same ($(grep -c . "$OUT/identity-$r-$1.txt") lines)"
      else
        echo "cp-$r: identity differs:"
        cat "$OUT/.diff"
        if grep -E '^[<>]' "$OUT/.diff" | grep -v -E "^[<>] (${IDENTITY_MAY_DIFFER:-none}) " | grep -q .; then
          echo "FAIL: the identity of cp-$r changed"
          rc=1
        fi
      fi
    done
    echo "what the node has, before and after:"
    diff <(sed -n '/^== SUMMARY/,/^== END SUMMARY/p' "$OUT/state-$1/node.txt") \
      <(sed -n '/^== SUMMARY/,/^== END SUMMARY/p' "$OUT/state-$2/node.txt") && echo "   no difference in the node summary"
    # The change time (field 6) shows that a file was made again or changed. The inode number
    # does not: the file system gives a new file the number of a file that was just removed.
    echo "files of /opt/kata: $(wc -l <"$OUT/state-$1/opt-kata.lst") before, $(wc -l <"$OUT/state-$2/opt-kata.lst") after, $(join -j2 <(awk '{print $6, $5}' "$OUT/state-$1/opt-kata.lst" | sort -k2) <(awk '{print $6, $5}' "$OUT/state-$2/opt-kata.lst" | sort -k2) | awk '$2 != $3 {n++} END {print n + 0}') with a new change time (written again), $(comm -13 <(awk '{print $5}' "$OUT/state-$1/opt-kata.lst" | sort) <(awk '{print $5}' "$OUT/state-$2/opt-kata.lst" | sort) | wc -l) new paths, $(comm -23 <(awk '{print $5}' "$OUT/state-$1/opt-kata.lst" | sort) <(awk '{print $5}' "$OUT/state-$2/opt-kata.lst" | sort) | wc -l) paths gone"
    join -j2 <(awk '{print $6, $5}' "$OUT/state-$1/opt-kata.lst" | sort -k2) <(awk '{print $6, $5}' "$OUT/state-$2/opt-kata.lst" | sort -k2) | awk '$2 == $3 {print "   not written again: " $1}' | head -20
  } 2>&1 | tee "$out"
  grep -q '^FAIL' "$out" && rc=1
  return "$rc"
}

# ---- diagnosis -------------------------------------------------------------------------------

# diag <since stamp name>: the journals of containerd, of the kubelet and of the Kata shim, the
# kernel log of the node and the events, from 30 s before the stamp. The Rust shim of Kata
# writes to the journal of the node with the identifier "kata", and virtiofsd with "virtiofsd".
diag() {
  local t d
  t=$(stamp_of "$1")
  t=${t%.*}
  [ -n "$t" ] || t=$(date +%s)
  d="$OUT/diag"
  mkdir -p "$d"
  n journalctl --no-pager -o short-precise -u containerd --since "@$((t - 30))" >"$d/containerd-journal.txt" 2>&1 || true
  n journalctl --no-pager -o short-precise -u kubelet --since "@$((t - 30))" >"$d/kubelet-journal.txt" 2>&1 || true
  n journalctl --no-pager -o short-precise -t kata -t virtiofsd --since "@$((t - 30))" >"$d/kata-shim-journal.txt" 2>&1 || true
  n journalctl --no-pager -o short-precise --since "@$((t - 30))" >"$d/node-journal-all.txt" 2>&1 || true
  n dmesg -T 2>/dev/null | tail -300 >"$d/kernel-log-tail.txt" || true
  k get events -A --sort-by=.lastTimestamp 2>&1 | tail -80 >"$d/events.txt" || true
  k -n "$NS" get pods -o yaml >"$d/pods.yaml" 2>&1 || true
  say "diagnosis files in $d"
  echo "   containerd journal: $(grep -c . "$d/containerd-journal.txt") lines, $(grep -c -i -E 'level=(error|warning)' "$d/containerd-journal.txt") with error or warning"
  grep -E 'Stopping containerd|Stopped containerd|Starting containerd|Started containerd|containerd successfully booted|cleaning up dead shim|cleanup leaked|shim disconnected|failed to load' "$d/containerd-journal.txt" | cut -c1-260 | head -40 | sed 's/^/   /'
  echo "   Kata shim journal: $(grep -c . "$d/kata-shim-journal.txt") lines, $(grep -c -i -E 'ERRO|error' "$d/kata-shim-journal.txt") with an error word"
  echo "   kubelet journal: $(grep -c . "$d/kubelet-journal.txt") lines"
  grep -E 'Stopping kubelet|Stopped kubelet|Started kubelet|Killing|SandboxChanged|sandbox.*(changed|dead|not ready)|Container.*(died|restart)|Predicate|NodeAffinity|admit' "$d/kubelet-journal.txt" | cut -c1-260 | head -40 | sed 's/^/   /'
}

# ---- replicas --------------------------------------------------------------------------------

# The StatefulSet of replica r, made by the templates of gate 4 (read only) for one class.
render_sts() { # render_sts <r> <class>
  local r=$1 class=$2 skip="" stop=10
  # A class with the patched agent needs no "init" cgroup and no stop timeout (gate 4, step 5).
  case "$class" in *-fix | *-fix-direct) skip=init-cgroup stop="" ;; esac
  LOG_DIR="$OUT/render" RUNTIME_CLASS="$class" G1_SKIP="$skip" STOP_TIMEOUT="$stop" OWNER=sts NS="$NS" "$G4_DIR/run.sh" render node-sts.yaml.tmpl "$r"
}

replicas_down() {
  say "scale the three StatefulSets to 0 (the claims and the volumes stay)"
  stamp replicas-down-start
  k -n "$NS" scale statefulset cp-a cp-b cp-c --replicas=0
  k -n "$NS" wait --for=delete pod/cp-a-0 pod/cp-b-0 pod/cp-c-0 --timeout=240s || die "a pod did not go away"
  stamp replicas-down-done
  k -n "$NS" get statefulset,pod,pvc
  # No Kata process of the namespace may stay.
  n crictl pods --namespace "$NS"
}

# replicas_up <class>: apply the three StatefulSets with one class, wait for /readyz and etcd.
replicas_up() {
  local class=$1 r
  say "start the three replicas with the class $class, from their volumes"
  mkdir -p "$OUT/render"
  stamp replicas-up-start
  for r in "${REPLICAS[@]}"; do
    render_sts "$r" "$class" >"$OUT/render/sts-$r-$class.yaml" || die "render of replica $r failed"
    ki apply -f - <"$OUT/render/sts-$r-$class.yaml" || die "apply of replica $r failed"
  done
  # "kubectl wait" for a condition stops at once when the pod is not there yet.
  k -n "$NS" wait --for=create pod/cp-a-0 pod/cp-b-0 pod/cp-c-0 --timeout=120s || die "the StatefulSets made no pods"
  k -n "$NS" wait --for=condition=Ready pod/cp-a-0 pod/cp-b-0 pod/cp-c-0 --timeout=600s || {
    k -n "$NS" get pods -o wide
    k -n "$NS" get events --sort-by=.lastTimestamp | tail -30
    die "the replicas are not ready"
  }
  stamp replicas-up-ready
  k -n "$NS" get pods -o wide
  for r in "${REPLICAS[@]}"; do echo "cp-$r-0: guest kernel $(pod "$r" uname -r), class $(k -n "$NS" get pod "cp-$r-0" -o jsonpath='{.spec.runtimeClassName}')"; done
}

# The checks of gate 4 (steps 3 and 6). They read, and they write their files to $OUT.
gate4_check() {
  local label=$1
  LOG_DIR="$OUT" NS="$NS" OWNER=sts "$G4_DIR/run.sh" check "$label" | tail -3
  LOG_DIR="$OUT" NS="$NS" OWNER=sts "$G4_DIR/run.sh" reach "$label" | tail -1
}

# ---- Kata installation -----------------------------------------------------------------------

chart_ref() { # chart_ref <version>: the local file when it exists, else the registry
  local f="$WORK/charts/kata-deploy-$1.tgz"
  if [ -s "$f" ]; then echo "$f"; else echo "$CHART_OCI --version $1"; fi
}
helm_k() { helm --kubeconfig "$HOST_KUBECONFIG" -n "$HELM_NS" "$@"; }

# The logs of the kata-deploy pods and jobs. The per-node jobs go away 600 s after their end.
kata_deploy_logs() {
  local label=$1 d p
  d="$OUT/kata-deploy-$label"
  mkdir -p "$d"
  k -n "$HELM_NS" get daemonset,job,pod -o wide 2>&1 | grep -E 'NAME|kata-deploy' >"$d/objects.txt" || true
  for p in $(k -n "$HELM_NS" get pods -o name 2>/dev/null | grep kata-deploy); do
    k -n "$HELM_NS" logs "$p" --all-containers --prefix --timestamps >"$d/$(basename "$p").log" 2>&1 || true
    k -n "$HELM_NS" get "$p" -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{" restarts="}{.restartCount}{" "}{.state}{"\n"}{end}{range .status.containerStatuses[*]}{.name}{" restarts="}{.restartCount}{" "}{.state}{"\n"}{end}' >"$d/$(basename "$p").status" 2>&1 || true
  done
  say "kata-deploy logs in $d"
  grep -h -E 'restart|Restart|Skipping|skipping|unchanged|changed its CRI config|Extracting component|Removing|removed|imports|cleanup' "$d"/*.log 2>/dev/null | cut -c1-240 | head -60 | sed 's/^/   /'
}

# node_summary <label>: what the node has (no replica state), in $OUT/state-<label>/.
node_summary() {
  mkdir -p "$OUT/state-$1"
  ni bash -s -- "$NS" <"$WORK/node/node-state.sh" >"$OUT/state-$1/node.txt" 2>&1 || true
  n find /opt/kata -xdev \( -type f -o -type l \) -printf '%i %s %T@ %y %p %C@\n' 2>/dev/null | sort -k5 >"$OUT/state-$1/opt-kata.lst" || true
  n cat /etc/containerd/config.toml >"$OUT/state-$1/containerd-config.toml" 2>&1 || true
  stamp "state-$1"
  say "node summary $1"
  sed -n '/^== SUMMARY/,/^== END SUMMARY/p' "$OUT/state-$1/node.txt" |
    grep -E '^(containerd|kubelet):|kata VERSION|imports line|^import |handlers |node labels|helm releases|kata-deploy objects' | cut -c1-300 | sed 's/^/   /'
  echo "   files in /opt/kata: $(wc -l <"$OUT/state-$1/opt-kata.lst")"
}

# The extra handlers of /opt/kata-fix must be in the containerd configuration, and the node
# must report them. This function changes nothing. It says what to do when they are absent.
check_fix_handlers() {
  local want="kata-clh-fix kata-clh-runtime-rs-direct kata-clh-runtime-rs-fix kata-clh-runtime-rs-fix-direct" h have miss=""
  have=$(k get node -o jsonpath='{.items[0].status.runtimeHandlers[*].name}')
  for h in $want; do case " $have " in *" $h "*) ;; *) miss="$miss $h" ;; esac; done
  echo "imports line: $(n grep -n '^imports' /etc/containerd/config.toml)"
  echo "/opt/kata-fix: $(n ls /opt/kata-fix 2>&1 | tr '\n' ' ')"
  echo "difference of the stock configuration and the configuration of the class of record (expected: the image line and the block_device_cache_direct line):"
  n diff /opt/kata/share/defaults/kata-containers/runtime-rs/runtimes/clh-runtime-rs/configuration-clh-runtime-rs.toml /opt/kata-fix/configuration-clh-runtime-rs-fix-direct.toml | sed 's/^/   /'
  if [ -z "$miss" ]; then
    echo "the node reports the four extra handlers"
  else
    echo "FAIL: the node does not report the handlers:$miss. Run $FIX_PLAN/01-install.sh again (it restarts containerd one time)."
    return 1
  fi
}

# ensure_fix_handlers: stop when the extra handlers are absent. With REINSTALL_FIX=1, run the
# install script of the extra handlers first (it restarts containerd one time).
ensure_fix_handlers() {
  check_fix_handlers && return 0
  [ "${REINSTALL_FIX:-0}" = 1 ] || die "the extra handlers are absent. Set REINSTALL_FIX=1 to run $FIX_PLAN/01-install.sh (it restarts containerd one time)."
  say "run $FIX_PLAN/01-install.sh"
  "$FIX_PLAN/01-install.sh" 2>&1 | tail -40
  check_fix_handlers || die "the extra handlers are still absent"
}

# ensure_class <class>: the RuntimeClass object must exist. The lab classes are not part of
# the Helm release, so an uninstall keeps them. If the overhead class is absent, make that one
# object from the file of gate 1 (one document of the file, not the whole file).
ensure_class() {
  local class=$1
  if k get runtimeclass "$class" >/dev/null 2>&1; then
    echo "RuntimeClass $class: $(k get runtimeclass "$class" -o jsonpath='{"handler "}{.handler}{", overhead "}{.overhead.podFixed}{", node selector "}{.scheduling.nodeSelector}')"
    return 0
  fi
  case "$class" in
    kata-clh-runtime-rs-ovh*)
      say "the RuntimeClass $class is absent. Make it from $OVERHEAD_CLASSES"
      awk -v want="  name: $class" 'BEGIN {RS = "---\n"} index($0, want "\n") {printf "%s", $0}' "$OVERHEAD_CLASSES" >"$OUT/runtimeclass-$class.yaml"
      [ "$(grep -c '^kind: RuntimeClass' "$OUT/runtimeclass-$class.yaml")" = 1 ] || die "cannot take the object $class from $OVERHEAD_CLASSES"
      ki apply -f - <"$OUT/runtimeclass-$class.yaml" || die "cannot make the RuntimeClass $class"
      ;;
    *) die "the RuntimeClass $class is absent" ;;
  esac
}

# kata_uninstall: "helm uninstall". It removes /opt/kata and the kata-deploy handlers and
# restarts containerd, so no Kata pod may run. In daemonset mode the pod of the DaemonSet does
# the cleanup when it stops, after helm returns, so wait until it is gone.
kata_uninstall() {
  local x rc
  say "action: helm uninstall $HELM_RELEASE (it removes /opt/kata and the kata-deploy handlers, and it restarts containerd)"
  [ -z "$(n crictl pods -q --namespace "$NS" --state ready)" ] || die "node pods still run. Stop them first."
  x=$(k get pods -A -o jsonpath='{range .items[?(@.spec.runtimeClassName)]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.runtimeClassName}{"\n"}{end}' | grep kata || true)
  if [ -n "$x" ]; then
    echo "$x"
    [ "${ALLOW_OTHER_KATA_PODS:-0}" = 1 ] || die "other Kata pods run on the node, and the uninstall stops them. Set ALLOW_OTHER_KATA_PODS=1 only when their owner agrees."
  fi
  stamp uninstall-start
  helm_k uninstall "$HELM_RELEASE" --timeout 15m >"$OUT/helm-uninstall.log" 2>&1
  rc=$?
  cat "$OUT/helm-uninstall.log"
  kata_deploy_logs after-uninstall
  [ "$rc" = 0 ] || die "helm uninstall gave exit code $rc"
  # "kubectl wait" with a selector gives an error when nothing matches, so look first.
  if k -n "$HELM_NS" get pods -l name=kata-deploy --no-headers 2>/dev/null | grep -q .; then
    k -n "$HELM_NS" wait --for=delete pod -l name=kata-deploy --timeout=900s || die "a pod of the DaemonSet did not go away"
  fi
  if k -n "$HELM_NS" get jobs -l app.kubernetes.io/instance="$HELM_RELEASE" --no-headers 2>/dev/null | grep -q .; then
    k -n "$HELM_NS" wait --for=delete job -l app.kubernetes.io/instance="$HELM_RELEASE" --timeout=900s || true
  fi
  stamp uninstall-done
  echo "after the uninstall: containerd $(n systemctl is-active containerd), /opt/kata has $(n find /opt/kata -mindepth 1 2>/dev/null | wc -l) entries, node label kata-runtime: [$(k get node "$NODE" -o jsonpath='{.metadata.labels.katacontainers\.io/kata-runtime}')]"
}

# kata_install <version> <mode>: "helm install" with the values of the lab. mode = job or daemonset.
kata_install() {
  local version=$1 mode=$2 rc
  # shellcheck disable=SC2046
  set -- $(chart_ref "$version")
  say "action: helm install $HELM_RELEASE $* -f $VALUES --set deploymentMode=$mode"
  stamp install-start
  helm_k install "$HELM_RELEASE" "$@" -f "$VALUES" --set "deploymentMode=$mode" --timeout 20m >"$OUT/helm-install.log" 2>&1
  rc=$?
  cat "$OUT/helm-install.log"
  [ "$rc" = 0 ] || die "helm install gave exit code $rc"
  if [ "$mode" = daemonset ]; then
    k -n "$HELM_NS" rollout status daemonset/kata-deploy --timeout=900s || die "the DaemonSet is not ready"
  fi
  k wait node "$NODE" --for=condition=Ready --timeout=300s
  # The node label is the last step of an install.
  k wait node "$NODE" --for=jsonpath='{.metadata.labels.katacontainers\.io/kata-runtime}'=true --timeout=300s ||
    die "the node has no label katacontainers.io/kata-runtime=true"
  stamp install-done
  kata_deploy_logs after-install
  echo "after the install: Kata $(n cat /opt/kata/VERSION), mode $(k -n "$HELM_NS" get configmap "$HELM_RELEASE-kata-deploy-state" -o jsonpath='{.data.deploymentMode}')"
}

# reinstall <version> <mode> <class>: stop the replicas, uninstall, install, start the replicas
# with a class. It records what the uninstall and the install do to the extra handlers.
reinstall() {
  local version=$1 mode=$2 class=$3 s
  node_summary 0-before
  if [ -n "$(n crictl pods -q --namespace "$NS" --state ready)" ]; then replicas_down; fi
  # The release secret shows if a release exists (a read in the node, no helm call).
  if k -n "$HELM_NS" get secret -l "owner=helm,name=$HELM_RELEASE" --no-headers 2>/dev/null | grep -q .; then
    kata_uninstall
  else
    echo "no release $HELM_RELEASE: no uninstall"
  fi
  node_summary 1-after-uninstall
  kata_install "$version" "$mode"
  node_summary 2-after-install
  say "what the uninstall and the install did to the extra handlers and to the containerd configuration"
  for s in 0-before 1-after-uninstall 2-after-install; do
    echo "-- $s"
    grep -E 'imports line|^import |handlers |^containerd:|kata VERSION' "$OUT/state-$s/node.txt" | cut -c1-300 | sed 's/^/   /'
    echo "   files in /opt/kata: $(wc -l <"$OUT/state-$s/opt-kata.lst"), entries in /opt/kata-fix: $(sed -n '/^\/opt\/kata-fix/,/^\/opt\/kata\/share/p' "$OUT/state-$s/node.txt" | grep -c '^   ')"
  done
  # A class with the patched agent needs the extra handlers of /opt/kata-fix.
  case "$class" in *-fix | *-fix-direct | *-direct) ensure_fix_handlers ;; esac
  ensure_class "$class"
  test_pod "$class"
  replicas_up "$class"
  gate4_check "after-install-$version-$mode"
}

# One Kata pod with a class, to prove that the handler starts a guest. It prints the guest kernel.
test_pod() { # test_pod <class>
  local class=$1 name
  name="g5-probe-${class//[^a-z0-9]/-}"
  name=${name:0:60}
  ki apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $name, namespace: default, labels: {g5: probe}}
spec:
  runtimeClassName: $class
  restartPolicy: Never
  terminationGracePeriodSeconds: 2
  automountServiceAccountToken: false
  containers:
    - name: c
      image: kindest/node:v1.36.4
      imagePullPolicy: Never
      command: ["sleep", "600"]
      resources: {limits: {cpu: "1", memory: 512Mi}}
EOF
  if k -n default wait --for=condition=Ready "pod/$name" --timeout=120s; then
    echo "class $class: the pod runs, guest kernel $(k -n default exec "$name" -- uname -r)"
  else
    echo "FAIL: class $class: the pod does not run"
    k -n default describe pod "$name" | tail -20
  fi
  k -n default delete pod "$name" --wait=true --timeout=120s
}

# The verdict of a run. A test script calls it last.
result() {
  local fail=0
  sleep 1 # the output of this script goes to run.log through "tee"
  grep -q -E '^FAIL|^ERROR:' "$OUT/run.log" && fail=1
  if [ "$fail" = 0 ]; then echo "RESULT $RUN_ID: PASS"; else echo "RESULT $RUN_ID: FAIL (see the FAIL lines in $OUT/run.log)"; fi
  stamp run-end
  RESULT_DONE=1
  if [ "$fail" = 0 ]; then progress_line PASS; else progress_line FAIL; fi
}
