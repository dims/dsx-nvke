#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Check the phase 1 NVKE stack in the lab cluster kata-cp.
#
# Use:
#   ./check.sh                    all checks
#   SKIP_KATA_PROBE=1 ./check.sh  no probe pod with the Kata class
#
# The script reads the cluster. Its only change is the namespace phase1-probe with two short
# probe pods, which it deletes at the end. The probe pods open one TLS connection each to the
# SPIRE server, at the address that NVKE writes into agent.conf.
#
# Each line starts with PASS, FAIL, WARN or INFO. The exit code is 0 when no line is FAIL.
# The kubectl calls run in the toolbox container, not on the host.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

PASS=0
FAIL=0
WARN=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
soft() { WARN=$((WARN + 1)); printf 'WARN  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }
head1() { printf '\n== %s\n' "$*"; }

# check TEXT CMD ARG...: PASS when the command works.
check() {
  local text="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$text"; else bad "$text"; fi
}

# has TEXT NEEDLE HAYSTACK: PASS when the text has the needle.
# A shell pattern, not a pipe into grep -q: with pipefail, grep -q ends at the first match,
# printf then gets a broken pipe on a long text, and the test would be false.
has() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (did not find: $2)" ;;
  esac
}

# deployments_available NAMESPACE: true when each Deployment of the namespace has all replicas.
deployments_available() {
  local lines
  lines="$(kubectl -n "$1" get deployment -o jsonpath='{range .items[*]}{.metadata.name} {.spec.replicas} {.status.availableReplicas}{"\n"}{end}' 2>/dev/null)" || return 1
  [ -n "$lines" ] || return 1
  printf '%s\n' "$lines" | awk '$2 != $3 { bad = 1 } END { exit bad }'
}

crd_established() {
  [ "$(kubectl get crd "$1" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)" = "True" ]
}

# ---------------------------------------------------------------------------------------------
# The probe pod: one TLS connection to the SPIRE server from a pod.
# ---------------------------------------------------------------------------------------------

probe() {
  local name="$1" class="$2" f="$STACK_DIR/tmp/$1.yaml" phase="" i out
  {
    printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n' "$name" "$NS_PROBE"
    printf '  restartPolicy: Never\n  automountServiceAccountToken: false\n  enableServiceLinks: false\n'
    printf '  terminationGracePeriodSeconds: 5\n'
    if [ -n "$class" ]; then
      printf '  runtimeClassName: %s\n' "$class"
    fi
    printf '  containers:\n    - name: probe\n      image: %s\n      imagePullPolicy: Never\n' "$PROBE_IMAGE"
    printf '      env:\n        - name: ADDR\n          value: "%s"\n        - name: PORT\n          value: "%s"\n' "$SPIRE_AGENT_ADDRESS" "$SPIRE_AGENT_PORT"
    printf '      command:\n        - /bin/sh\n        - -c\n        - |\n'
    printf '          san=$(timeout 20 openssl s_client -connect "$ADDR:$PORT" </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d " \\n")\n'
    printf '          if [ -n "$san" ]; then echo "PROBE_OK $san"; else echo "PROBE_FAIL no certificate from $ADDR:$PORT"; exit 1; fi\n'
    printf '      resources:\n        requests:\n          cpu: 100m\n          memory: 128Mi\n        limits:\n          memory: 512Mi\n'
  } > "$f"
  kubectl -n "$NS_PROBE" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  if ! kubectl apply -f "$f" >/dev/null 2>&1; then
    bad "probe pod $name: the API server did not accept the pod"
    return
  fi
  for i in $(seq 1 60); do
    phase="$(kubectl -n "$NS_PROBE" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 3
  done
  out="$(kubectl -n "$NS_PROBE" logs "$name" 2>/dev/null | tail -n 3)"
  if [ "$phase" = "Succeeded" ] && printf '%s' "$out" | grep -q "PROBE_OK.*spiffe://${TRUST_DOMAIN}/spire/server"; then
    ok "probe pod $name (${class:-runc}) reaches the SPIRE server at ${SPIRE_AGENT_ADDRESS}:${SPIRE_AGENT_PORT}: $out"
  else
    bad "probe pod $name (${class:-runc}), phase ${phase:-none}: ${out:-no output}"
    kubectl -n "$NS_PROBE" describe pod "$name" 2>/dev/null | tail -n 12
  fi
  kubectl -n "$NS_PROBE" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
}

