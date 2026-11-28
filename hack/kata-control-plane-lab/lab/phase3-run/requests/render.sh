#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Render the requests of phase 3 for the NVKE API from the templates of this folder. It sends
# nothing. It needs envsubst and jq, and it runs on the machine and on the workstation.
#
#   cluster <out folder> [workers]    cluster-request.json: the request of phase 2 (a PodVMCluster,
#                                     three control plane nodes from a PodVMMachineTemplate, the
#                                     shared address) plus ONE node pool whose template is a
#                                     NicoMachineTemplate with siteID and the IDs of the simulator
#   pool <out folder> <cluster ID> [workers]   pool-request.json: the same pool for a cluster
#                                     that exists (POST /api/nodePools)
#   scale <out folder> <count>        pool-scale-<count>.json: {"desiredNodeCount": <count>}
#   calls                             print the API calls that use the files
#
# The first pre-kubeadm command of the pool is a wait for the control socket of systemd (at most
# 120 s). The container backend of the simulator starts the simulated cloud-init commands right
# after "docker start". NVKE adds "systemctl restart nke-agent.service" as the last command, and
# on a fast machine that command ran 0.09 s before systemd was up (run a-1 of 2026-11-27). The
# status file then says "error" for good, and the NodePreflight activity of NVKE never passes.
# The wait prints how long it waited into the output file of the simulated cloud-init.
#
# Settings (environment), with the values of the lab:
#   CLUSTER_NAME kata-cp1, IP_API 172.29.255.220, POD_CIDR 10.113.0.0/16, SERVICE_CIDR 10.112.0.0/16,
#   NS d, RUNTIME_CLASS kata-clh-runtime-rs-fix-direct-ovs, RANGE_CIDR 172.28.1.0/24, K8S_VERSION 1.36.4,
#   NODE_IMAGE_REF docker.io/library/nvke-node-podvm:bcc4376f-p10, CPU 2, MEMORY 6Gi, SC podvm-local-block,
#   POOL_NAME nico-workers, POOL_PREFIX nw
# The five IDs are the ones of the container site of the seed file of the simulator
# (controller/nico-sim/internal/seed/default-seed.yaml:16-19, :28-31, :38-41, :53-55, :104-107).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export CLUSTER_NAME=${CLUSTER_NAME:-kata-cp1}
export IP_API=${IP_API:-172.29.255.220}
export POD_CIDR=${POD_CIDR:-10.113.0.0/16} SERVICE_CIDR=${SERVICE_CIDR:-10.112.0.0/16}
export NS=${NS:-d}
export RUNTIME_CLASS=${RUNTIME_CLASS:-kata-clh-runtime-rs-fix-direct-ovs}
export RANGE_CIDR=${RANGE_CIDR:-172.28.1.0/24}
export K8S_VERSION=${K8S_VERSION:-1.36.4}
export NODE_IMAGE_REF=${NODE_IMAGE_REF:-docker.io/library/nvke-node-podvm:bcc4376f-p10}
export CPU=${CPU:-2} MEMORY=${MEMORY:-6Gi} SC=${SC:-podvm-local-block}
export POOL_NAME=${POOL_NAME:-nico-workers} POOL_PREFIX=${POOL_PREFIX:-nw}
export NICO_SITE_ID=${NICO_SITE_ID:-00000000-0000-0000-0000-000000000001}
export NICO_VPC_ID=${NICO_VPC_ID:-00000000-0000-0000-0000-000000000002}
export NICO_SUBNET_ID=${NICO_SUBNET_ID:-00000000-0000-0000-0000-000000000003}
export NICO_SSH_KEY_GROUP_ID=${NICO_SSH_KEY_GROUP_ID:-00000000-0000-0000-0000-000000000004}
export NICO_INSTANCE_TYPE_ID=${NICO_INSTANCE_TYPE_ID:-00000000-0000-0000-0000-000000000005}

