#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Remove the phase 1 NVKE stack from the lab cluster kata-cp. The steps are the install steps
# in the opposite order.
#
# Use:
#   ./uninstall.sh list        show the steps
#   ./uninstall.sh NN          run one step, for example ./uninstall.sh 12
#   ./uninstall.sh all         run steps 12 to 07, then show what is left
#   ./uninstall.sh images      also remove the images from the kind node and the two built
#                              images from the Docker store
#   ./uninstall.sh files       also remove cache/, tmp/, secrets/ and the clusterctl program
#   ./uninstall.sh left        show what is left in the cluster. No change
#
# "all" keeps the images and the files, so that a new install needs no download.
#
# The script stops when the cluster has a Cluster API Cluster object. cluster-api-provider-provisioned
# refuses the delete of a Machine that has a host
# (cluster-api-provider-provisioned/controllers/machine_controller.go:103-126), so a delete of
# the kinds would not end. Delete the NVKE cluster first, or set FORCE=1 and remove the
# finalizers by hand.
#
# The script does not touch: the namespaces gate4, gate1-nvke-spire, metallb-system,
# local-path-storage and kube-system, the Kata install, and the kind node container.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

STEPS="12 11 10 09 08 07"

step_title() {
  case "$1" in
    12) echo "remove the NVKE controller, the namespaces ${NS_CONTROLLER} and ${NS_NVKE_SYSTEM}, and the three release kinds" ;;
    11) echo "remove cluster-api-provider-provisioned and its four kinds" ;;
    10) echo "remove Cluster API core with clusterctl delete, then cert-manager" ;;
    09) echo "remove the NodePort Service, SPIRE, the SPIRE CRDs and the namespace ${NS_SPIRE}" ;;
    08) echo "remove Temporal and the namespace ${NS_TEMPORAL}" ;;
    07) echo "remove PostgreSQL, its volume and the namespace ${NS_POSTGRES}" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Toolbox parts
# ---------------------------------------------------------------------------------------------

release_exists() { helm status "$1" --namespace "$2" >/dev/null 2>&1; }

delete_namespace() {
  if kubectl get namespace "$1" >/dev/null 2>&1; then
    log "delete the namespace $1"
    kubectl delete namespace "$1" --timeout=300s || warn "the namespace $1 is not gone after 300 s. Look for objects with finalizers"
  fi
}

# Stop when the cluster has a Cluster object.
guard() {
  local n
  if ! kubectl get crd clusters.cluster.x-k8s.io >/dev/null 2>&1; then
    return 0
  fi
  n="$(kubectl get clusters.cluster.x-k8s.io -A --no-headers 2>/dev/null | wc -l)"
  if [ "$n" != "0" ]; then
    kubectl get clusters.cluster.x-k8s.io,machines.cluster.x-k8s.io -A 2>/dev/null || true
    [ "${FORCE:-0}" = "1" ] || die "the cluster has $n Cluster API Cluster objects. Delete the NVKE cluster first, or set FORCE=1"
    warn "FORCE=1: continue with $n Cluster objects"
  fi
}

inner_12() {
  guard
  if release_exists nvke-controller "$NS_CONTROLLER"; then
    helm uninstall nvke-controller --namespace "$NS_CONTROLLER" --wait --timeout 5m
  fi
  delete_namespace "$NS_CONTROLLER"
  # The chart keeps this namespace and the release kinds at an uninstall
  # (helm.sh/resource-policy: keep, templates/nvke-rbac.yaml and templates/crds.yaml).
  delete_namespace "$NS_NVKE_SYSTEM"
  kubectl delete crd machineimages.internal.nvke.nvidia.com clusterreleases.internal.nvke.nvidia.com \
    nodepoolreleases.internal.nvke.nvidia.com --ignore-not-found --timeout=120s
}

inner_11() {
  guard
  local f="$STACK_DIR/manifests/provisioned-provider.yaml"
  [ -s "$f" ] || die "no $f"
  kubectl delete -f "$f" --ignore-not-found --timeout=300s
}

inner_10() {
  guard
  if kubectl -n capi-system get deployment capi-controller-manager >/dev/null 2>&1; then
    command -v clusterctl >/dev/null || die "clusterctl is not in the toolbox"
    clusterctl delete --kubeconfig "$KUBECONFIG" --all --include-crd --include-namespace
  fi
  local ns
  for ns in $NS_CAPI_ALL; do
    delete_namespace "$ns"
  done
  # clusterctl delete keeps cert-manager. The lab cluster had no cert-manager before the
  # stack, so each object with this label is from clusterctl init. (The label is from the
  # clusterctl program, not from the NVKE source.)
  local sel="clusterctl.cluster.x-k8s.io/core=cert-manager"
  kubectl delete mutatingwebhookconfiguration,validatingwebhookconfiguration -l "$sel" --ignore-not-found
  delete_namespace "$NS_CERT_MANAGER"
  kubectl delete clusterrole,clusterrolebinding -l "$sel" --ignore-not-found
  kubectl -n kube-system delete role,rolebinding -l "$sel" --ignore-not-found
  kubectl delete crd -l "$sel" --ignore-not-found --timeout=120s
}

