#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Bring up a kind host cluster that can run the control plane nodes of a tenant
# cluster as Kata pods, through cluster-api-provider-podvm. A site brings its
# own Kata, node network, load balancer and block storage; this is the same
# set for one machine with Docker and KVM. README.md has the whole run.
#
# Usage:
#   ./up.sh              # every step below, in this order
#   ./up.sh STEP...      # only the steps named
#
#   host       load the kernel modules of Kata, raise the inotify limit
#   network    the Docker network of the node network
#   cluster    the kind cluster
#   nodes      in each kind node: D-Bus, loop device nodes, the bridge of the
#              node network, the CNI plugins bridge and static
#   multus     Multus, and the pod namespace with its network attachment
#   kata       Kata Containers with the runtime class kata-podvm
#   metallb    MetalLB with a pool on the node network
#   storage    loop devices and the local static provisioner in block mode
#
# Not in the default run:
#   sim        start the NICo simulator, with its workers on the node network
#   env        print the settings that deploy-stack.sh needs for this cluster
#
# Every step can run again. Nothing here survives a restart of the machine or
# of a kind node: run the script again after one.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-podvm}"
STATE_DIR="${PODVM_KIND_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/podvm-kind}"
# The directory with vmlinux and kata-containers.img, which README.md builds.
KATA_GUEST_DIR="${KATA_GUEST_DIR:-${STATE_DIR}/kata-guest}"
POD_NAMESPACE="${POD_NAMESPACE:-podvm-clusters}"
# Volume places on each kind worker. One machine of the provider takes one
# place: a volume of 20G and one of 8G. Two leave room to replace a node.
PLACES_PER_NODE="${PLACES_PER_NODE:-2}"

KATA_VERSION="${KATA_VERSION:-4.4.0}"
METALLB_VERSION="${METALLB_VERSION:-0.16.2}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.3.2}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.10.0}"
LOCAL_STATIC_PROVISIONER_VERSION="${LOCAL_STATIC_PROVISIONER_VERSION:-2.10.0}"

# The node network. metallb.yaml and the example requests name addresses of
# this subnet, so a change here is a change there. Docker gives out the first
# /24, to the kind nodes and to the workers of the simulator.
NODE_NETWORK=podvm-nodenet
NODE_SUBNET=172.28.0.0/16
NODE_IP_RANGE=172.28.0.0/24
NODE_BRIDGE=br-nodenet
NODE_IFNAME=nodenet0
NICO_SIM_PORT=18080

log() { printf '\n=== %s\n' "$*" >&2; }
die() { printf 'podvm-kind: %s\n' "$*" >&2; exit 1; }
as_root() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
k() { kubectl --context "kind-${KIND_CLUSTER_NAME}" "$@"; }
nodes() { kind get nodes --name "${KIND_CLUSTER_NAME}"; }
workers() { nodes | grep -v -- '-control-plane$'; }

step_host() {
  [[ -e /dev/kvm ]] || die "no /dev/kvm: Kata needs KVM, and in a virtual machine nested virtualization"
  log "kernel modules vhost_vsock and vhost_net, and the inotify limit"
  as_root modprobe -a vhost_vsock vhost_net
  if [[ "$(sysctl -n fs.inotify.max_user_instances)" -lt 8192 ]]; then
    as_root sysctl -q -w fs.inotify.max_user_instances=8192
  fi
}

step_network() {
  log "Docker network ${NODE_NETWORK} (${NODE_SUBNET})"
  docker network inspect "${NODE_NETWORK}" >/dev/null 2>&1 \
    || docker network create --subnet "${NODE_SUBNET}" --ip-range "${NODE_IP_RANGE}" "${NODE_NETWORK}" >/dev/null
}

step_cluster() {
  log "kind cluster ${KIND_CLUSTER_NAME}"
  kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER_NAME}" \
    || kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${HERE}/kind.yaml"
}

