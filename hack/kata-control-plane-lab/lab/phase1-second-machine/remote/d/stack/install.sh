#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Install the phase 1 NVKE stack into the lab cluster kata-cp: PostgreSQL, Temporal, SPIRE,
# Cluster API core, cluster-api-provider-provisioned and the NVKE controller.
#
# The order and the values follow cli/internal/bootstrap/controllerdeploy/controllerdeploy.go
# and capi.go of NVKE at bcc4376f (the recipe with no Tilt). The lab settings are in values/.
#
# Use:
#   ./install.sh list          show the steps
#   ./install.sh NN            run one step, for example ./install.sh 07
#   ./install.sh from NN       run step NN and each step after it
#   ./install.sh all           run each step in order
#
# Each step can run again. A step stops at its first error.
#
# Where a step runs:
#   host      Docker commands and one download with curl. No kubectl and no helm on the host.
#   toolbox   helm, kubectl and clusterctl in a container on the Docker network kata-cp.
#             Each API call stays on the bridge. The toolbox has no published port.
#   node      docker exec in the kind node, for image imports and image pulls.
#
# Lab rules that this script keeps: each download and each pull runs alone, no host port,
# no change to the Docker configuration, no change to the kind node container, no kernel module.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

STEPS="00 01 02 03 04 05 06 07 08 09 10 11 12 13"

step_title() {
  case "$1" in
    00) echo "preflight: read the host and the cluster, write the toolbox kubeconfig and the secret values. No change in the cluster" ;;
    01) echo "host: download clusterctl ${CAPI_VERSION} to ${CLUSTERCTL_BIN} (one curl call)" ;;
    02) echo "toolbox: download three charts with helm pull, one at a time" ;;
    03) echo "host: build the controller image ${CONTROLLER_IMAGE_LOCAL} from the source" ;;
    04) echo "host: build the provider image ${PROVISIONED_IMAGE_LOCAL} from the source" ;;
    05) echo "node: import the two images into the kind node" ;;
    06) echo "node: pull the chart images into the kind node, one at a time" ;;
    07) echo "toolbox: install PostgreSQL (namespace ${NS_POSTGRES})" ;;
    08) echo "toolbox: install Temporal (namespace ${NS_TEMPORAL})" ;;
    09) echo "toolbox: install the SPIRE CRDs, SPIRE and the NodePort Service (namespace ${NS_SPIRE})" ;;
    10) echo "toolbox: install Cluster API core and cert-manager with clusterctl init" ;;
    11) echo "toolbox: install cluster-api-provider-provisioned (namespace ${NS_PROVISIONED})" ;;
    12) echo "toolbox: install the NVKE controller (namespaces ${NS_CONTROLLER} and ${NS_NVKE_SYSTEM})" ;;
    13) echo "check: run check.sh" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Helm arguments. The install and the image list use the same arguments.
# ---------------------------------------------------------------------------------------------

set_postgres_args() {
  HELM_ARGS=(postgres "$NVKE_SRC/controller/deploy/charts/postgresql"
    --namespace "$NS_POSTGRES"
    --values "$STACK_DIR/values/postgres-values.yaml"
    --values "$STACK_DIR/secrets/postgres-secret-values.yaml")
}

set_temporal_args() {
  local tgz="$STACK_DIR/cache/charts/temporal-${TEMPORAL_CHART_VERSION}.tgz"
  [ -s "$tgz" ] || die "no $tgz, run step 02"
  HELM_ARGS=(temporal "$tgz"
    --namespace "$NS_TEMPORAL"
    --values "$STACK_DIR/values/temporal-values.yaml"
    --values "$STACK_DIR/secrets/temporal-secret-values.yaml")
}