inner_09() {
  kubectl -n "$NS_SPIRE" delete service spire-server-external --ignore-not-found
  if release_exists spire "$NS_SPIRE"; then
    helm uninstall spire --namespace "$NS_SPIRE" --wait --timeout 10m
  fi
  if release_exists spire-crds "$NS_SPIRE"; then
    helm uninstall spire-crds --namespace "$NS_SPIRE" --wait --timeout 5m
  fi
  local crds
  crds="$(kubectl get crd -o name 2>/dev/null | grep -E '\.spire\.spiffe\.io$' || true)"
  if [ -n "$crds" ]; then
    # shellcheck disable=SC2086
    kubectl delete $crds --timeout=120s
  fi
  delete_namespace "$NS_SPIRE"
  kubectl delete csidriver csi.spiffe.io --ignore-not-found
}

inner_08() {
  if release_exists temporal "$NS_TEMPORAL"; then
    helm uninstall temporal --namespace "$NS_TEMPORAL" --wait --timeout 10m
  fi
  delete_namespace "$NS_TEMPORAL"
}

inner_07() {
  if release_exists postgres "$NS_POSTGRES"; then
    helm uninstall postgres --namespace "$NS_POSTGRES" --wait --timeout 5m
  fi
  # The volume claim goes with the namespace. local-path then deletes the data.
  delete_namespace "$NS_POSTGRES"
}

# Show what is left. No change.
inner_left() {
  local ns found=0 out
  for ns in $STACK_NAMESPACES phase1-probe; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
      echo "namespace: $ns"
      found=1
    fi
  done
  out="$(kubectl get crd -o name 2>/dev/null | grep -E 'cluster\.x-k8s\.io|spire\.spiffe\.io|cert-manager\.io|internal\.nvke\.nvidia\.com' || true)"
  if [ -n "$out" ]; then echo "$out"; found=1; fi
  out="$(kubectl get clusterrole,clusterrolebinding -o name 2>/dev/null | grep -E 'nvke-controller|provisioned|capi-|cert-manager|spire' || true)"
  if [ -n "$out" ]; then echo "$out"; found=1; fi
  out="$(kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration -o name 2>/dev/null | grep -vE 'metallb|frr-k8s' || true)"
  if [ -n "$out" ]; then echo "$out"; found=1; fi
  out="$(kubectl get csidriver -o name 2>/dev/null || true)"
  if [ -n "$out" ]; then echo "$out"; found=1; fi
  out="$(kubectl get pv --no-headers 2>/dev/null | grep -E "${NS_POSTGRES}/|${NS_SPIRE}/" || true)"
  if [ -n "$out" ]; then echo "$out"; found=1; fi
  if [ "$found" = "0" ]; then
    log "nothing of the stack is left in the cluster"
  else
    warn "the objects above are left"
  fi
  log "the namespaces of the cluster now:"
  kubectl get namespace --no-headers -o custom-columns=NAME:.metadata.name | tr '\n' ' '
  echo
}

# ---------------------------------------------------------------------------------------------
# Host parts
# ---------------------------------------------------------------------------------------------

prepare_host() {
  make_dirs
  [ -s "$STACK_DIR/secrets/kubeconfig.internal" ] || make_kubeconfig
}

run_step() {
  local n="$1" logfile rc
  step_title "$n" >/dev/null || die "no step $n. Use: $0 list"
  prepare_host
  logfile="$LOG_DIR/uninstall-${n}-$(date +%Y%m%d-%H%M%S).log"
  log "=== uninstall step $n: $(step_title "$n")" | tee -a "$logfile"
  set +e
  ( set -e; tb bash /work/uninstall.sh --inner "$n" ) 2>&1 | tee -a "$logfile"
  rc="${PIPESTATUS[0]}"
  set -e
  if [ "$rc" = "0" ]; then
    progress "uninstall $n" PASS "$(step_title "$n") (log $logfile)"
    log "=== uninstall step $n: PASS"
  else
    progress "uninstall $n" FAIL "$(grep -v '^[[:space:]]*$' "$logfile" | tail -n 1 | cut -c1-300) (exit code $rc, log $logfile)"
    log "=== uninstall step $n: FAIL, exit code $rc"
    exit "$rc"
  fi
}

remove_images() {
  local img
  if [ -s "$STACK_DIR/cache/images.txt" ]; then
    while read -r img; do
      [ -n "$img" ] || continue
      if node crictl rmi "$img" >/dev/null 2>&1; then
        log "removed from the kind node: $img"
      fi
    done < "$STACK_DIR/cache/images.txt"
  fi
  for img in "$CONTROLLER_IMAGE" "$PROVISIONED_IMAGE"; do
    if node crictl rmi "$img" >/dev/null 2>&1; then
      log "removed from the kind node: $img"
    fi
  done
  for img in "$CONTROLLER_IMAGE_LOCAL" "$PROVISIONED_IMAGE_LOCAL"; do
    if docker rmi "$img" >/dev/null 2>&1; then
      log "removed from the Docker store: $img"
    fi
  done
  log "not removed: the images that clusterctl init made the kind node pull (cert-manager, Cluster API), the base images of the builds in the Docker store, and the build cache"
}

remove_files() {
  rm -rf "$STACK_DIR/cache" "$STACK_DIR/tmp" "$STACK_DIR/secrets"
  rm -f "$CLUSTERCTL_BIN"
  log "removed cache/, tmp/, secrets/ and $CLUSTERCTL_BIN. The logs in $LOG_DIR stay"
}

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local n
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
      prepare_host
      tb bash /work/uninstall.sh --inner left
      ;;
    left)
      prepare_host
      tb bash /work/uninstall.sh --inner left
      ;;
    images)
      remove_images
      ;;
    files)
      remove_files
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
