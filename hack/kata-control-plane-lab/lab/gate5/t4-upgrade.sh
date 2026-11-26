#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, test 4 (phase C): upgrade Kata from 4.3.1 to 4.4.0 while the three replicas run.
#
#   t4-upgrade.sh to-old <run>          bring the node to Kata 4.3.1 and start the replicas on the
#                                       stock class of 4.3.1
#   t4-upgrade.sh upgrade <run>         "helm upgrade" to 4.4.0 with the loops running
#   t4-upgrade.sh mixed-restart <run>   one containerd restart after the upgrade, while the old
#                                       guests of 4.3.1 still run (same steps as test 1)
#   t4-upgrade.sh new-pod <run>         a new Kata pod starts on 4.4.0, and one replica that is
#                                       made again on 4.4.0 joins its old etcd member
#   t4-upgrade.sh to-record <run>       check the extra handlers, then move the three replicas
#                                       to the class of record, one at a time
#   t4-upgrade.sh restore <run>         rollback from each state: install 4.4.0 in job mode
#                                       again and start the replicas on the class of record
#
# Variables:
#   FROM=4.3.1  TO=4.4.0     the two versions
#   MODE=job|daemonset       the deployment mode of the release (default job, the chart default
#                            of the two versions)
#   CLASS_STOCK=kata-clh-runtime-rs-ovh512   the class of the replicas while 4.3.1 is installed:
#                            the stock handler kata-clh-runtime-rs (stock runtime and stock
#                            guest image of 4.3.1) with a memory overhead of 512 Mi. The overhead
#                            is a RuntimeClass value. The patched guest image fits 4.4.0 only.
#   REPLACE=c                the replica that "new-pod" makes again
#   REINSTALL_FIX=1          "to-record" runs 01-install.sh when the extra handlers are absent
#   REF_LIST=<file>          a file list of /opt/kata from a clean 4.4.0 install
#                            (state-before/opt-kata.lst of test 1), to find files that the
#                            upgrade left from 4.3.1
#
# What the installer does at the upgrade, from the source (binary/src/artifacts/install.rs,
# extract_tarball): for each file of the new release it removes the old file and then makes a
# new one. A process that has the old file open or mapped keeps the old content. A file that
# only 4.3.1 had stays in /opt/kata.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
FROM=${FROM:-4.3.1}
TO=${TO:-4.4.0}
MODE=${MODE:-job}
REPLACE=${REPLACE:-c}
NEW_POD_KEYS='^(pod_uid|pod_ip|restarts|container_id|container_started|ready_since|sandbox_id|sandbox_handler|runtime_class|boot_id|guest_kernel|shim\.[0-9]+|virtiofsd\.[0-9]+|hypervisor\.[0-9]+|etcd_leader|etcd_raft_term|inner_containers|inner_units)$'

sha_list() { # sha_list <label>: the checksum of each file of /opt/kata
  n find /opt/kata -xdev -type f -exec sha256sum {} + 2>/dev/null | sort -k2 >"$OUT/state-$1/opt-kata.sha256" || true
}

# replace_one <r> <label>: delete the pod of replica r and wait for the new one. The step
# "replace" of gate 4 does the work and compares the identity (certificates, etcd member).
replace_one() {
  local r=$1 label=$2 old_sb
  old_sb=$(n crictl pods -q --state ready --label io.kubernetes.pod.namespace="$NS" --label io.kubernetes.pod.name="cp-$r-0" | head -1)
  say "replace the pod of replica $r ($label). Old sandbox $old_sb"
  LOG_DIR="$OUT" NS="$NS" OWNER=sts "$G4_DIR/run.sh" replace "$r" "$label" | tail -25
  echo "cp-$r-0 now: class $(k -n "$NS" get pod "cp-$r-0" -o jsonpath='{.spec.runtimeClassName}'), guest kernel $(pod "$r" uname -r)"
  # The old sandbox must leave no process and no folder.
  echo "processes of the old sandbox: $(n ps -eo pid=,args= | grep -F "$old_sb" | grep -v grep | wc -l). /run/kata/$old_sb: $(n ls -d "/run/kata/$old_sb" 2>&1 | tail -1)"
  if n ps -eo args= | grep -F "$old_sb" | grep -v grep | grep -q .; then echo "FAIL: processes of the old sandbox of cp-$r-0 stay"; fi
}