set_spire_args() {
  local tgz="$STACK_DIR/cache/charts/spire-${SPIRE_CHART_VERSION}.tgz"
  [ -s "$tgz" ] || die "no $tgz, run step 02"
  HELM_ARGS=(spire "$tgz"
    --namespace "$NS_SPIRE"
    --values "$STACK_DIR/values/spire-values.yaml")
  # The join token is the attestation method of phase 1. Chart versions that have the value
  # nodeAttestor.joinToken get it. Without the value the SPIRE server still accepts a join
  # token: the Tilt values have no such value, and the CAPD lane uses join tokens with them
  # (controller/Makefile:311, controller/deploy/helm-values/spire.yaml).
  # grep -c, not grep -q: with pipefail, grep -q ends at the first match, tar then gets a
  # broken pipe, and the test is false. That was the fault of the first run of step 09 on
  # 2026-11-26, which installed SPIRE without this value.
  local n
  n="$(tar -xzOf "$tgz" spire/charts/spire-server/values.yaml 2>/dev/null | grep -cE '^[[:space:]]+joinToken:' || true)"
  if [ "${n:-0}" -gt 0 ]; then
    HELM_ARGS+=(--set spire-server.nodeAttestor.joinToken.enabled=true)
  fi
}

set_controller_args() {
  HELM_ARGS=(nvke-controller "$NVKE_SRC/controller/deploy/charts/controller"
    --namespace "$NS_CONTROLLER"
    --values "$STACK_DIR/values/controller-values.yaml"
    --values "$STACK_DIR/secrets/controller-secret-values.yaml")
}

# ---------------------------------------------------------------------------------------------
# Host parts
# ---------------------------------------------------------------------------------------------

prepare_host() {
  in_toolbox && return 0
  make_dirs
  [ -s "$STACK_DIR/secrets/kubeconfig.internal" ] || make_kubeconfig
  make_secret_values
}

check_pins() {
  local mk="$NVKE_SRC/make/tool-versions.mk"
  local bm="$NVKE_SRC/cli/internal/bootstrap/manifest/bootstrap-manifest.yaml"
  grep -qE "^CAPI_VERSION[[:space:]]*\?=[[:space:]]*${CAPI_VERSION}\$" "$mk" || die "CAPI_VERSION differs from $mk"
  grep -qE "^CLUSTERCTL_SHA256_AMD64[[:space:]]*\?=[[:space:]]*${CLUSTERCTL_SHA256}\$" "$mk" || die "CLUSTERCTL_SHA256 differs from $mk"
  local s
  for s in "$TEMPORAL_CHART_SHA256" "$SPIRE_CRDS_CHART_SHA256" "$SPIRE_CHART_SHA256"; do
    grep -q "sha256: ${s}\$" "$bm" || die "chart digest $s is not in $bm"
  done
  for s in "$TEMPORAL_CHART_VERSION" "$SPIRE_CRDS_CHART_VERSION" "$SPIRE_CHART_VERSION"; do
    grep -q "version: \"${s}\"\$" "$bm" || die "chart version $s is not in $bm"
  done
  grep -q "$PROVISIONED_PLACEHOLDER_IMAGE" "$NVKE_SRC/$PROVISIONED_MANIFEST_SRC" || die "the provider manifest of the source has no placeholder image"
}

check_values() {
  local v="$STACK_DIR/values" m="$STACK_DIR/manifests"
  grep -q "trustDomain: ${TRUST_DOMAIN}\$" "$v/spire-values.yaml" || die "trust domain differs in spire-values.yaml"
  grep -q "spiffe://${TRUST_DOMAIN}/nvke-service/${CONTROLLER_SVC}\$" "$v/spire-values.yaml" || die "admin ID differs in spire-values.yaml"
  grep -q "clusterName: ${SPIRE_CLUSTER_NAME}\$" "$v/spire-values.yaml" || die "cluster name differs in spire-values.yaml"
  grep -q "trustDomain: ${TRUST_DOMAIN}\$" "$v/controller-values.yaml" || die "trust domain differs in controller-values.yaml"
  grep -q "serverAddress: \"${SPIRE_AGENT_ADDRESS}\"\$" "$v/controller-values.yaml" || die "SPIRE address differs in controller-values.yaml"
  grep -q "serverPort: \"${SPIRE_AGENT_PORT}\"\$" "$v/controller-values.yaml" || die "SPIRE port differs in controller-values.yaml"
  grep -q "value: ${SPIRE_API_ADDRESS}\$" "$v/controller-values.yaml" || die "SPIRE API address differs in controller-values.yaml"
  grep -q "tag: ${NVKE_COMMIT}\$" "$v/controller-values.yaml" || die "image tag differs in controller-values.yaml"
  grep -q "nodePort: ${SPIRE_AGENT_PORT}\$" "$m/spire-server-external.yaml" || die "NodePort differs in spire-server-external.yaml"
}