# ---------------------------------------------------------------------------------------------
# The checks. They run in the toolbox.
# ---------------------------------------------------------------------------------------------

inner_check() {
  local out cfg ns crd q tns img n

  head1 "1. The cluster"
  check "the API server answers at https://${KIND_NODE}:6443" kubectl get --raw /readyz
  out="$(kubectl get node -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)"
  has "the node is Ready" " True" "$out"
  # The other lab parts, read only. The test namespaces of other agents (gate4, phase1-cni,
  # phase1-dry) come and go, so the check gives only INFO lines for them and never a FAIL.
  for ns in gate1-nvke-spire metallb-system kube-system; do
    out="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed"' | wc -l)"
    n="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l)"
    if [ "$out" = "0" ]; then info "namespace $ns of the lab: $n pods, all run"; else soft "namespace $ns of the lab: $out of $n pods do not run"; fi
  done
  info "other namespaces now: $(kubectl get namespace --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep -vE "^(default|kube-.*|local-path-storage|metallb-system|gate1-nvke-spire|${NS_PROBE}|$(printf '%s' "$STACK_NAMESPACES" | tr ' ' '|'))\$" | tr '\n' ' ')"

  head1 "2. PostgreSQL"
  check "the Deployment in $NS_POSTGRES is available" deployments_available "$NS_POSTGRES"
  check "pg_isready answers" kubectl -n "$NS_POSTGRES" exec deploy/postgres-postgresql -- pg_isready -U postgres
  out="$(kubectl -n "$NS_POSTGRES" exec deploy/postgres-postgresql -- psql -U postgres -Atc 'select datname from pg_database' 2>/dev/null)"
  has "the database nvke-controller exists" "nvke-controller" "$out"
  has "the database temporal exists" "temporal" "$out"
  has "the database temporal_visibility exists" "temporal_visibility" "$out"
  out="$(kubectl -n "$NS_POSTGRES" get pvc -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' 2>/dev/null)"
  has "the PostgreSQL volume is bound" "=Bound" "$out"

  head1 "3. Temporal"
  check "each Deployment in $NS_TEMPORAL is available" deployments_available "$NS_TEMPORAL"
  check "the Service temporal-frontend exists" kubectl -n "$NS_TEMPORAL" get svc temporal-frontend
  if out="$(kubectl -n "$NS_TEMPORAL" exec deploy/temporal-admintools -- temporal operator cluster health --address temporal-frontend:7233 2>&1)"; then
    ok "temporal operator cluster health: $(printf '%s' "$out" | tr '\n' ' ')"
  else
    soft "temporal operator cluster health did not run: $(printf '%s' "$out" | tail -n 1)"
  fi

  head1 "4. SPIRE"
  out="$(kubectl -n "$NS_SPIRE" get statefulset -l app.kubernetes.io/name=server -o jsonpath='{range .items[*]}{.metadata.name} {.spec.replicas} {.status.readyReplicas}{"\n"}{end}' 2>/dev/null)"
  if [ -n "$out" ] && printf '%s\n' "$out" | awk '$2 != $3 { bad = 1 } END { exit bad }'; then ok "the SPIRE server is ready: $out"; else bad "the SPIRE server is not ready: ${out:-no StatefulSet}"; fi
  out="$(kubectl -n "$NS_SPIRE" get daemonset -o jsonpath='{range .items[*]}{.metadata.name} {.status.desiredNumberScheduled} {.status.numberReady}{"\n"}{end}' 2>/dev/null)"
  if [ -n "$out" ] && printf '%s\n' "$out" | awk '$2 != $3 { bad = 1 } END { exit bad }'; then ok "the SPIRE agent and the CSI driver are ready: $(printf '%s' "$out" | tr '\n' ';')"; else bad "a DaemonSet in $NS_SPIRE is not ready: $(printf '%s' "$out" | tr '\n' ';')"; fi
  # The chart has no Deployment. The SPIRE controller manager is a container of the server pod.
  out="$(kubectl -n "$NS_SPIRE" get pod spire-server-0 -o jsonpath='{range .status.containerStatuses[*]}{.name}={.ready} {end}' 2>/dev/null)"
  has "the SPIRE controller manager container is ready: $out" "spire-controller-manager=true" "$out"
  check "the CSI driver csi.spiffe.io is registered" kubectl get csidriver csi.spiffe.io
  for crd in clusterspiffeids.spire.spiffe.io clusterstaticentries.spire.spiffe.io; do
    check "the kind $crd exists" crd_established "$crd"
  done
  # The form of controller/Tiltfile:958.
  check "spire-server healthcheck" kubectl -n "$NS_SPIRE" exec spire-server-0 -c spire-server -- bin/spire-server healthcheck
  out="$(kubectl -n "$NS_SPIRE" exec spire-server-0 -c spire-server -- bin/spire-server bundle show -format spiffe 2>/dev/null | head -c 200)"
  if [ -n "$out" ]; then ok "the SPIRE server has a trust bundle"; else soft "could not read the trust bundle"; fi
  out="$(kubectl -n "$NS_SPIRE" get configmap -o yaml 2>/dev/null)"
  has "the trust domain of the SPIRE server is $TRUST_DOMAIN" "$TRUST_DOMAIN" "$out"
  has "the class of the SPIRE controller manager is spire-mgmt-spire" "spire-mgmt-spire" "$out"
  has "the controller ID is an admin ID of the SPIRE server" "spiffe://${TRUST_DOMAIN}/nvke-service/${CONTROLLER_SVC}" "$out"
  info "node attestors in the SPIRE server configuration: $(printf '%s' "$out" | grep -oE '"(join_token|k8s_psat|tpm|x509pop)"' | sort -u | tr '\n' ' ')"
  out="$(kubectl -n "$NS_SPIRE" get svc spire-server -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)"
  has "the Service spire-server has the port 8081 (join token API of the controller)" "8081" "$out"
  out="$(kubectl -n "$NS_SPIRE" get svc spire-server-external -o jsonpath='{.spec.type} {.spec.ports[*].nodePort}' 2>/dev/null)"
  has "the Service spire-server-external has the NodePort $SPIRE_AGENT_PORT" "NodePort $SPIRE_AGENT_PORT" "$out"
  out="$(kubectl -n "$NS_SPIRE" get endpointslices -l kubernetes.io/service-name=spire-server-external -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null)"
  if [ -n "$out" ]; then ok "spire-server-external has an endpoint: $out"; else bad "spire-server-external has no endpoint (the selector does not match the server pod)"; fi

  head1 "5. SPIRE from a pod, at the address of agent.conf (${SPIRE_AGENT_ADDRESS}:${SPIRE_AGENT_PORT})"
  mkdir -p "$STACK_DIR/tmp"
  kubectl create namespace "$NS_PROBE" >/dev/null 2>&1
  probe spire-probe-runc ""
  if [ "${SKIP_KATA_PROBE:-0}" = "1" ]; then
    info "no Kata probe (SKIP_KATA_PROBE=1)"
  elif kubectl get runtimeclass "$PROBE_RUNTIME_CLASS" >/dev/null 2>&1; then
    probe spire-probe-kata "$PROBE_RUNTIME_CLASS"
  else
    soft "no RuntimeClass $PROBE_RUNTIME_CLASS, no Kata probe"
  fi
  kubectl delete namespace "$NS_PROBE" --wait=false >/dev/null 2>&1

  head1 "6. Cluster API core and cert-manager"
  for ns in $NS_CERT_MANAGER $NS_CAPI_ALL; do
    check "each Deployment in $ns is available" deployments_available "$ns"
  done
  for crd in clusters.cluster.x-k8s.io machines.cluster.x-k8s.io kubeadmconfigs.bootstrap.cluster.x-k8s.io kubeadmcontrolplanes.controlplane.cluster.x-k8s.io; do
    check "the kind $crd exists" crd_established "$crd"
  done
  info "Cluster API images: $(kubectl get deployment -A -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null | grep -E 'cluster-api|cert-manager' | sort -u | tr '\n' ' ')"

  head1 "7. cluster-api-provider-provisioned"
  for crd in provisionedclusters provisionedmachines provisionedmachinetemplates provisionedhostclaims; do
    check "the kind ${crd}.infrastructure.cluster.x-k8s.io exists" crd_established "${crd}.infrastructure.cluster.x-k8s.io"
  done
  check "the Deployment in $NS_PROVISIONED is available" deployments_available "$NS_PROVISIONED"
  img="$(kubectl -n "$NS_PROVISIONED" get deployment provisioned-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  has "the provider runs the image of the lab" "$PROVISIONED_IMAGE" "$img"

  head1 "8. The NVKE controller: API and worker"
  check "the Deployment in $NS_CONTROLLER is available" deployments_available "$NS_CONTROLLER"
  img="$(kubectl -n "$NS_CONTROLLER" get deployment "$CONTROLLER_SVC" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  has "the controller runs the image of the lab" "$CONTROLLER_IMAGE" "$img"
  out="$(kubectl get --raw "${CONTROLLER_PROXY}/readyz" 2>&1)"
  has "/readyz says ok (database and Temporal): $out" '"status":"ok"' "$out"
  out="$(kubectl get --raw "${CONTROLLER_PROXY}/api/version" 2>&1)"
  has "/api/version answers: $out" '"version"' "$out"
  tns="$(printf '%s' "$out" | sed -n 's/.*"temporalNamespace":"\([^"]*\)".*/\1/p')"
  if out="$(kubectl get --raw "${CONTROLLER_PROXY}/api/clusters" 2>&1)"; then
    ok "GET /api/clusters answers with no token: $(printf '%s' "$out" | head -c 120)"
  else
    bad "GET /api/clusters: $(printf '%s' "$out" | head -c 200)"
  fi
  out="$(kubectl -n "$NS_CONTROLLER" logs "deployment/${CONTROLLER_SVC}" --tail=-1 2>/dev/null)"
  has "the log has: Starting Temporal worker (controller/cmd/worker/main.go:738)" "Starting Temporal worker" "$out"
  has "the log has: Starting HTTP server (main.go:717)" "Starting HTTP server" "$out"
  has "the controller has its SPIFFE identity, trust domain $TRUST_DOMAIN (main.go:864)" "$TRUST_DOMAIN" "$(printf '%s' "$out" | grep -F 'SPIFFE trust domain')"
  out="$(kubectl -n "$NS_SPIRE" exec spire-server-0 -c spire-server -- bin/spire-server entry show -spiffeID "spiffe://${TRUST_DOMAIN}/nvke-service/${CONTROLLER_SVC}" 2>&1)"
  has "the SPIRE server has an entry for the controller ID" "spiffe://${TRUST_DOMAIN}/nvke-service/${CONTROLLER_SVC}" "$out"
  cfg="$(kubectl -n "$NS_CONTROLLER" get configmap nvke-controller-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null)"
  q="$(printf '%s\n' "$cfg" | sed -n 's/^ *taskQueue: *"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -n "$tns" ] && [ -n "$q" ] && out="$(kubectl -n "$NS_TEMPORAL" exec deploy/temporal-admintools -- temporal task-queue describe --namespace "$tns" --task-queue "$q" --address temporal-frontend:7233 2>&1)"; then
    if printf '%s' "$out" | grep -qiE 'workflow|activity'; then
      ok "Temporal has pollers on the task queue $q of the namespace $tns"
    else
      soft "Temporal shows no poller on the task queue $q of the namespace $tns: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
    fi
  else
    soft "could not ask Temporal for the pollers of the task queue ${q:-unknown} in the namespace ${tns:-unknown}"
  fi

  head1 "9. The settings of the phase 1 design"
  has "supportedInfraProviders has infra" '- "infra"' "$(printf '%s\n' "$cfg" | grep -A3 'supportedInfraProviders:')"
  has "allowControlPlaneWithoutVIP is true" "allowControlPlaneWithoutVIP: true" "$cfg"
  has "cni.installAfterInit is true" "installCNIAfterInit: true" "$cfg"
  has "spiffe.enabled is true" "spiffeEnabled: true" "$cfg"
  has "nodeAgent.spireAttestationMethod is joinToken" 'spireAttestationMethod: "joinToken"' "$cfg"
  has "the SPIRE port for agent.conf is $SPIRE_AGENT_PORT" "serverPort: \"${SPIRE_AGENT_PORT}\"" "$cfg"
  has "the NICo controllers are off" "nicoControllersEnabled: false" "$cfg"
  has "API authentication is off (no token)" "enabled: false" "$(printf '%s\n' "$cfg" | grep -A1 '^ *apiAuth:')"
  out="$(kubectl -n "$NS_CONTROLLER" get deployment "$CONTROLLER_SVC" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SPIRE_SERVER_ADDRESS")].value}' 2>/dev/null)"
  if [ "$out" = "$SPIRE_AGENT_ADDRESS" ]; then ok "the SPIRE address for agent.conf is $out"; else bad "SPIRE_SERVER_ADDRESS is '${out}', not $SPIRE_AGENT_ADDRESS"; fi
  out="$(kubectl -n "$NS_CONTROLLER" get deployment "$CONTROLLER_SVC" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SPIRE_SERVER_API_ADDRESS")].value}' 2>/dev/null)"
  if [ "$out" = "$SPIRE_API_ADDRESS" ]; then ok "the SPIRE API address for join tokens is $out"; else bad "SPIRE_SERVER_API_ADDRESS is '${out}', not $SPIRE_API_ADDRESS"; fi
  check "capi.rbac.create: the ClusterRole ${CONTROLLER_SVC}-capi exists" kubectl get clusterrole "${CONTROLLER_SVC}-capi"
  for crd in provisionedclusters.infrastructure.cluster.x-k8s.io machines.cluster.x-k8s.io clusterstaticentries.spire.spiffe.io; do
    out="$(kubectl auth can-i create "$crd" -n "$NS_NVKE_SYSTEM" --as "system:serviceaccount:${NS_CONTROLLER}:${CONTROLLER_SVC}" 2>/dev/null)"
    if [ "$out" = "yes" ]; then ok "the controller can create $crd"; else bad "the controller cannot create $crd"; fi
  done
  out="$(kubectl -n "$NS_CONTROLLER" get pods -l "app.kubernetes.io/name=${CONTROLLER_SVC}" -o jsonpath='{range .items[*]}{.metadata.name} ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount} config={.metadata.annotations.checksum/controller-config}{"\n"}{end}' 2>/dev/null)"
  info "controller pod: $out"

  head1 "10. What the stack adds next to the other lab parts"
  out="$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}={.status.loadBalancer.ingress[*].ip}{"\n"}{end}' 2>/dev/null)"
  n=0
  for ns in $STACK_NAMESPACES; do
    if printf '%s\n' "$out" | grep -q "^${ns}/"; then n=$((n + 1)); fi
  done
  if [ "$n" = "0" ]; then ok "the stack has no LoadBalancer Service, so it uses no MetalLB address"; else soft "the stack has LoadBalancer Services in $n namespaces"; fi
  info "LoadBalancer Services of the cluster: $(printf '%s' "$out" | tr '\n' ' ')"
  out="$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="NodePort")]}{.metadata.namespace}/{.metadata.name}={.spec.ports[*].nodePort}{"\n"}{end}' 2>/dev/null)"
  if [ "$(printf '%s\n' "$out" | grep -c .)" = "1" ] && printf '%s' "$out" | grep -q "^${NS_SPIRE}/spire-server-external=${SPIRE_AGENT_PORT}\$"; then
    ok "the only NodePort Service is ${NS_SPIRE}/spire-server-external with ${SPIRE_AGENT_PORT}"
  else
    soft "NodePort Services of the cluster: $(printf '%s' "$out" | tr '\n' ' ')"
  fi
  info "volumes of the stack: $(kubectl get pvc -A --no-headers 2>/dev/null | awk '{ print $1 "/" $2 "=" $3 }' | tr '\n' ' ')"

  head1 "Result"
  printf 'PASS %s, FAIL %s, WARN %s\n' "$PASS" "$FAIL" "$WARN"
  [ "$FAIL" = "0" ]
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

if [ "${1:-}" = "--inner" ]; then
  in_toolbox || die "--inner is for the toolbox"
  inner_check
  exit $?
fi

make_dirs
[ -s "$STACK_DIR/secrets/kubeconfig.internal" ] || make_kubeconfig
defender_check

head1 "0. The host and the kind node"
if [ "$(docker inspect -f '{{.State.Running}}' "$KIND_NODE" 2>/dev/null)" = "true" ]; then ok "the kind node runs"; else bad "the kind node does not run"; fi
info "published ports of the kind node: $(docker port "$KIND_NODE" 2>/dev/null | tr '\n' ' ')"
for img in "$CONTROLLER_IMAGE" "$PROVISIONED_IMAGE"; do
  if node crictl inspecti "$img" >/dev/null 2>&1; then ok "the kind node has the image $img"; else bad "the kind node does not have the image $img"; fi
done
host_fail="$FAIL"

tb bash /work/check.sh --inner
rc=$?
if [ "$rc" != "0" ] || [ "$host_fail" != "0" ]; then
  exit 1
fi
exit 0
