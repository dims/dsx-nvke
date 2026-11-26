#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, test 3b: restart the kata-deploy DaemonSet while the three replicas run. This is the
# upstream regression test of issue 12761 (tests/functional/kata-deploy/kata-deploy-lifecycle.bats).
#
#   t3b-kata-deploy-daemonset.sh to-daemonset <run>   change the install to deploymentMode=daemonset
#   t3b-kata-deploy-daemonset.sh run <run>            kubectl rollout restart daemonset/kata-deploy
#   t3b-kata-deploy-daemonset.sh to-job <run>         change the install back to job mode (rollback)
#
# The chart refuses a change of deploymentMode for a release that exists
# (templates/kata-deploy-state.yaml). So "to-daemonset" and "to-job" are an uninstall and an
# install. The uninstall removes /opt/kata and the kata-deploy handlers and restarts containerd.
# A running Kata pod does not survive that, so these two steps stop the replicas first (scale
# to 0, the volumes stay) and start them again after the install.
#
# What "to-daemonset" changes: replicas down, "helm uninstall kata-deploy", "helm install" with
# deploymentMode=daemonset (same chart version, same values), one small test pod, replicas up
# on the class of record. It records what the uninstall and the install do to /opt/kata-fix, to
# the imports line of /etc/containerd/config.toml and to the extra handlers.
# What "run" changes: one rollout restart of the DaemonSet. From the source, the old pod does no
# cleanup, and the new pod writes /opt/kata again and restarts containerd one time.
#
# VERSION=<x> selects the chart version of the install (default: the version in /opt/kata/VERSION).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

# The values that differ when each replica has a new pod and the inner cluster started again.
NEW_POD_KEYS='^(pod_uid|pod_ip|restarts|container_id|container_started|ready_since|sandbox_id|boot_id|shim\.[0-9]+|virtiofsd\.[0-9]+|hypervisor\.[0-9]+|etcd_leader|etcd_raft_term|inner_containers|inner_units)$'

switch_mode() { # switch_mode <mode>
  local mode=$1 version
  version=${VERSION:-$(n cat /opt/kata/VERSION)}
  preflight
  state before identity
  reinstall "$version" "$mode" "$CLASS_RECORD"
  check_fix_handlers || true
  state after identity
  IDENTITY_MAY_DIFFER='pod-ip|boot-id' compare before after "$NEW_POD_KEYS" || true
  diag run-start
}

case "${1:-}" in
  to-daemonset)
    init_run "${TEST:-t3b-to-daemonset}" "${2:?run}"
    switch_mode daemonset
    sleep 1
    result
    ;;
  to-job)
    init_run "${TEST:-t3b-to-job}" "${2:?run}"
    switch_mode job
    sleep 1
    result
    ;;
  run)
    init_run "${TEST:-t3b-kata-deploy-daemonset}" "${2:?run}"
    preflight
    k -n "$HELM_NS" get daemonset kata-deploy -o wide || die "no DaemonSet kata-deploy. Run to-daemonset first."
    state before identity
    loops_start
    sleep "$BASELINE"
    say "action: kubectl -n $HELM_NS rollout restart daemonset/kata-deploy (in the kind node)"
    start_action action-ds-rollout.sh 3
    wait_action 10 900 || echo "FAIL: the action did not run"
    for f in kd-old-pod.log kd-new-pod.log rollout.log; do n cat "$ND/$f" >"$OUT/$f" 2>/dev/null || true; done
    say "the old pod at its stop (last lines of its log)"
    tail -8 "$OUT/kd-old-pod.log" | cut -c1-240
    say "the new pod: lines about the restart and the files"
    grep -E 'restart|Restart|Extracting component|imports|Skipping|skipping|label' "$OUT/kd-new-pod.log" | cut -c1-240 | head -40
    sleep "$AFTER"
    loops_stop
    state after identity
    compare before after || true
    "$HERE/analyze.sh" "$OUT"
    diag action-start
    check_fix_handlers || true
    sleep 1
    result
    ;;
  *)
    sed -n '2,/^HERE=/p' "$0" | sed '$d'
    exit 1
    ;;
esac