# node_setup runs in a kind node. A stock kind node lacks three things that a
# real node has: the D-Bus system bus, which the Rust runtime of Kata asks
# systemd for cgroups over; loop device nodes, which the kubelet needs for a
# raw block volume; and a bridge on the node network. The bridge takes the
# address of the interface, so the node and its pods reach the node network.
node_setup() {
  cat <<EOF
set -eu
command -v dbus-daemon >/dev/null || {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq --no-install-recommends dbus
}
systemctl start dbus.socket dbus.service
i=0
while [ \$i -le 127 ]; do
  [ -e /dev/loop\$i ] || mknod -m 660 /dev/loop\$i b 7 \$i
  i=\$((i + 1))
done
ip link show ${NODE_BRIDGE} >/dev/null 2>&1 || ip link add ${NODE_BRIDGE} type bridge
if [ ! -e /sys/class/net/${NODE_BRIDGE}/brif/${NODE_IFNAME} ]; then
  ip link set ${NODE_BRIDGE} address "\$(cat /sys/class/net/${NODE_IFNAME}/address)"
  ip link set ${NODE_IFNAME} master ${NODE_BRIDGE}
fi
ip link set ${NODE_IFNAME} up
ip link set ${NODE_BRIDGE} up
addr="\$(ip -o -4 addr show dev ${NODE_IFNAME} | awk '{print \$4}' | head -n 1)"
if [ -n "\$addr" ]; then
  ip addr del "\$addr" dev ${NODE_IFNAME}
  ip addr replace "\$addr" dev ${NODE_BRIDGE}
fi
EOF
  # Under QEMU the memory of each Kata guest is a file in /dev/shm, and Docker
  # gives a container 64M there. A Linux machine gives /dev/shm half of its
  # memory, as a limit and not as a reservation. Only arm64 runs QEMU here,
  # so a kind node on amd64 stays as it was.
  if [[ "$(go_arch)" == arm64 ]]; then
    echo 'mount -o remount,size=50% /dev/shm'
  fi
}

step_nodes() {
  local node plugins="${STATE_DIR}/cni-plugins-${CNI_PLUGINS_VERSION}.tgz"
  mkdir -p "${STATE_DIR}"
  if [[ ! -s "${plugins}" ]]; then
    log "downloading the CNI plugins ${CNI_PLUGINS_VERSION}"
    curl -fsSL -o "${plugins}" \
      "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-$(go_arch)-${CNI_PLUGINS_VERSION}.tgz"
  fi
  for node in $(nodes); do
    log "${node}: D-Bus, loop device nodes, bridge ${NODE_BRIDGE}, CNI plugins"
    docker exec "${node}" test -e "/sys/class/net/${NODE_IFNAME}" \
      || docker network connect --driver-opt "com.docker.network.endpoint.ifname=${NODE_IFNAME}" "${NODE_NETWORK}" "${node}"
    node_setup | docker exec -i "${node}" sh
    docker exec -i "${node}" tar -xz -C /opt/cni/bin --no-anchored bridge static <"${plugins}"
  done
}

go_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
}

step_multus() {
  log "Multus ${MULTUS_VERSION}"
  # The manifest of a release names the image by a moving tag.
  curl -fsSL "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset.yml" \
    | sed "s#multus-cni:snapshot#multus-cni:${MULTUS_VERSION}#" | k apply -f -
  k -n kube-system rollout status daemonset/kube-multus-ds --timeout=300s
  log "namespace ${POD_NAMESPACE} with the network attachment nodenet"
  k create namespace "${POD_NAMESPACE}" --dry-run=client -o yaml | k apply -f -
  k label namespace "${POD_NAMESPACE}" --overwrite pod-security.kubernetes.io/enforce=privileged
  sed "s/^  namespace: .*/  namespace: ${POD_NAMESPACE}/" \
    "${REPO}/cluster-api-provider-podvm/config/samples/networkattachmentdefinition.yaml" | k apply -f -
}

