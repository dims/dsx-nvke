#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Install cluster-api-provider-podvm in the lab cluster and give the NVKE controller the rights
# for its three kinds. The image must be in the kind nodes already (the nodes cannot pull).
# Usage: install.sh        (prints what it checks)
set -euo pipefail
. /root/kata-cp/bin/env.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
KIND_NODE=${KIND_NODE:-kata-bb-control-plane}
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
node() { docker exec "$KIND_NODE" "$@"; }
nodei() { docker exec -i "$KIND_NODE" "$@"; }
k() { node "${KC[@]}" "$@"; }
IMG=$(awk '$1=="image:" && $2 ~ /cluster-api-provider-podvm/ {print $2}' "$HERE/install/infrastructure-components.yaml")
echo "== image of the manifest: $IMG"
for n in $NODES; do echo "$n: $(docker exec "$n" crictl inspecti -o json "$IMG" 2>/dev/null | jq -r '.status.id' | cut -c8-19)"; done
echo "== apply infrastructure-components.yaml and nvke-controller-rbac.yaml"
nodei "${KC[@]}" apply -f - <"$HERE/install/infrastructure-components.yaml"
nodei "${KC[@]}" apply -f - <"$HERE/install/nvke-controller-rbac.yaml"
k -n podvm-system rollout status deployment/podvm-controller-manager --timeout=180s
k -n podvm-system get pods -o wide
echo "== the three kinds"
k get crd -o name | grep podvm
k wait --for=condition=Established crd/podvmclusters.infrastructure.cluster.x-k8s.io crd/podvmmachines.infrastructure.cluster.x-k8s.io crd/podvmmachinetemplates.infrastructure.cluster.x-k8s.io --timeout=60s
echo "== leader election"
k -n podvm-system get deployment podvm-controller-manager -o jsonpath='{"args: "}{.spec.template.spec.containers[0].args}{"\n"}'
for i in $(seq 1 30); do [ -n "$(k -n podvm-system get lease -o name 2>/dev/null)" ] && break; sleep 2; done
k -n podvm-system get lease -o custom-columns=NAME:.metadata.name,HOLDER:.spec.holderIdentity,ACQUIRED:.spec.acquireTime,RENEWED:.spec.renewTime
echo "== rights of the NVKE controller (service account nvke-controller in nvke-controller) in nvke-system"
for kind in podvmclusters podvmmachines podvmmachinetemplates; do
  echo "$kind: $(for verb in create delete get list patch watch; do printf '%s=%s ' "$verb" "$(k auth can-i "$verb" "$kind.infrastructure.cluster.x-k8s.io" -n nvke-system --as system:serviceaccount:nvke-controller:nvke-controller 2>&1 | tail -1)"; done)"
done
echo "get the CRD: $(k auth can-i get customresourcedefinitions.apiextensions.k8s.io/podvmmachines.infrastructure.cluster.x-k8s.io --as system:serviceaccount:nvke-controller:nvke-controller 2>&1 | tail -1)"
echo "== the manager log"
k -n podvm-system logs deployment/podvm-controller-manager --tail=30 | cut -c1-260
