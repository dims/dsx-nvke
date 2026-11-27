#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The provider and the NVKE controller of the gap tests, on the machine.
#   images      load the two image archives into Docker of the machine and into the four kind nodes
#   provider    apply infrastructure-components-<commit>.yaml and the RBAC file (as p2-worker/install.sh)
#   controller  helm upgrade of the release nvke-controller with the new image tag only. It prints the
#               Helm history before and after. The values of the release stay (--reuse-values)
#   rollback <revision>   helm rollback of the controller
#   status      images, pods, Helm history
# Usage: install-stack.sh <step>
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
PROVIDER_COMMIT=${PROVIDER_COMMIT:-d2880014}
CONTROLLER_TAG=${CONTROLLER_TAG:-5c08484c}
STACK=$W/d/stack
CHART=$W/d/src/controller/deploy/charts/controller
HELM=$W/bin/helm
export KUBECONFIG=$STACK/secrets/kubeconfig.internal
export HELM_CACHE_HOME=$STACK/cache/helm/cache HELM_CONFIG_HOME=$STACK/cache/helm/config HELM_DATA_HOME=$STACK/cache/helm/data
KIND_NODE=${KIND_NODE:-kata-bb-control-plane}
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
history() { "$HELM" -n nvke-controller history nvke-controller 2>&1 | cut -c1-150; }
case "${1:-}" in
  images)
    for f in "$W/dl/img/p2gaps/cluster-api-provider-podvm_$PROVIDER_COMMIT.tar" "$W/dl/img/p2gaps/nvke-controller_$CONTROLLER_TAG.tar"; do
      [ -s "$f" ] || { echo "no archive $f"; exit 1; }
      docker load -q -i "$f"
    done
    for t in "cluster-api-provider-podvm:$PROVIDER_COMMIT" "nvke-controller:$CONTROLLER_TAG"; do
      docker image inspect "$t" | jq -c --arg t "$t" '.[0] | {image: $t, id: .Id[7:19], size: .Size}'
      "$W/bin/img-load.sh" "$t" $NODES
      for n in $NODES; do echo "$n: $(docker exec "$n" crictl inspecti -o json "docker.io/library/$t" 2>/dev/null | jq -r '.status.id' | cut -c8-19)"; done
    done
    ;;
  provider)
    M=$HERE/install/infrastructure-components-$PROVIDER_COMMIT.yaml
    IMG=$(awk '$1=="image:" && $2 ~ /cluster-api-provider-podvm/ {print $2}' "$M")
    echo "== image of the manifest: $IMG, before: $(k -n podvm-system get deployment podvm-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}')"
    for n in $NODES; do echo "$n: $(docker exec "$n" crictl inspecti -o json "$IMG" 2>/dev/null | jq -r '.status.id' | cut -c8-19)"; done
    nodei "${KC[@]}" apply -f - <"$M" | grep -v -E ' unchanged$' || true
    nodei "${KC[@]}" apply -f - <"$HERE/install/nvke-controller-rbac.yaml" | grep -v -E ' unchanged$' || true
    k -n podvm-system rollout status deployment/podvm-controller-manager --timeout=180s
    k -n podvm-system get pods -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName --no-headers
    for i in $(seq 1 30); do [ -n "$(k -n podvm-system get lease -o name 2>/dev/null)" ] && break; sleep 2; done
    k -n podvm-system get lease -o custom-columns=NAME:.metadata.name,HOLDER:.spec.holderIdentity,RENEWED:.spec.renewTime --no-headers
    sleep 8
    echo "== the manager log"
    k -n podvm-system logs deployment/podvm-controller-manager --tail=12 | cut -c1-220
    ;;
  controller)
    echo "== Helm history before"; history
    echo "image before: $(k -n nvke-controller get deployment nvke-controller -o jsonpath='{.spec.template.spec.containers[0].image}')"
    for n in $NODES; do echo "$n has the new image: $(docker exec "$n" crictl inspecti -o json "docker.io/library/nvke-controller:$CONTROLLER_TAG" 2>/dev/null | jq -r '.status.id' | cut -c8-19)"; done
    t0=$(date +%s)
    "$HELM" upgrade nvke-controller "$CHART" --namespace nvke-controller --reuse-values --set "image.tag=$CONTROLLER_TAG" --wait --timeout 5m 2>&1 | grep -v -i -E 'password|secret' | cut -c1-200
    echo "helm upgrade took $(( $(date +%s) - t0 )) s"
    echo "== Helm history after"; history
    "$0" status
    ;;
  rollback)
    "$HELM" -n nvke-controller rollback nvke-controller "${2:?revision}" --wait --timeout 5m
    history
    ;;
  status)
    echo "provider: $(k -n podvm-system get deployment podvm-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}{" ready="}{.status.readyReplicas}')"
    echo "controller: $(k -n nvke-controller get deployment nvke-controller -o jsonpath='{.spec.template.spec.containers[0].image}{" replicas="}{.status.replicas}{" ready="}{.status.readyReplicas}{" updated="}{.status.updatedReplicas}')"
    k -n nvke-controller get pods -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.startTime --no-headers
    echo "readyz of the controller: $(k get --raw /api/v1/namespaces/nvke-controller/services/nvke-controller:http/proxy/readyz 2>&1 | tr -d '\n' | cut -c1-120)"
    echo "version of the API: $(env -u LOG_DIR "$W/d/stack/api.sh" get /api/version 2>&1 | tr -d '\n' | cut -c1-200)"
    history | tail -3
    ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