step_00() {
  local b ip head f
  for b in docker git sha256sum curl; do
    command -v "$b" >/dev/null || die "the host has no $b"
  done
  for b in "$HELM_BIN" "$KUBECTL_BIN"; do
    [ -x "$b" ] || die "no program $b"
  done
  [ -r "$CA_BUNDLE" ] || die "no CA bundle $CA_BUNDLE"
  docker network inspect "$DOCKER_NET" >/dev/null 2>&1 || die "no Docker network $DOCKER_NET"
  [ "$(docker inspect -f '{{.State.Running}}' "$KIND_NODE" 2>/dev/null)" = "true" ] || die "the kind node $KIND_NODE does not run"
  ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$DOCKER_NET\").IPAddress}}" "$KIND_NODE")"
  [ "$ip" = "$NODE_IP" ] || die "the kind node has the address $ip, the files have $NODE_IP"
  # The source here is a copy of a few files of the commit c6d669ef, with no git folder.
  check_pins
  check_values
  defender_check
  for f in "$STACK_DIR"/*.sh; do
    bash -n "$f" || die "syntax error in $f"
  done
  make_dirs
  make_kubeconfig
  make_secret_values
  log "host: ok. Docker root: $(docker info --format '{{.DockerRootDir}}'), free: $(df -h --output=avail "$(docker info --format '{{.DockerRootDir}}')" | tail -1 | tr -d ' ')"
  tb bash /work/install.sh --inner preflight
}

step_01() {
  if sha256_ok "$CLUSTERCTL_BIN" "$CLUSTERCTL_SHA256"; then
    log "clusterctl is present with the correct digest"
    return 0
  fi
  mkdir -p "$(dirname "$CLUSTERCTL_BIN")"
  log "download $CLUSTERCTL_URL"
  # One call, no retry. The form is controller/Makefile.dev:587-589.
  curl -fsSL --max-time 600 -o "$CLUSTERCTL_BIN.tmp" "$CLUSTERCTL_URL"
  if ! sha256_ok "$CLUSTERCTL_BIN.tmp" "$CLUSTERCTL_SHA256"; then
    rm -f "$CLUSTERCTL_BIN.tmp"
    die "the download does not have the digest of make/tool-versions.mk:119"
  fi
  chmod 755 "$CLUSTERCTL_BIN.tmp"
  mv "$CLUSTERCTL_BIN.tmp" "$CLUSTERCTL_BIN"
  # The program does not run on the host. Step 10 runs it in the toolbox.
  log "clusterctl is in $CLUSTERCTL_BIN"
}

step_02() { tb bash /work/install.sh --inner fetch_charts; }

# The *_IMAGE arguments of a Dockerfile, one "NAME VALUE" line for each default.
image_args() {
  awk '/^ARG [A-Z_]+_IMAGE=/ { s = $0; sub(/^ARG /, "", s); i = index(s, "="); print substr(s, 1, i - 1), substr(s, i + 1) }' "$1"
}

# The literal FROM images of a Dockerfile (no argument in the name).
literal_from_images() {
  awk '/^FROM [a-z0-9.]+\// && $2 !~ /\$/ { print $2 }' "$1"
}

# Pull one base image alone, so that the build itself pulls nothing.
pull_base_image() {
  if docker image inspect "$1" >/dev/null 2>&1; then
    log "base image is present: $1"
  else
    log "pull base image: $1"
    docker pull "$1" </dev/null
  fi
}

build_image() {
  local dockerfile="$1" tag="$2" build_version git_version name value ref img t0
  local -a build_args=()
  t0="$(date +%s)"
  # The version strings as controller/Makefile:47-55 makes them.
  build_version="$(git -C "$NVKE_SRC" --no-optional-locks describe --tags --always --dirty --match 'v*')"
  git_version="$(git -C "$NVKE_SRC" rev-parse --short=8 HEAD)"
  # A base image of Docker Hub comes from the mirror, with the digest of the Dockerfile
  # (controller/Dockerfile:13-16 names this use of the *_IMAGE arguments).
  while read -r name value; do
    [ -n "$name" ] || continue
    ref="$(mirror_ref "$value")"
    pull_base_image "$ref"
    if [ "$ref" != "$value" ]; then
      build_args+=(--build-arg "${name}=${ref}")
    fi
  done < <(image_args "$dockerfile")
  while read -r img; do
    [ -n "$img" ] || continue
    pull_base_image "$img"
  done < <(literal_from_images "$dockerfile")
  log "build $tag (BUILD_VERSION=$build_version GIT_VERSION=$git_version ${build_args[*]})"
  # The context is the root of the source, as controller/Makefile:388-401 and cli/Makefile:228-230
  # do. The build reads the tree and writes nothing into it. The builder "default" keeps the
  # image in the local Docker store.
  DOCKER_BUILDKIT=1 docker build --builder default \
    --file "$dockerfile" --platform linux/amd64 --provenance=false --progress=plain \
    --build-arg "BUILD_VERSION=$build_version" --build-arg "GIT_VERSION=$git_version" \
    "${build_args[@]}" \
    --tag "$tag" "$NVKE_SRC" </dev/null
  fact "built $tag, $(docker image inspect -f '{{.Id}}' "$tag" | cut -c1-19), $(docker image inspect -f '{{.Size}}' "$tag" | awk '{ printf "%.0f MB", $1 / 1000000 }'), $(( $(date +%s) - t0 )) s"
}

step_03() { docker image inspect "$CONTROLLER_IMAGE_LOCAL" >/dev/null || die "no image $CONTROLLER_IMAGE_LOCAL (it comes from the workstation, no build here)"; fact "$CONTROLLER_IMAGE_LOCAL is in the Docker store of the machine (copied from the workstation)"; }

step_04() { docker image inspect "$PROVISIONED_IMAGE_LOCAL" >/dev/null || die "no image $PROVISIONED_IMAGE_LOCAL (it comes from the workstation, no build here)"; fact "$PROVISIONED_IMAGE_LOCAL is in the Docker store of the machine (copied from the workstation)"; }

step_05() {
  local img
  for img in "$CONTROLLER_IMAGE_LOCAL" "$PROVISIONED_IMAGE_LOCAL" nvke-lab-bootstrap-helper:dev; do
    docker image inspect "$img" >/dev/null 2>&1 || die "no image $img"
    log "load $img into each kind node"
    /root/kata-cp/bin/img-load.sh "$img"
  done
  for img in "$CONTROLLER_IMAGE" "$PROVISIONED_IMAGE"; do
    node crictl inspecti "$img" >/dev/null 2>&1 || die "the kind node does not have $img after the import"
    log "the kind node has $img"
  done
  fact "each kind node has $CONTROLLER_IMAGE, $PROVISIONED_IMAGE and the helper image"
}

step_06() {
  local img n=0
  tb bash /work/install.sh --inner image_list
  # A kind node cannot pull here. The machine pulls each image and each node imports it (d/stack-image.sh).
  # The Cluster API and cert-manager images are not in the chart list, so they are named here.
  for img in $(cat "$STACK_DIR/cache/images.txt") \
    quay.io/jetstack/cert-manager-cainjector:v1.21.1 quay.io/jetstack/cert-manager-controller:v1.21.1 quay.io/jetstack/cert-manager-webhook:v1.21.1 \
    registry.k8s.io/cluster-api/cluster-api-controller:v1.13.6 registry.k8s.io/cluster-api/kubeadm-bootstrap-controller:v1.13.6 \
    registry.k8s.io/cluster-api/kubeadm-control-plane-controller:v1.13.6; do
    case "$img" in
      *nvke-controller:*|*cluster-api-provider-provisioned:*) continue ;;
    esac
    /root/kata-cp/d/stack-image.sh "$img" || { fact "the load of $img did not work"; die "the load of $img did not work"; }
    n=$((n + 1))
  done
  fact "$n images in each kind node, list in cache/images.txt plus 6 of Cluster API and cert-manager"
}

step_07() { tb bash /work/install.sh --inner postgres; }
step_08() { tb bash /work/install.sh --inner temporal; }
step_09() { tb bash /work/install.sh --inner spire; }
step_10() {
  [ -x "$CLUSTERCTL_BIN" ] || die "no $CLUSTERCTL_BIN, run step 01"
  tb bash /work/install.sh --inner capi
}
step_11() { tb bash /work/install.sh --inner provisioned; }
step_12() { tb bash /work/install.sh --inner controller; }
step_13() { "$HERE/check.sh"; }

# ---------------------------------------------------------------------------------------------
# Toolbox parts
# ---------------------------------------------------------------------------------------------

inner_preflight() {
  local ns owner sc
  log "toolbox: helm $(helm version --short 2>/dev/null), kubectl $(kubectl version --client 2>/dev/null | head -n1)"
  kubectl get --raw /readyz >/dev/null || die "the API server does not answer at https://${KIND_NODE}:6443"
  kubectl get nodes -o wide
  for ns in $STACK_NAMESPACES; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
      log "the namespace $ns exists (from a run before)"
    fi
  done
  owner="$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.ports[*].nodePort}{"\n"}{end}' \
    | awk -v p="$SPIRE_AGENT_PORT" '{ for (i = 2; i <= NF; i++) if ($i == p) print $1 }')"
  case "$owner" in
    ""|"$NS_SPIRE/spire-server-external") ;;
    *) die "the NodePort $SPIRE_AGENT_PORT belongs to $owner" ;;
  esac
  sc="$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')"
  [ -n "$sc" ] || die "the cluster has no default StorageClass. PostgreSQL and the SPIRE server need one"
  log "default StorageClass: $sc"
  kubectl get runtimeclass "$PROBE_RUNTIME_CLASS" >/dev/null 2>&1 || warn "no RuntimeClass $PROBE_RUNTIME_CLASS, check.sh cannot run its Kata probe"
  log "node resources now:"
  kubectl describe node | sed -n '/Allocated resources/,/Events/p' | sed -n '4,7p'
  log "toolbox: ok"
  fact "host and toolbox ok, the API server answers at https://${KIND_NODE}:6443, NodePort ${SPIRE_AGENT_PORT} is free or ours, default StorageClass $sc"
}

pull_chart() {
  local name="$1" repo="$2" version="$3" sha="$4"
  local f="$STACK_DIR/cache/charts/${name}-${version}.tgz"
  if sha256_ok "$f" "$sha"; then
    log "chart is present: $f"
    return 0
  fi
  if [ -s "$f" ] && [ "${ALLOW_CHART_SHA_MISMATCH:-0}" = "1" ]; then
    warn "chart $f is present with another digest, kept because ALLOW_CHART_SHA_MISMATCH=1"
    return 0
  fi
  rm -f "$f"
  log "helm pull $name $version from $repo"
  # One call for one chart, as controller/Tiltfile:585 does for Temporal.
  helm pull "$name" --repo "$repo" --version "$version" --destination "$STACK_DIR/cache/charts"
  if ! sha256_ok "$f" "$sha"; then
    warn "$f has the digest $(sha256sum "$f" | cut -d' ' -f1), bootstrap-manifest.yaml has $sha"
    fact "chart ${name}-${version}: the download has $(sha256sum "$f" | cut -d' ' -f1), bootstrap-manifest.yaml has $sha"
    [ "${ALLOW_CHART_SHA_MISMATCH:-0}" = "1" ] || die "stop. The chart digest differs"
  fi
}

inner_fetch_charts() {
  mkdir -p "$STACK_DIR/cache/charts"
  pull_chart temporal "$TEMPORAL_CHART_REPO" "$TEMPORAL_CHART_VERSION" "$TEMPORAL_CHART_SHA256"
  pull_chart spire-crds "$SPIRE_CHART_REPO" "$SPIRE_CRDS_CHART_VERSION" "$SPIRE_CRDS_CHART_SHA256"
  pull_chart spire "$SPIRE_CHART_REPO" "$SPIRE_CHART_VERSION" "$SPIRE_CHART_SHA256"
  ls -l "$STACK_DIR/cache/charts"
  fact "charts temporal ${TEMPORAL_CHART_VERSION}, spire-crds ${SPIRE_CRDS_CHART_VERSION}, spire ${SPIRE_CHART_VERSION} are in cache/charts, digests as in bootstrap-manifest.yaml"
}

# Write cache/images.txt: each image that the four charts name. It needs no cluster.
inner_image_list() {
  local chart tmp
  tmp="$(mktemp)"
  for chart in postgres temporal spire controller; do
    "set_${chart}_args"
    helm template "${HELM_ARGS[@]}" --skip-tests \
      | awk '$1 == "image:" { v = $2 } $1 == "-" && $2 == "image:" { v = $3 }
             v != "" { gsub(/"/, "", v); gsub(/\047/, "", v); print v; v = "" }' >> "$tmp"
  done
  sort -u "$tmp" > "$STACK_DIR/cache/images.txt"
  rm -f "$tmp"
  log "images of the charts ($(wc -l < "$STACK_DIR/cache/images.txt")):"
  cat "$STACK_DIR/cache/images.txt"
}

inner_postgres() {
  set_postgres_args
  # controllerdeploy.go:569-578
  helm upgrade --install "${HELM_ARGS[@]}" --create-namespace --wait --timeout 10m
  kubectl -n "$NS_POSTGRES" get deployment,pvc,svc
  fact "helm release postgres is deployed, pods: $(kubectl -n "$NS_POSTGRES" get pods --no-headers | awk '{ print $1 "=" $3 }' | tr '\n' ' ')"
}

inner_temporal() {
  set_temporal_args
  # controllerdeploy.go:625-637
  helm upgrade --install "${HELM_ARGS[@]}" --create-namespace --wait --timeout 15m
  inner_temporal_wait
}

# helm --wait ends as soon as each Deployment is available one time. The Temporal server pods
# have no readiness probe, and they exit and start again until the schema job is done (first
# run on 2026-11-26: helm ended after 1 s, the servers were up after 46 s with 2 to 3 restarts).
# So wait for the real state: the schema job is complete, the frontend says SERVING, and no
# container starts again during 20 s.
inner_temporal_wait() {
  local i out="" d before after
  kubectl -n "$NS_TEMPORAL" wait --for=condition=complete job --all --timeout=300s
  for d in $(kubectl -n "$NS_TEMPORAL" get deployment -o name); do
    kubectl -n "$NS_TEMPORAL" rollout status "$d" --timeout=300s
  done
  for i in $(seq 1 30); do
    if out="$(kubectl -n "$NS_TEMPORAL" exec deploy/temporal-admintools -- temporal operator cluster health --address temporal-frontend:7233 2>&1)" \
      && printf '%s' "$out" | grep -q SERVING; then
      before="$(kubectl -n "$NS_TEMPORAL" get pods -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {end}')"
      sleep 20
      after="$(kubectl -n "$NS_TEMPORAL" get pods -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {end}')"
      if [ "$before" = "$after" ] && deployments_ready "$NS_TEMPORAL"; then
        kubectl -n "$NS_TEMPORAL" get deployment,job,svc
        fact "helm release temporal is deployed, schema job complete, frontend health SERVING, $(kubectl -n "$NS_TEMPORAL" get deployment --no-headers | wc -l) Deployments ready, restarts: $after"
        return 0
      fi
    fi
    sleep 10
  done
  kubectl -n "$NS_TEMPORAL" get pods
  die "Temporal is not stable after the wait. Last health answer: $out"
}

# deployments_ready NAMESPACE: true when each Deployment of the namespace has all replicas ready.
deployments_ready() {
  kubectl -n "$1" get deployment -o jsonpath='{range .items[*]}{.metadata.name} {.spec.replicas} {.status.readyReplicas}{"\n"}{end}' \
    | awk 'NF < 3 || $2 != $3 { bad = 1 } END { exit bad }'
}

inner_spire() {
  local crds="$STACK_DIR/cache/charts/spire-crds-${SPIRE_CRDS_CHART_VERSION}.tgz"
  [ -s "$crds" ] || die "no $crds, run step 02"
  # controllerdeploy.go:644-654
  helm upgrade --install spire-crds "$crds" --namespace "$NS_SPIRE" --create-namespace --wait --timeout 10m
  set_spire_args
  log "helm arguments for SPIRE: ${HELM_ARGS[*]}"
  # controllerdeploy.go:664-671
  helm upgrade --install "${HELM_ARGS[@]}" --create-namespace --wait --timeout 15m
  # controllerdeploy.go:1372-1392, with the lab manifest
  kubectl apply -f "$STACK_DIR/manifests/spire-server-external.yaml"
  # Do not trust helm --wait alone (see inner_temporal_wait): wait for each workload.
  local w
  for w in $(kubectl -n "$NS_SPIRE" get statefulset,daemonset,deployment -o name); do
    kubectl -n "$NS_SPIRE" rollout status "$w" --timeout=300s
  done
  kubectl -n "$NS_SPIRE" exec spire-server-0 -c spire-server -- bin/spire-server healthcheck
  kubectl -n "$NS_SPIRE" get statefulset,daemonset,deployment,svc
  fact "helm releases spire-crds and spire are deployed, NodePort ${SPIRE_AGENT_PORT} is set, pods: $(kubectl -n "$NS_SPIRE" get pods --no-headers | awk '{ print $1 "=" $2 }' | tr '\n' ' ')"
}

inner_capi() {
  local d
  command -v clusterctl >/dev/null || die "clusterctl is not in the toolbox, run step 01"
  # capi.go:331-351. clusterctl refuses a second init, so look first.
  if kubectl -n capi-system get deployment capi-controller-manager >/dev/null 2>&1; then
    log "Cluster API core is installed already"
  else
    clusterctl init --kubeconfig "$KUBECONFIG" \
      --core "cluster-api:${CAPI_VERSION}" \
      --bootstrap "kubeadm:${CAPI_VERSION}" \
      --control-plane "kubeadm:${CAPI_VERSION}" \
      --wait-providers --wait-provider-timeout 900
  fi
  # controller/Makefile.dev:616-621
  for d in cert-manager/cert-manager cert-manager/cert-manager-webhook cert-manager/cert-manager-cainjector \
           capi-system/capi-controller-manager \
           capi-kubeadm-bootstrap-system/capi-kubeadm-bootstrap-controller-manager \
           capi-kubeadm-control-plane-system/capi-kubeadm-control-plane-controller-manager; do
    kubectl -n "${d%%/*}" rollout status "deployment/${d##*/}" --timeout=300s
  done
  fact "Cluster API ${CAPI_VERSION} (core, kubeadm bootstrap, kubeadm control plane) and cert-manager are ready"
}