step_kata() {
  local node file values=(--values "${HERE}/kata-deploy-values.yaml")
  # Kata has Cloud Hypervisor with its Rust runtime for amd64 only. On arm64
  # the runtime class sits on QEMU.
  if [[ "$(go_arch)" == arm64 ]]; then
    values+=(--values "${HERE}/kata-deploy-values-arm64.yaml")
  fi
  for file in vmlinux kata-containers.img; do
    [[ -s "${KATA_GUEST_DIR}/${file}" ]] || die "no ${KATA_GUEST_DIR}/${file}: README.md says how to build it"
  done
  for node in $(nodes); do
    log "${node}: the guest kernel and the guest image"
    docker exec "${node}" mkdir -p /opt/kata-podvm
    for file in vmlinux kata-containers.img; do
      docker cp -q "${KATA_GUEST_DIR}/${file}" "${node}:/opt/kata-podvm/${file}"
    done
  done
  log "Kata Containers ${KATA_VERSION}"
  helm --kube-context "kind-${KIND_CLUSTER_NAME}" upgrade --install kata-deploy \
    oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy --version "${KATA_VERSION}" \
    --namespace kube-system "${values[@]}" --wait --timeout 15m
}

step_metallb() {
  local _
  log "MetalLB ${METALLB_VERSION}"
  helm --kube-context "kind-${KIND_CLUSTER_NAME}" upgrade --install metallb metallb \
    --repo https://metallb.github.io/metallb --version "${METALLB_VERSION}" \
    --namespace metallb-system --create-namespace --wait --timeout 10m
  # The webhook of MetalLB can refuse the pool for some seconds after the wait.
  for _ in $(seq 1 30); do
    k apply -f "${HERE}/metallb.yaml" && return 0
    sleep 5
  done
  die "MetalLB did not take ${HERE}/metallb.yaml"
}

