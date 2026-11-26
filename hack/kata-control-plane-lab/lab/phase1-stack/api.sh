#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Call the NVKE API of the lab stack from inside the kind node. No host port and no token.
#
# Use:
#   ./api.sh url                      print the URLs of the API
#   ./api.sh get /api/version
#   ./api.sh get /api/clusters
#   ./api.sh post /api/clusters request.json
#   ./api.sh put /api/clusters/ID request.json
#   ./api.sh patch /api/clusters/ID request.json
#   ./api.sh delete /api/clusters/ID
#
# How it works: curl runs in the kind node with docker exec and calls the ClusterIP of the
# Service nvke-controller on port 8080. The kind node reaches each ClusterIP through kube-proxy.
# The script prints the answer and then one line "HTTP <status code>".
#
# The API has no authentication in this stack (apiAuth.enabled is false, the default of the
# chart and of nvkectl bootstrap). The header X-Managed-By is not necessary
# (MANAGED_BY_K8S_PLATFORM is false, controller/internal/config/config.go:369-370).
#
# The same API from a pod of the cluster:
#   http://nvke-controller.nvke-controller.svc.cluster.local:8080/api/clusters
# The same API through the API server, from the toolbox or the kind node (a GET):
#   kubectl get --raw /api/v1/namespaces/nvke-controller/services/nvke-controller:http/proxy/api/clusters
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

cluster_ip() {
  local ip
  ip="$(node kubectl --kubeconfig /etc/kubernetes/admin.conf -n "$NS_CONTROLLER" get svc "$CONTROLLER_SVC" -o jsonpath='{.spec.clusterIP}')"
  [ -n "$ip" ] || die "no Service ${NS_CONTROLLER}/${CONTROLLER_SVC}"
  printf '%s' "$ip"
}

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

method="${1:-}"
path="${2:-}"
body="${3:-}"

case "$method" in
  url)
    echo "from a pod:       http://${CONTROLLER_SVC}.${NS_CONTROLLER}.svc.cluster.local:${CONTROLLER_PORT}/api"
    echo "from the node:    http://$(cluster_ip):${CONTROLLER_PORT}/api"
    echo "through kubectl:  kubectl get --raw ${CONTROLLER_PROXY}/api/clusters"
    exit 0
    ;;
  get|delete)
    [ -n "$path" ] || { usage; exit 2; }
    base="http://$(cluster_ip):${CONTROLLER_PORT}"
    docker exec "$KIND_NODE" curl -sS --max-time 60 -w '\nHTTP %{http_code}\n' \
      -X "$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')" "${base}${path}" </dev/null
    ;;
  post|put|patch)
    [ -n "$path" ] && [ -n "$body" ] || { usage; exit 2; }
    [ -r "$body" ] || die "no file $body"
    base="http://$(cluster_ip):${CONTROLLER_PORT}"
    docker exec -i "$KIND_NODE" curl -sS --max-time 60 -w '\nHTTP %{http_code}\n' \
      -X "$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')" \
      -H 'Content-Type: application/json' --data-binary @- "${base}${path}" < "$body"
    ;;
  *)
    usage
    exit 2
    ;;
esac
