#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Phase 1 step 7: change of the NVKE controller release in the lab cluster with Helm.
#
# helm runs in a toolbox container on the Docker network of the lab, as the stack scripts do.
# The host opens no connection to the API server and publishes no port. The stack folder is
# mounted read only: this script writes nothing there.
#
# Use:
#   ./ctl.sh history              the revisions of the release nvke-controller
#   ./ctl.sh save-values <name>   the values of the release now, into secrets/ (they hold the database password)
#   ./ctl.sh diff                 helm template of the old and the new values, difference only
#   ./ctl.sh upgrade              helm upgrade with values/controller-values.yaml of this folder
#   ./ctl.sh rollback <revision>  helm rollback to that revision
#   ./ctl.sh status               image, replicas, restarts and /readyz of the controller
#   ./ctl.sh db-column            read-only query: the column control_plane_endpoint and the migration row
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STACK=/scratch/kata-cp/work/phase1-stack
SRC=/scratch/kata-cp/src/nvke-endpoint          # read only, commit c6d669ef. The chart is equal to the chart of bcc4376f
KIND_NODE=kata-cp-control-plane
NS=nvke-controller
RELEASE=nvke-controller
KC=(kubectl --kubeconfig /etc/kubernetes/admin.conf)

node() { docker exec "$KIND_NODE" "$@" </dev/null; }
k() { node "${KC[@]}" "$@"; }

tb() {
  mkdir -p "$HERE/cache/helm"
  docker run --rm --network kata-cp --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e KUBECONFIG=/stack/secrets/kubeconfig.internal \
    -e HELM_CACHE_HOME=/work/cache/helm/cache \
    -e HELM_CONFIG_HOME=/work/cache/helm/config \
    -e HELM_DATA_HOME=/work/cache/helm/data \
    -v "$STACK:/stack:ro" \
    -v "$HERE:/work" \
    -v "$SRC:/src:ro" \
    -v /home/dsrinivas/.local/bin/helm:/usr/local/bin/helm:ro \
    -v /home/dsrinivas/.local/bin/kubectl:/usr/local/bin/kubectl:ro \
    -v /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro \
    -w /work debian:trixie-slim "$@" </dev/null
}

CHART=/src/controller/deploy/charts/controller
NEW_VALUES=(--values /work/values/controller-values.yaml --values /stack/secrets/controller-secret-values.yaml)
OLD_VALUES=(--values /stack/values/controller-values.yaml --values /stack/secrets/controller-secret-values.yaml)

case "${1:-}" in
  history)
    tb helm -n "$NS" history "$RELEASE"
    ;;
  save-values)
    name=${2:?name}
    ( umask 077; tb helm -n "$NS" get values "$RELEASE" -o yaml >"$HERE/secrets/values-$name.yaml" )
    echo "saved secrets/values-$name.yaml ($(wc -l <"$HERE/secrets/values-$name.yaml") lines)"
    grep -nE '^  tag:|^allowControlPlaneWithoutVIP:|^supportedInfraProviders:' "$HERE/secrets/values-$name.yaml"
    ;;
  diff)
    ( umask 077
      tb helm template "$RELEASE" "$CHART" --namespace "$NS" "${OLD_VALUES[@]}" >"$HERE/secrets/template-old.yaml"
      tb helm template "$RELEASE" "$CHART" --namespace "$NS" "${NEW_VALUES[@]}" >"$HERE/secrets/template-new.yaml" )
    # The difference has no secret: only the image and the one setting may differ.
    diff "$HERE/secrets/template-old.yaml" "$HERE/secrets/template-new.yaml" || true
    ;;
  upgrade)
    tb helm upgrade "$RELEASE" "$CHART" --namespace "$NS" "${NEW_VALUES[@]}" --wait --timeout 5m
    ;;
  rollback)
    rev=${2:?revision}
    tb helm -n "$NS" rollback "$RELEASE" "$rev" --wait --timeout 5m
    ;;
  status)
    k -n "$NS" get deployment "$RELEASE" -o jsonpath='{"image="}{.spec.template.spec.containers[0].image}{" replicas="}{.status.replicas}{" ready="}{.status.readyReplicas}{" updated="}{.status.updatedReplicas}{"\n"}'
    k -n "$NS" get pods -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.startTime --no-headers
    k get --raw "/api/v1/namespaces/$NS/services/$RELEASE:http/proxy/readyz"
    echo
    ;;
  db-column)
    # Read only. psql runs in the PostgreSQL pod with the password of the pod environment. No password is printed.
    pod=$(k -n postgres get pods -o jsonpath='{.items[0].metadata.name}')
    k -n postgres exec "$pod" -- sh -c 'PGPASSWORD="${POSTGRES_PASSWORD:-$(cat "${POSTGRES_PASSWORD_FILE:-/dev/null}" 2>/dev/null)}" psql -U postgres -d nvke-controller -At -F " | " -c "SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = '"'"'clusters'"'"' AND column_name IN ('"'"'control_plane_endpoint'"'"', '"'"'control_plane_vip'"'"') ORDER BY column_name" -c "SELECT * FROM bun_migrations ORDER BY id DESC LIMIT 3" -c "SELECT name, control_plane_vip, control_plane_endpoint FROM clusters"'
    ;;
  *)
    sed -n '2,16p' "$0"
    exit 1
    ;;
esac