# shellcheck disable=SC2016  # the names of the placeholders, not their values
templates() {
  PODVM_MACHINE_TEMPLATE=$(envsubst '$NODE_IMAGE_REF $CPU $MEMORY $SC' <"$HERE/podvm-machine-template.json.tmpl")
  NICO_MACHINE_TEMPLATE=$(envsubst '$CLUSTER_NAME $POOL_NAME $NICO_SITE_ID $NICO_VPC_ID $NICO_SUBNET_ID $NICO_SSH_KEY_GROUP_ID $NICO_INSTANCE_TYPE_ID' <"$HERE/nico-machine-template.json.tmpl")
  export PODVM_MACHINE_TEMPLATE NICO_MACHINE_TEMPLATE
}
number() { case "$1" in "" | *[!0-9]*) echo "[$1] is not a count"; exit 1 ;; esac; }
# The facts of a rendered request, as one line.
facts() {
  jq -c '{name, endpoint: .controlPlaneEndpoint, cluster: .infra.cluster.kind, controlPlane: "\(.controlPlaneConfig.desiredCount) x \(.controlPlaneConfig.infra.machineTemplate.kind)",
    pools: [.nodePools[]? | "\(.name): \(.desiredNodeCount) x \(.infra.machineTemplate.kind), siteID \(.infra.machineTemplate.spec.template.spec.siteID)"]}' "$1"
}

case "${1:-}" in
  cluster)
    out=${2:?out folder}
    export WORKER_COUNT=${3:-1}
    number "$WORKER_COUNT"
    mkdir -p "$out"
    templates
    # shellcheck disable=SC2016
    envsubst '$CLUSTER_NAME $K8S_VERSION $IP_API $POD_CIDR $SERVICE_CIDR $NS $RUNTIME_CLASS $RANGE_CIDR $POOL_NAME $POOL_PREFIX $WORKER_COUNT $PODVM_MACHINE_TEMPLATE $NICO_MACHINE_TEMPLATE' <"$HERE/cluster-request.json.tmpl" >"$out/cluster-request.json"
    jq -e . "$out/cluster-request.json" >/dev/null || { echo "the request is not JSON"; exit 1; }
    echo "$out/cluster-request.json: $(facts "$out/cluster-request.json")"
    ;;
  pool)
    out=${2:?out folder}
    export CLUSTER_ID=${3:?the cluster ID of NVKE}
    export WORKER_COUNT=${4:-1}
    number "$WORKER_COUNT"
    mkdir -p "$out"
    templates
    # shellcheck disable=SC2016
    envsubst '$CLUSTER_ID $POOL_NAME $POOL_PREFIX $WORKER_COUNT $NICO_MACHINE_TEMPLATE' <"$HERE/pool-request.json.tmpl" >"$out/pool-request.json"
    jq -e . "$out/pool-request.json" >/dev/null || { echo "the request is not JSON"; exit 1; }
    echo "$out/pool-request.json: $(jq -c '{clusterID, name, nodeNamePrefix, desiredNodeCount, template: .infra.machineTemplate.kind, siteID: .infra.machineTemplate.spec.template.spec.siteID}' "$out/pool-request.json")"
    ;;
  scale)
    out=${2:?out folder}
    number "${3:?count}"
    mkdir -p "$out"
    printf '{"desiredNodeCount": %s}\n' "$3" >"$out/pool-scale-$3.json"
    echo "$out/pool-scale-$3.json: $(cat "$out/pool-scale-$3.json")"
    ;;
  calls)
    cat <<'CALLS'
A = /root/kata-cp/d/stack/api.sh (it prints the answer and one line "HTTP <code>")
make the mixed cluster:        A post /api/clusters <out>/cluster-request.json
the node pools of the cluster: A get "/api/nodePools?clusterID=<cluster ID>"
the nodes of the cluster:      A get "/api/nodes?clusterID=<cluster ID>"
a pool for a cluster that exists:   A post /api/nodePools <out>/pool-request.json
add a worker (count N to N+1):      A patch /api/nodePools/<pool ID> <out>/pool-scale-<N+1>.json
remove a worker, two calls:         A patch /api/nodePools/<pool ID> <out>/pool-scale-<N-1>.json
                                    A delete /api/nodes/<node ID>
remove the pool with its workers:   A delete /api/nodePools/<pool ID>
delete the cluster:                 A delete /api/clusters/<cluster ID>
CALLS
    ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
