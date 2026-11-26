#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Gate 5, test 3a: run the kata-deploy install again, in job mode, for the version that is
# installed, while the three replicas run.
#
#   t3a-kata-deploy-job.sh <run>    logs in /scratch/kata-cp/logs/gate5/t3a-kata-deploy-job-<run>/
#   FORCE_RESTART=1 t3a-kata-deploy-job.sh <run>
#       Change the modification time of the kata-deploy drop-in file first (touch). The cri
#       stage then cannot prove that containerd read the file, and it restarts containerd.
#       This shows the restart path of job mode with no change of the file content.
#
# The command is the one that the Kata documents give for a second run
# (docs/helm-configuration.md, "Adding nodes in job mode"):
#   helm upgrade kata-deploy <chart> --version <installed version> -f <the values of the install>
# Helm runs the hook Job kata-deploy-install-dispatcher. The dispatcher makes one Job for the
# node with the stages load-kernel-modules, host-check, artifacts (init containers) and cri.
#
# What changes: the Helm release gets a new revision. The artifacts stage writes each file of
# /opt/kata again (remove, then create). The cri stage restarts containerd only when the
# containerd files changed or containerd did not start after their last write. The node pulls
# the dispatcher image and checks the kata-deploy image (imagePullPolicy Always).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

init_run "${TEST:-t3a-kata-deploy-job}" "${1:?run}"
VERSION=${VERSION:-$(n cat /opt/kata/VERSION)}
preflight
say "release before"
k get secret -n "$HELM_NS" -l owner=helm,name="$HELM_RELEASE" --no-headers -o custom-columns='NAME:.metadata.name,STATUS:.metadata.labels.status'
mode=$(k -n "$HELM_NS" get configmap "$HELM_RELEASE-kata-deploy-state" -o jsonpath='{.data.deploymentMode}' 2>/dev/null)
echo "deployment mode of the release: ${mode:-unknown}. Installed version: $VERSION"
[ "$mode" = job ] || die "the release is not in job mode"
# A per-node Job of an earlier run stays for 600 s. Do not delete it: wait for its end of life.
old=$(k -n "$HELM_NS" get jobs -l kata-deploy/stage=install --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [ -n "$old" ] && [ "${WAIT_OLD_JOB:-1}" = 1 ]; then
  say "a per-node Job of an earlier run is present: $old. Wait until it is gone (at most 660 s)."
  k -n "$HELM_NS" wait --for=delete job -l kata-deploy/stage=install --timeout=660s || die "the old Job did not go away"
elif [ -n "$old" ]; then
  echo "NOTE: a per-node Job of an earlier run is present: $old (WAIT_OLD_JOB=0, no wait)"
fi

state before identity
loops_start
sleep "$BASELINE"

if [ "${FORCE_RESTART:-0}" = 1 ]; then
  f=$(n sh -c "grep '^imports' /etc/containerd/config.toml | grep -o '\"[^\"]*kata-deploy[^\"]*\"' | tr -d '\"' | head -1")
  say "FORCE_RESTART: touch $f"
  n touch "$f"
fi

# shellcheck disable=SC2046
set -- $(chart_ref "$VERSION")
say "action: helm upgrade $HELM_RELEASE $* -f $VALUES (job mode, the same version)"
stamp action-start
helm_k upgrade "$HELM_RELEASE" "$@" -f "$VALUES" --timeout 15m >"$OUT/helm.log" 2>&1
rc=$?
stamp action-end
cat "$OUT/helm.log"
[ "$rc" = 0 ] || echo "FAIL: helm upgrade gave exit code $rc"
kata_deploy_logs after-upgrade
sleep "$AFTER"

loops_stop
state after identity
compare before after || true
"$HERE/analyze.sh" "$OUT"
diag action-start
say "what the run did to containerd (from the node summary)"
grep -E '^(containerd|kubelet):|imports line|^import |handlers ' "$OUT/state-before/node.txt" | sed 's/^/   before: /'
grep -E '^(containerd|kubelet):|imports line|^import |handlers ' "$OUT/state-after/node.txt" | sed 's/^/   after:  /'
sleep 1
result
