# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Settings of the phase 1 NVKE stack in the lab cluster kata-cp.
# install.sh, uninstall.sh, check.sh and api.sh source this file. It runs nothing.
#
# The values files in values/ hold the same trust domain and the same SPIRE address as
# literals. Step 00 of install.sh stops when the two places differ.

# The folder of this file. On the host it is /scratch/kata-cp/work/phase1-stack.
# In the toolbox container the same folder is /work.
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- the lab -------------------------------------------------------------------------------
KIND_NODE="${KIND_NODE:-kata-bb-control-plane}"   # the kind node that has kubectl and the API server (the control plane node of four)
DOCKER_NET="${DOCKER_NET:-kata-bb}"               # Docker network of the kind node
NODE_IP="${NODE_IP:-172.29.0.3}"                  # address of the kind node on that network

# --- the source (read only) ----------------------------------------------------------------
NVKE_COMMIT="c6d669ef"   # the controller of the branch with controlPlaneEndpoint. The provider image is bcc4376f.
# On the-second-machine: a copy of the few files of the source that the install reads (charts, two manifests,
# the pins), from /scratch/kata-cp/src/nvke-endpoint of the workstation. No toolbox container.
NVKE_SRC="${NVKE_SRC:-/root/kata-cp/d/src}"

# --- tools ---------------------------------------------------------------------------------
# The toolbox is a container on the Docker network of the lab. It reaches the API server at
# https://kata-cp-control-plane:6443 over the bridge, with no host socket. helm, kubectl and
# clusterctl are static binaries of the host, mounted read only.
TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-debian:trixie-slim}"   # is in the local Docker store
HELM_BIN="${HELM_BIN:-/root/kata-cp/bin/helm}"         # v4.2.4, the pin of make/tool-versions.mk:63
KUBECTL_BIN="${KUBECTL_BIN:-/root/kata-cp/bin/kubectl}"
CLUSTERCTL_BIN="${CLUSTERCTL_BIN:-/root/kata-cp/bin/clusterctl}"   # step 01 downloads it
CA_BUNDLE="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

# --- Docker Hub mirror and logs --------------------------------------------------------------
# Each Docker Hub image comes from this mirror: the base images of the two builds (build
# arguments) and the chart images (values/). A digest of the source stays as it is.
DOCKERHUB_MIRROR="${DOCKERHUB_MIRROR:-mirror.gcr.io}"
# One log for each step, and one line for each step in progress.txt.
LOG_DIR="${LOG_DIR:-/root/kata-cp/logs/d-stack}"
PROGRESS_FILE="$LOG_DIR/progress.txt"

# --- pins, copied from the source ------------------------------------------------------------
# make/tool-versions.mk:117-119
CAPI_VERSION="v1.13.6"
CLUSTERCTL_SHA256="1e4019b8ef30fa13993716d28b9fec4072fee1e17ea2cc69cb7c8f232d9b8c2f"
CLUSTERCTL_URL="https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_VERSION}/clusterctl-linux-amd64"
# cli/internal/bootstrap/manifest/bootstrap-manifest.yaml:30-71
TEMPORAL_CHART_REPO="https://go.temporal.io/helm-charts"
TEMPORAL_CHART_VERSION="0.74.0"
TEMPORAL_CHART_SHA256="14a8efe1cc92c91befac151db91f20f9a13962788e9d710c86655add6d966d37"
SPIRE_CHART_REPO="https://spiffe.github.io/helm-charts-hardened/"
SPIRE_CRDS_CHART_VERSION="0.6.1"
SPIRE_CRDS_CHART_SHA256="ce982e63fc375e392b014fc99e621a55442ab886052413e9bb052f72d66580a8"
SPIRE_CHART_VERSION="0.30.1"
SPIRE_CHART_SHA256="7c32126bb1909076cdf9fd0419dbf9e5b012f152bb09a96a4259917d70581fac"

# --- names, as cli/internal/bootstrap/controllerdeploy/controllerdeploy.go:56-81 fixes them ----
NS_POSTGRES="postgres"
NS_TEMPORAL="temporal"
NS_SPIRE="spire-server"
NS_CONTROLLER="nvke-controller"
NS_NVKE_SYSTEM="nvke-system"
NS_PROVISIONED="provisioned-system"
NS_CAPI_ALL="capi-system capi-kubeadm-bootstrap-system capi-kubeadm-control-plane-system"
NS_CERT_MANAGER="cert-manager"
# Each namespace that the stack makes. None of them exists in the lab cluster today.
STACK_NAMESPACES="$NS_POSTGRES $NS_TEMPORAL $NS_SPIRE $NS_CERT_MANAGER $NS_CAPI_ALL $NS_PROVISIONED $NS_CONTROLLER $NS_NVKE_SYSTEM"

# --- SPIRE -----------------------------------------------------------------------------------
TRUST_DOMAIN="kata-cp.nvke.local"          # also in values/spire-values.yaml and values/controller-values.yaml
SPIRE_CLUSTER_NAME="kata-cp"
# The address and port that NVKE writes into agent.conf of each node
# (controller/internal/clients/capi/bootstrap_userdata.go:128-129). A pod of the lab cluster
# reaches the kind node address and the NodePort. Also in values/controller-values.yaml.
SPIRE_AGENT_ADDRESS="$NODE_IP"
SPIRE_AGENT_PORT="30081"                   # NodePort of manifests/spire-server-external.yaml
# The address that the controller uses for join tokens (controller/internal/config/config.go:348).
SPIRE_API_ADDRESS="spire-server.spire-server.svc.cluster.local:8081"

# --- images that the lab builds --------------------------------------------------------------
CONTROLLER_IMAGE_LOCAL="nvke-controller:${NVKE_COMMIT}"                           # name in the Docker store
CONTROLLER_IMAGE="docker.io/library/nvke-controller:${NVKE_COMMIT}"               # name in the kind node
PROVISIONED_IMAGE_LOCAL="cluster-api-provider-provisioned:bcc4376f"
PROVISIONED_IMAGE="docker.io/library/cluster-api-provider-provisioned:bcc4376f"
# The image name in the manifest of the source (cli/internal/bootstrap/controllerdeploy/capi.go:63).
PROVISIONED_PLACEHOLDER_IMAGE="docker.io/library/cluster-api-provider-provisioned:latest"
PROVISIONED_MANIFEST_SRC="cli/internal/bootstrap/controllerdeploy/manifests/provisioned-provider.yaml"

# --- the NVKE API ------------------------------------------------------------------------------
# In the cluster: http://nvke-controller.nvke-controller.svc.cluster.local:8080/api
# API authentication is off in this stack (chart default, values.yaml:521-523). No token.
CONTROLLER_SVC="nvke-controller"
CONTROLLER_PORT="8080"
# The same API through the service proxy of the API server (controllerdeploy.go:990-991).
CONTROLLER_PROXY="/api/v1/namespaces/${NS_CONTROLLER}/services/${CONTROLLER_SVC}:http/proxy"

# --- the check ---------------------------------------------------------------------------------
# The probe pod runs with runc and with this Kata class. The gate 4 pods use the same class.
PROBE_RUNTIME_CLASS="${PROBE_RUNTIME_CLASS:-kata-clh-runtime-rs-fix-direct-ovs}"
PROBE_IMAGE="${PROBE_IMAGE:-docker.io/library/nvke-node:bcc4376f-amd64}"   # is in the kind node, has openssl
NS_PROBE="phase1-probe"
