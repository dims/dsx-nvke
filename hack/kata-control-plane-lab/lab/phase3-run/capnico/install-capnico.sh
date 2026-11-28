#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# CAPNICo (the NICo provider for Cluster API) in the lab cluster, as NVKE deploys it at 5c08484c:
# the manifest deploy/nico/capnico/capnico.yaml (the public release asset of v0.3.0-rc.1 with
# the reboot and repair annotation names of NVKE in the manager arguments) and the image
# ghcr.io/dsx-ai-factory/cluster-api-provider-nico/controller:v0.3.0-rc.1. No Helm, no build.
#
#   images    load the image archive into Docker of the machine and into the four kind nodes
#             (a kind node cannot pull here). The archive comes from the workstation.
#   install   apply capnico.yaml, wait for the manager, then apply the Secret nico-credentials
#   secret    apply only the Secret (after a change of the address of the simulator)
#   status    image in the nodes, the five kinds, the manager, its arguments, the Secret keys,
#             the rights of the NVKE controller for the NICo kinds
#   remove    delete the Secret and each object of capnico.yaml. It refuses when a NicoMachine
#             or a NicoCluster exists
# Usage: install-capnico.sh <step>
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../env-p3.sh
. "$HERE/../env-p3.sh"
KIND_NODE=${KIND_NODE:-$CP_NODE}
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
ARCHIVE=$W/dl/img/$(echo "$CAPNICO_IMAGE" | tr '/:' '__').tar
KINDS="nicoclusters nicoclustertemplates nicoidentities nicomachines nicomachinetemplates"
# The fake token of the lab. The simulator checks only that the token is not empty.
NICO_TOKEN=${NICO_TOKEN:-example-token}
NICO_ENDPOINT=${NICO_ENDPOINT:-http://$SIM_IP:$SIM_PORT}

apply_secret() {
  export NICO_ENDPOINT NICO_ORG_ID NICO_TOKEN NICO_API_NAME
  # shellcheck disable=SC2016  # the names of the placeholders, not their values
  envsubst '$NICO_ENDPOINT $NICO_ORG_ID $NICO_TOKEN $NICO_API_NAME' <"$HERE/nico-credentials.yaml.tmpl" | nodei "${KC[@]}" apply -f -
  echo "Secret nico-credentials: endpoint $NICO_ENDPOINT, orgID $NICO_ORG_ID, apiName $NICO_API_NAME, token (fake, $(printf '%s' "$NICO_TOKEN" | wc -c) characters)"
}

case "${1:-}" in
  images)
    [ -s "$ARCHIVE" ] || { echo "no archive $ARCHIVE. Copy it from the workstation first (ws-sync.sh images)"; exit 1; }
    docker load -q -i "$ARCHIVE"
    docker image inspect "$CAPNICO_IMAGE" | jq -c --arg t "$CAPNICO_IMAGE" '.[0] | {image: $t, id: .Id[7:19], size: .Size, revision: .Config.Labels["org.opencontainers.image.revision"]}'
    # shellcheck disable=SC2086  # one argument for each node
    "$W/bin/img-load.sh" "$CAPNICO_IMAGE" $NODES
    for n in $NODES; do echo "$n: $(docker exec "$n" crictl inspecti -o json "$CAPNICO_IMAGE" 2>/dev/null | jq -r '.status.id' | cut -c8-19)"; done
    ;;
  install)
    k get crd certificates.cert-manager.io -o name >/dev/null || { echo "no cert-manager in the cluster. The manifest has a Certificate and an Issuer"; exit 1; }
    for n in $NODES; do
      docker exec "$n" crictl inspecti "$CAPNICO_IMAGE" >/dev/null 2>&1 || { echo "the image $CAPNICO_IMAGE is not in $n. Run \"$0 images\" first"; exit 1; }
    done
    [ "$(awk '$1=="image:" {print $2}' "$HERE/capnico.yaml")" = "$CAPNICO_IMAGE" ] || { echo "the image line of capnico.yaml is not $CAPNICO_IMAGE"; exit 1; }
    echo "== $(utc) apply capnico.yaml"
    nodei "${KC[@]}" apply -f - <"$HERE/capnico.yaml" | grep -v -E ' unchanged$' || true
    # shellcheck disable=SC2046  # one argument for each kind
    k wait --for=condition=Established $(for kind in $KINDS; do printf 'crd/%s.infrastructure.cluster.x-k8s.io ' "$kind"; done) --timeout=60s
    k -n "$CAPNICO_NS" rollout status deployment/controller-manager --timeout=180s
    echo "== $(utc) the Secret"
    apply_secret
    "$0" status
    ;;
  secret)
    apply_secret
    ;;
  status)
    for n in $NODES; do echo "image in $n: $(docker exec "$n" crictl inspecti -o json "$CAPNICO_IMAGE" 2>/dev/null | jq -r '.status.id' | cut -c8-19)"; done
    echo "kinds: $(k get crd -o name 2>/dev/null | grep -c -E '/nico[a-z]+\.infrastructure\.cluster\.x-k8s\.io$' || true) of 5"
    k -n "$CAPNICO_NS" get deployment controller-manager -o jsonpath='{"manager: image "}{.spec.template.spec.containers[0].image}{", ready "}{.status.readyReplicas}{", arguments "}{.spec.template.spec.containers[0].args}{"\n"}' 2>&1 | cut -c1-400
    k -n "$CAPNICO_NS" get pods -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName --no-headers 2>&1 | cut -c1-200
    echo "Secret nico-credentials: keys [$(k -n "$CAPNICO_NS" get secret nico-credentials -o json 2>/dev/null | jq -r '.data | keys | join(" ")')], endpoint [$(k -n "$CAPNICO_NS" get secret nico-credentials -o jsonpath='{.data.endpoint}' 2>/dev/null | base64 -d)]"
    echo "webhook: $(k get validatingwebhookconfiguration capnico-validating-webhook-configuration -o json 2>/dev/null | jq -r '[.webhooks[] | "\(.name) caBundle \((.clientConfig.caBundle // "") | length) bytes"] | join("; ")')"
    echo "ClusterRole nvke-controller-nico of the controller chart: $(k get clusterrole nvke-controller-nico -o json 2>/dev/null | jq -c '[.rules[] | {resources, verbs}]' 2>/dev/null || true)"
    echo "its bindings: $(k get clusterrolebinding -o json | jq -r '[.items[] | select(.roleRef.name=="nvke-controller-nico") | "\(.metadata.name) -> \([.subjects[]? | "\(.kind):\(.namespace)/\(.name)"] | join(","))"] | join("; ")')"
    # kubectl auth can-i answers "no" for a kind that the API server does not know. So the lines
    # below are true only after the five kinds are installed.
    echo "rights of the NVKE controller (service account nvke-controller in nvke-controller), in nvke-system:"
    for kind in nicomachines nicoclusters nicomachinetemplates; do
      echo "  $kind: $(for verb in create delete get list patch update watch; do printf '%s=%s ' "$verb" "$(k auth can-i "$verb" "$kind.infrastructure.cluster.x-k8s.io" -n nvke-system --as system:serviceaccount:nvke-controller:nvke-controller 2>&1 | tail -1)"; done)"
    done
    echo "  get the CRD nicomachines: $(k auth can-i get customresourcedefinitions.apiextensions.k8s.io/nicomachines.infrastructure.cluster.x-k8s.io --as system:serviceaccount:nvke-controller:nvke-controller 2>&1 | tail -1)"
    echo "NicoMachine objects: $(k get nicomachines -A -o name 2>/dev/null | grep -c . || true)"
    echo "the manager log:"
    k -n "$CAPNICO_NS" logs deployment/controller-manager --tail=8 2>&1 | cut -c1-240
    ;;
  remove)
    left=$(k get nicomachines,nicoclusters -A -o name 2>/dev/null | tr '\n' ' ')
    [ -z "$left" ] || { echo "objects of CAPNICo exist: $left. Delete the cluster or the pool through the NVKE API first"; exit 1; }
    k -n "$CAPNICO_NS" delete secret nico-credentials --ignore-not-found
    nodei "${KC[@]}" delete --ignore-not-found --wait=true -f - <"$HERE/capnico.yaml"
    ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
