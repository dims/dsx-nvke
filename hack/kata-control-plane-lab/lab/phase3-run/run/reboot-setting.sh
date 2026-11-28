#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The setting NODE_REBOOT_SOFT_REBOOT_ENABLED of the lab NVKE controller, through ONE helm upgrade
# of the release nvke-controller (--reuse-values, only the list "env" of the chart changes).
#   status    the env list of the release values, the setting in the pod, the Helm history
#   off       add NODE_REBOOT_SOFT_REBOOT_ENABLED=false to the env list
#   on        remove the entry from the env list (the default of NVKE is true)
# The way back is also "helm rollback nvke-controller <revision>" (p2-gaps/install-stack.sh rollback).
# Usage: reboot-setting.sh <step>
set -euo pipefail
. /root/kata-cp/bin/env.sh
STACK=$W/d/stack
CHART=$W/d/src/controller/deploy/charts/controller
HELM=$W/bin/helm
export KUBECONFIG=$STACK/secrets/kubeconfig.internal
export HELM_CACHE_HOME=$STACK/cache/helm/cache HELM_CONFIG_HOME=$STACK/cache/helm/config HELM_DATA_HOME=$STACK/cache/helm/data
NAME=NODE_REBOOT_SOFT_REBOOT_ENABLED
k() { "$W/bin/kubectl" --kubeconfig "$W/secrets/kubeconfig" "$@"; }
history() { "$HELM" -n nvke-controller history nvke-controller 2>&1 | cut -c1-110; }
env_list() { "$HELM" -n nvke-controller get values nvke-controller -o json | jq -c '.env // []'; }
status() {
  echo "env list of the release values (names only): $(env_list | jq -c '[.[].name]')"
  echo "$NAME in the release values: $(env_list | jq -r --arg n "$NAME" '([.[] | select(.name==$n) | .value][0]) // "not set (NVKE default: true)"')"
  echo "$NAME in the container of the pod: $(k -n nvke-controller get deployment nvke-controller -o json | jq -r --arg n "$NAME" '([.spec.template.spec.containers[0].env[]? | select(.name==$n) | .value][0]) // "not set"')"
  echo "image: $(k -n nvke-controller get deployment nvke-controller -o jsonpath='{.spec.template.spec.containers[0].image}'), pods: $(k -n nvke-controller get pods --no-headers | awk '{print $1 "=" $2 "/" $3 "/restarts " $4}' | tr '\n' ' ')"
  history
}
upgrade() { # <new env list, JSON>
  local t0
  echo "== $(utc) Helm history before"; history
  t0=$(date +%s)
  "$HELM" upgrade nvke-controller "$CHART" --namespace nvke-controller --reuse-values --set-json "env=$1" --wait --timeout 5m 2>&1 | grep -v -i -E 'password|secret' | cut -c1-200
  echo "helm upgrade took $(( $(date +%s) - t0 )) s"
  k -n nvke-controller rollout status deployment/nvke-controller --timeout=180s | tail -1
  echo "== $(utc) after"; status
}
case "${1:-}" in
  status) status ;;
  off) upgrade "$(env_list | jq -c --arg n "$NAME" '[.[] | select(.name!=$n)] + [{name: $n, value: "false"}]')" ;;
  on) upgrade "$(env_list | jq -c --arg n "$NAME" '[.[] | select(.name!=$n)]')" ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