inner_provisioned() {
  local src="$NVKE_SRC/$PROVISIONED_MANIFEST_SRC" out="$STACK_DIR/manifests/provisioned-provider.yaml"
  # capi.go:372-382: the manifest of the source with the image of the lab.
  grep -q "$PROVISIONED_PLACEHOLDER_IMAGE" "$src" || die "$src has no placeholder image"
  sed "s#${PROVISIONED_PLACEHOLDER_IMAGE}#${PROVISIONED_IMAGE}#" "$src" > "$out.tmp"
  mv "$out.tmp" "$out"
  # capi.go:390-402
  kubectl apply --server-side --force-conflicts -f "$out"
  kubectl -n "$NS_PROVISIONED" rollout status deployment/provisioned-controller-manager --timeout=300s
  fact "cluster-api-provider-provisioned runs with $PROVISIONED_IMAGE, 4 kinds applied"
}

inner_controller() {
  local i out=""
  kubectl -n capi-system get deployment capi-controller-manager >/dev/null 2>&1 \
    || die "Cluster API is not installed. The controller exits without the Machine kind (controller/cmd/worker/main.go:328-336). Run step 10"
  kubectl get namespace "$NS_SPIRE" >/dev/null 2>&1 || die "no namespace $NS_SPIRE. Run step 09"
  set_controller_args
  # controllerdeploy.go:724-777
  helm upgrade --install "${HELM_ARGS[@]}" --create-namespace --wait --timeout 10m
  # controllerdeploy.go:983-1017: /readyz through the service proxy of the API server.
  for i in $(seq 1 60); do
    if out="$(kubectl get --raw "${CONTROLLER_PROXY}/readyz" 2>/dev/null)" && printf '%s' "$out" | grep -q '"status":"ok"'; then
      log "the controller is ready: $out"
      fact "helm release nvke-controller is deployed, /readyz: $(printf '%s' "$out" | tr -d '\n')"
      return 0
    fi
    sleep 5
  done
  die "the controller did not answer ok on /readyz in 5 minutes. Last answer: $out"
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

# Run one step with its own log. Write one line into progress.txt: time, step, PASS or FAIL,
# the main fact and the duration.
run_step() {
  local n="$1" logfile rc t0 text
  step_title "$n" >/dev/null || die "no step $n. Use: $0 list"
  prepare_host
  logfile="$LOG_DIR/install-${n}-$(date +%Y%m%d-%H%M%S).log"
  rm -f "$STACK_DIR/tmp/fact.txt"
  t0="$(date +%s)"
  log "=== step $n: $(step_title "$n")" | tee -a "$logfile"
  set +e
  ( set -e; "step_${n}" ) 2>&1 | tee -a "$logfile"
  rc="${PIPESTATUS[0]}"
  set -e
  if [ -s "$STACK_DIR/tmp/fact.txt" ]; then
    text="$(head -n 1 "$STACK_DIR/tmp/fact.txt")"
  else
    text="$(grep -v '^[[:space:]]*$' "$logfile" | tail -n 1 | cut -c1-300)"
  fi
  if [ "$rc" = "0" ]; then
    progress "install $n" PASS "$text ($(( $(date +%s) - t0 )) s, log $logfile)"
    log "=== step $n: PASS (log: $logfile)" | tee -a "$logfile"
  else
    progress "install $n" FAIL "$text (exit code $rc, $(( $(date +%s) - t0 )) s, log $logfile)"
    log "=== step $n: FAIL, exit code $rc (log: $logfile)" | tee -a "$logfile"
    exit "$rc"
  fi
}

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local n started=0
  case "${1:-}" in
    --inner)
      in_toolbox || die "--inner is for the toolbox"
      shift
      "inner_$1"
      ;;
    list)
      for n in $STEPS; do
        printf '%s  %s\n' "$n" "$(step_title "$n")"
      done
      ;;
    all)
      for n in $STEPS; do
        run_step "$n"
      done
      ;;
    from)
      [ -n "${2:-}" ] || die "use: $0 from NN"
      step_title "$2" >/dev/null || die "no step $2"
      for n in $STEPS; do
        if [ "$n" = "$2" ]; then
          started=1
        fi
        if [ "$started" = "1" ]; then
          run_step "$n"
        fi
      done
      ;;
    [0-9][0-9])
      run_step "$1"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