# One sparse file and one loop device for each volume, with direct I/O, and in
# the kind worker a link to the device. The provisioner makes one volume of
# each link.
step_storage() {
  local node place spec name size file dev majmin
  mkdir -p "${STATE_DIR}/disks"
  for node in $(workers); do
    log "${node}: ${PLACES_PER_NODE} volume places"
    docker exec "${node}" mkdir -p /mnt/podvm-disks
    for place in $(seq 0 $((PLACES_PER_NODE - 1))); do
      for spec in var:20G etcd:8G; do
        name="${spec%%:*}-${place}"
        size="${spec##*:}"
        file="${STATE_DIR}/disks/${node}-${name}.img"
        [[ -f "${file}" ]] || truncate -s "${size}" "${file}"
        dev="$(as_root losetup --noheadings --output NAME --associated "${file}" | head -n 1)"
        [[ -n "${dev}" ]] || dev="$(as_root losetup --find --show --direct-io=on "${file}")"
        majmin="$(cat "/sys/block/${dev##*/}/dev")"
        docker exec "${node}" sh -c "[ -e ${dev} ] || mknod -m 660 ${dev} b ${majmin%%:*} ${majmin##*:}"
        docker exec "${node}" ln -sfn "${dev}" "/mnt/podvm-disks/${name}"
      done
    done
  done
  log "local static provisioner ${LOCAL_STATIC_PROVISIONER_VERSION}"
  helm --kube-context "kind-${KIND_CLUSTER_NAME}" upgrade --install local-static-provisioner local-static-provisioner \
    --repo https://kubernetes-sigs.github.io/sig-storage-local-static-provisioner \
    --version "${LOCAL_STATIC_PROVISIONER_VERSION}" \
    --namespace local-static-provisioner --create-namespace \
    --values "${HERE}/local-static-provisioner-values.yaml" --wait --timeout 5m
}

kind_gateway() {
  docker network inspect kind -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' \
    | grep -Eo '^[0-9]+(\.[0-9]+){3}$' | head -n 1
}

# The simulator runs on this machine and listens on the gateway of the kind
# network, where CAPNICo reaches it. A worker is a container on the node
# network alone, so it has the node address that the tunnels of the pod network
# need, and it reaches the control plane Service and the SPIRE server there.
step_sim() {
  local sim="${REPO}/controller/nico-sim" gateway _
  gateway="$(kind_gateway)"
  [[ -n "${gateway}" ]] || die "cannot read the gateway of the Docker network kind"
  [[ -e /sys/module/openvswitch ]] || as_root modprobe openvswitch
  if curl -fsS -m 2 "http://${gateway}:${NICO_SIM_PORT}/healthz" >/dev/null 2>&1; then
    log "something answers on ${gateway}:${NICO_SIM_PORT} already"
    return 0
  fi
  log "building and starting nico-sim on ${gateway}:${NICO_SIM_PORT}"
  make -C "${sim}" build >/dev/null
  mkdir -p "${STATE_DIR}/nico-sim"
  (
    cd "${sim}"
    export NICO_SIM_LISTEN_ADDR="${gateway}:${NICO_SIM_PORT}" NICO_SIM_DB_PATH="${STATE_DIR}/nico-sim/nico-sim.db"
    export NICO_SIM_FILES_DIR="${STATE_DIR}/nico-sim/files" NICO_SIM_SEED_PATH="${sim}/internal/seed/default-seed.yaml"
    export NICO_VMS_VM_BACKEND=mock NICO_VMS_BGP_ENABLED=false NICO_VMS_CONSOLE_SSH_PORT=-1
    export NICO_VMS_BRIDGE_CIDR="${NICO_VMS_BRIDGE_CIDR:-172.30.0.0/24}"
    export NICO_CONTAINERS_ENABLED=true NICO_CONTAINERS_REQUIRE_HEALTHY=true
    export NICO_CONTAINERS_NODE_NETWORK="${NODE_NETWORK}" NICO_CONTAINERS_SPIRE_ATTESTATION_METHOD=joinToken
    export NICO_CONTAINERS_NODE_IMAGE="${CAPD_KINDEST_NODE_IMAGE:-cwe-capd-kindest-node:local}"
    nohup ./bin/nico-sim >"${STATE_DIR}/nico-sim/nico-sim.log" 2>&1 &
    echo $! >"${STATE_DIR}/nico-sim/nico-sim.pid"
  )
  for _ in $(seq 1 30); do
    curl -fsS -m 1 "http://${gateway}:${NICO_SIM_PORT}/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "nico-sim did not answer; the log is ${STATE_DIR}/nico-sim/nico-sim.log"
}

# The address of the control plane node of the host cluster on the node
# network. A node of a tenant cluster reaches the SPIRE server there.
step_env() {
  local vip
  vip="$(docker exec "${KIND_CLUSTER_NAME}-control-plane" ip -o -4 addr show dev "${NODE_BRIDGE}" | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
  [[ -n "${vip}" ]] || die "${KIND_CLUSTER_NAME}-control-plane has no address on ${NODE_BRIDGE}: run the step nodes"
  cat <<EOF
export STACK_DIR=${REPO}
export DEPLOY_TARGET=podvm-e2e
export KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME}
export MANAGEMENT_VIP=${vip}
export NODE_AGENT_SPIRE_ATTESTATION_METHOD=joinToken
export NODE_REBOOT_SOFT_REBOOT_ENABLED=false
export NVKE_CONTROLLER_RELEASES_DIR=${REPO}/controller/test/fixtures/releases
EOF
}

if [[ $# -eq 0 ]]; then
  set -- host network cluster nodes multus kata metallb storage
fi
for step in "$@"; do
  case "${step}" in
    host | network | cluster | nodes | multus | kata | metallb | storage | sim | env) "step_${step}" ;;
    *) die "unknown step ${step}: see the header of $0" ;;
  esac
done