case "${1:-}" in
  to-old)
    init_run "${TEST:-t4-to-old}" "${2:?run}"
    free -g | sed -n 1,2p
    df -h /scratch | tail -1
    state before identity
    reinstall "$FROM" "$MODE" "$CLASS_STOCK"
    [ "$(n cat /opt/kata/VERSION)" = "$FROM" ] || echo "FAIL: /opt/kata/VERSION is not $FROM"
    state after identity
    IDENTITY_MAY_DIFFER='pod-ip|boot-id' compare before after "$NEW_POD_KEYS" || true
    say "the replicas on Kata $FROM"
    grep -E '^cp-[abc]-0 (guest_kernel|runtime_class|sandbox_handler)=' "$OUT/state-after/kv.txt"
    diag run-start
    sleep 1
    result
    ;;

  upgrade)
    init_run "${TEST:-t4-upgrade}" "${2:?run}"
    preflight
    [ "$(n cat /opt/kata/VERSION)" = "$FROM" ] || die "/opt/kata/VERSION is not $FROM. Run to-old first."
    mode=$(k -n "$HELM_NS" get configmap "$HELM_RELEASE-kata-deploy-state" -o jsonpath='{.data.deploymentMode}' 2>/dev/null)
    echo "deployment mode of the release: ${mode:-unknown}"
    [ "$mode" = "$MODE" ] || die "the release is in the mode $mode, not $MODE"
    # A per-node Job of the install lives for 600 s. Do not delete it: wait for its end of life,
    # so that the dispatcher of the upgrade makes its own Job (as test 3a does).
    old=$(k -n "$HELM_NS" get jobs -l kata-deploy/stage=install --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    if [ -n "$old" ] && [ "${WAIT_OLD_JOB:-1}" = 1 ]; then
      say "a per-node Job of an earlier run is present: $old. Wait until it is gone (at most 660 s)."
      k -n "$HELM_NS" wait --for=delete job -l kata-deploy/stage=install --timeout=660s || die "the old Job did not go away"
    fi
    state before identity
    sha_list before
    loops_start
    sleep "$BASELINE"

    # shellcheck disable=SC2046
    set -- $(chart_ref "$TO")
    say "action: helm upgrade $HELM_RELEASE $* -f $VALUES --set deploymentMode=$MODE (Kata $FROM to $TO)"
    stamp action-start
    helm_k upgrade "$HELM_RELEASE" "$@" -f "$VALUES" --set "deploymentMode=$MODE" --timeout 20m >"$OUT/helm.log" 2>&1
    rc=$?
    cat "$OUT/helm.log"
    [ "$rc" = 0 ] || echo "FAIL: helm upgrade gave exit code $rc"
    if [ "$MODE" = daemonset ]; then
      # Helm does not wait for the new pod of the DaemonSet. The new pod does the install.
      k -n "$HELM_NS" rollout status daemonset/kata-deploy --timeout=900s || echo "FAIL: the DaemonSet is not ready"
    fi
    k wait node "$NODE" --for=jsonpath='{.metadata.labels.katacontainers\.io/kata-runtime}'=true --timeout=300s || echo "FAIL: the node label is not true"
    stamp action-end
    kata_deploy_logs after-upgrade
    sleep "${AFTER_UPGRADE:-60}"

    loops_stop
    state after identity
    sha_list after
    compare before after || true
    "$HERE/analyze.sh" "$OUT"
    diag action-start

    say "what the upgrade did"
    echo "Kata version file: $(grep 'kata VERSION' "$OUT/state-before/node.txt") -> $(grep 'kata VERSION' "$OUT/state-after/node.txt")"
    grep -E '^(containerd|kubelet):|imports line|^import |handlers ' "$OUT/state-before/node.txt" | cut -c1-300 | sed 's/^/   before: /'
    grep -E '^(containerd|kubelet):|imports line|^import |handlers ' "$OUT/state-after/node.txt" | cut -c1-300 | sed 's/^/   after:  /'
    echo "files of /opt/kata with the same path: $(join -j2 <(sort -k2 "$OUT/state-before/opt-kata.sha256") <(sort -k2 "$OUT/state-after/opt-kata.sha256") | awk '{n++; if ($2 == $3) same++} END {printf "%d, %d of them with the same content", n, same}')"
    echo "paths that only the state before has (removed): $(comm -23 <(awk '{print $5}' "$OUT/state-before/opt-kata.lst" | sort) <(awk '{print $5}' "$OUT/state-after/opt-kata.lst" | sort) | wc -l)"
    echo "paths that only the state after has (new): $(comm -13 <(awk '{print $5}' "$OUT/state-before/opt-kata.lst" | sort) <(awk '{print $5}' "$OUT/state-after/opt-kata.lst" | sort) | wc -l)"
    ref=${REF_LIST:-$LOG_ROOT/t1-containerd-1/state-before/opt-kata.lst}
    if [ -s "$ref" ]; then
      echo "paths that a clean $TO install does not have (left from $FROM), reference $ref:"
      comm -13 <(awk '{print $5}' "$ref" | sort) <(awk '{print $5}' "$OUT/state-after/opt-kata.lst" | sort) | sed 's/^/   /'
    fi
    say "the Kata processes of the replicas BEFORE the upgrade: program file, open files and mapped files in /opt"
    grep -E '^INFO cp-[abc]-0 (shim|virtiofsd|hypervisor) pid=[0-9]+ ' "$OUT/state-before/node.txt" | sed -E 's/started=.* exe=/program /; s/^INFO //' | cut -c1-260
    say "the same processes AFTER the upgrade (a file with \"(deleted)\" was removed or replaced, and the process still has the old content)"
    grep -E '^INFO cp-[abc]-0 (shim|virtiofsd|hypervisor) pid=[0-9]+ ' "$OUT/state-after/node.txt" | sed -E 's/started=.* exe=/program /; s/^INFO //' | cut -c1-260
    say "does each process of the baseline still run (same PID and same start time)"
    grep -E '^cp-[abc]-0 (shim|virtiofsd|hypervisor)\.[0-9]+=' "$OUT/state-before/kv.txt" | while read -r line; do
      if grep -q -F -x "$line" "$OUT/state-after/kv.txt"; then echo "   runs: $line"; else echo "FAIL: gone or new: $line"; fi
    done
    say "the guests after the upgrade (they must be the guests of $FROM)"
    grep -E '^cp-[abc]-0 (guest_kernel|boot_id)=' "$OUT/state-after/kv.txt"
    sleep 1
    result
    ;;

  mixed-restart)
    # The same steps as test 1, with another name for the log folder.
    TEST=${TEST:-t4-mixed-containerd} exec "$HERE/t1-containerd.sh" "${2:?run}"
    ;;

  new-pod)
    init_run "${TEST:-t4-new-pod}" "${2:?run}"
    preflight
    [ "$(n cat /opt/kata/VERSION)" = "$TO" ] || die "/opt/kata/VERSION is not $TO. Run upgrade first."
    say "1. a new Kata pod with the stock class of $TO"
    test_pod "$CLASS_STOCK"
    state before identity
    # A follower, so that the etcd leader stays and the two other replicas show no change.
    lead=$(grep '^cp-a-0 etcd_leader=' "$OUT/state-before/kv.txt" | cut -d= -f2)
    if [ "$(grep "^cp-$REPLACE-0 etcd_member_id=" "$OUT/state-before/kv.txt" | cut -d= -f2)" = "$lead" ] && [ "${REPLACE_LEADER:-0}" != 1 ]; then
      for r in "${REPLICAS[@]}"; do
        if [ "$(grep "^cp-$r-0 etcd_member_id=" "$OUT/state-before/kv.txt" | cut -d= -f2)" != "$lead" ]; then
          echo "replica $REPLACE is the etcd leader. Use replica $r."
          REPLACE=$r
          break
        fi
      done
    fi
    say "2. replica $REPLACE made again on $TO (class $(k -n "$NS" get statefulset "cp-$REPLACE" -o jsonpath='{.spec.template.spec.runtimeClassName}'))"
    replace_one "$REPLACE" "new-pod-$REPLACE"
    state after identity
    echo "replica $REPLACE keeps its etcd member and its certificates, and the other replicas do not change:"
    IDENTITY_MAY_DIFFER='pod-ip|boot-id' compare before after "$NEW_POD_KEYS" || true
    # Values of the two other replicas: no difference is permitted.
    for r in "${REPLICAS[@]}"; do
      [ "$r" != "$REPLACE" ] || continue
      if diff <(grep "^cp-$r-0 " "$OUT/state-before/kv.txt") <(grep "^cp-$r-0 " "$OUT/state-after/kv.txt"); then
        echo "cp-$r-0: no difference"
      else
        echo "FAIL: cp-$r-0 changed, and its pod was not replaced"
      fi
    done
    grep -E "^cp-$REPLACE-0 (etcd_member_id|etcd_members|inner_nodes|machine_id|guest_kernel)=" "$OUT/state-before/kv.txt" | sed 's/^/   before: /' | cut -c1-300
    grep -E "^cp-$REPLACE-0 (etcd_member_id|etcd_members|inner_nodes|machine_id|guest_kernel)=" "$OUT/state-after/kv.txt" | sed 's/^/   after:  /' | cut -c1-300
    for key in etcd_member_id etcd_members inner_nodes machine_id; do
      [ "$(grep "^cp-$REPLACE-0 $key=" "$OUT/state-before/kv.txt")" = "$(grep "^cp-$REPLACE-0 $key=" "$OUT/state-after/kv.txt")" ] || echo "FAIL: $key of cp-$REPLACE-0 changed"
    done
    gate4_check after-new-pod
    diag run-start
    sleep 1
    result
    ;;

  to-record)
    init_run "${TEST:-t4-to-record}" "${2:?run}"
    preflight
    [ "$(n cat /opt/kata/VERSION)" = "$TO" ] || die "/opt/kata/VERSION is not $TO"
    node_summary 0-before
    ensure_fix_handlers
    test_pod "$CLASS_RECORD"
    state before identity
    # One replica at a time, so that etcd keeps its quorum. The leader goes last.
    lead=$(grep '^cp-a-0 etcd_leader=' "$OUT/state-before/kv.txt" | cut -d= -f2)
    order=""
    last=""
    for r in "${REPLICAS[@]}"; do
      if [ "$(grep "^cp-$r-0 etcd_member_id=" "$OUT/state-before/kv.txt" | cut -d= -f2)" = "$lead" ]; then last=$r; else order="$order $r"; fi
    done
    for r in $order $last; do
      render_sts "$r" "$CLASS_RECORD" >"$OUT/sts-$r-$CLASS_RECORD.yaml" || die "render of replica $r failed"
      ki apply -f - <"$OUT/sts-$r-$CLASS_RECORD.yaml" || die "apply of replica $r failed"
      replace_one "$r" "to-record-$r"
    done
    state after identity
    IDENTITY_MAY_DIFFER='pod-ip|boot-id' compare before after "$NEW_POD_KEYS" || true
    gate4_check final
    node_summary 9-final
    say "end state"
    k -n "$NS" get pods -o wide
    grep -E '^cp-[abc]-0 (guest_kernel|runtime_class|sandbox_handler|restarts)=' "$OUT/state-after/kv.txt"
    k get runtimeclass
    diag run-start
    sleep 1
    result
    ;;

  restore)
    init_run "${TEST:-t4-restore}" "${2:?run}"
    reinstall "$TO" job "$CLASS_RECORD"
    state after identity
    diag run-start
    sleep 1
    result
    ;;

  *)
    sed -n '2,/^HERE=/p' "$0" | sed '$d'
    exit 1
    ;;
esac
