# Kind host cluster for the pod VM provider

`cluster-api-provider-podvm` runs each control plane node of a tenant cluster as
a Kata pod of the cluster that runs Cluster API. The provider needs four things
from that host cluster: a Kata runtime class, a node network through Multus, a
load balancer and block storage. A site brings its own. This folder gives the
same set on one Linux machine, in a kind cluster, so that the
`controller/deploy/podvm-e2e` deploy path can run there.

| File | What it is |
|---|---|
| `up.sh` | Brings the host cluster up, step by step. Its header lists the steps |
| `down.sh` | Removes what `up.sh` made |
| `kind.yaml` | The kind cluster: one control plane node and three workers |
| `kata-deploy-values.yaml` | Values for the `kata-deploy` chart: the runtime class `kata-podvm` |
| `metallb.yaml` | The address pool of the control plane Service |
| `local-static-provisioner-values.yaml` | Values for the local static provisioner: the storage class `podvm-block` |

## What the machine needs

- Linux on amd64 with `/dev/kvm`. In a virtual machine, nested virtualization
  must be on.
- Docker 28 or newer with `buildx`, `kind`, `kubectl`, `helm` and `clusterctl`.
- Go, a C compiler and `make`, for the builds. The node image README lists what
  its kernel build needs more.
- `python3`, `curl`, `jq`, and `tar` with `zstd`. The scripts and the commands
  of this page call them.
- The versions that this repository is tested with: `make/tool-versions.mk`
  pins `kind`, `kubectl`, `helm` and Cluster API, which is also the version of
  `clusterctl`, and `go.work` pins Go.
- `sudo` rights, for `modprobe`, `sysctl` and `losetup`.
- A machine where a container reaches the internet. A kind node installs one
  package and pulls images, and a node of the tenant cluster pulls images.
- About 20 Gi of memory for three control plane nodes of 6 Gi, and disk space
  for six volume places of 28 G as sparse files.

## The addresses

`up.sh` makes a second Docker network, `podvm-nodenet`, for the node network.
Each kind node gets an interface on it and a bridge, `br-nodenet`.

| Range | Who has it |
|---|---|
| `172.28.0.0/24` | Docker: the kind nodes and the workers of the simulator |
| `172.28.1.0/24` | The provider: the node address of each control plane pod |
| `172.28.255.200` to `172.28.255.250` | MetalLB: the control plane Service |

The examples use `172.28.255.220` as the control plane endpoint.

## 1. Build the guest kernel and the guest image

[The node image README](../../../cluster-api-provider-podvm/node-image/README.md#what-the-host-cluster-and-kata-must-give)
says what the feature needs from Kata Containers 4.4.0, and why: a guest kernel
with eleven more options, and a Kata agent with two changes. `up.sh` reads both
as files of one directory:

```bash
export KATA_GUEST_DIR="${HOME}/.local/state/podvm-kind/kata-guest"
mkdir -p "${KATA_GUEST_DIR}"
```

`vmlinux` is the guest kernel. That README has the build. Copy its result:

```bash
cp ~/kata-kernel/out/opt/kata/share/kata-containers/vmlinux-6.18.62-211 "${KATA_GUEST_DIR}/vmlinux"
```

`kata-containers.img` is a guest image whose Kata agent has the two changes.
Build it in a Kata Containers 4.4.0 tree that has them, with the make target of
Kata. `KATA_SRC` is the root of that tree. The build runs in containers and
needs Docker. `USE_CACHE=no` makes it use this tree and not a published
artifact.

```bash
USE_CACHE=no make -C "${KATA_SRC}/tools/packaging/kata-deploy/local-build" rootfs-image-tarball
mkdir -p /tmp/kata-out
tar --zstd -xf "${KATA_SRC}/tools/packaging/kata-deploy/local-build/build/kata-static-rootfs-image.tar.zst" -C /tmp/kata-out
cp -L /tmp/kata-out/opt/kata/share/kata-containers/kata-containers.img "${KATA_GUEST_DIR}/kata-containers.img"
```

## 2. Build the images and nvkectl

[The node image README](../../../cluster-api-provider-podvm/node-image/README.md#build)
builds the container node image of this repository, `cwe-capd-kindest-node:local`,
for the join token method. The node image of a control plane pod sits on it.
`cwe-capd-kindest-node:local` is also the image of a simulator worker. Then,
from the repository root:

```bash
BASE_IMAGE=cwe-capd-kindest-node:local IMAGE=podvm-node:local \
  cluster-api-provider-podvm/node-image/build-image.sh
make -C controller docker-build-local IMG=nvke-controller:local
make -C cluster-api-provider-podvm docker-build PLATFORMS=linux/amd64 BUILDX_OUTPUT=type=docker
make -C cli build
export PATH="${PWD}/cli/bin:${PATH}"
```

The last two lines build `nvkectl` and put it on the search path.

## 3. Bring the host cluster up

```bash
controller/hack/podvm-kind/up.sh
```

Then load the three images into the kind nodes:

```bash
for image in podvm-node:local nvke-controller:local cluster-api-provider-podvm:latest; do
  for node in $(kind get nodes --name podvm); do
    docker save --platform linux/amd64 "${image}" | docker exec -i "${node}" ctr -n k8s.io images import --digests -
  done
done
```

`kind load docker-image` can fail with the containerd image store of Docker,
when the store has one platform of an image. The loop works with both stores.

## 4. Install Cluster API and the provider

```bash
CAPI_VERSION="$(make --no-print-directory print-CAPI_VERSION)"
clusterctl init --kubeconfig-context kind-podvm --core "cluster-api:${CAPI_VERSION}" \
  --bootstrap "kubeadm:${CAPI_VERSION}" --control-plane "kubeadm:${CAPI_VERSION}" --wait-providers
kubectl --context kind-podvm apply -k cluster-api-provider-podvm/config/default
kubectl --context kind-podvm -n podvm-system rollout status deployment/podvm-controller-manager
```

## 5. Install CAPNICo and start the simulator

The example cluster of step 7 has one worker pool of the NICo simulator, so
CAPNICo and the simulator come first. CAPNICo is built from its source, at the
version that this repository pins.
[Get the CAPNICo source](../../../docs/get-started/quickstart-local.md#get-the-capnico-source)
says why the source is a writable copy of the Go module. From the repository
root:

```bash
kubectl config use-context kind-podvm
CAPNICO_MODULE_DIR="$(go mod download -json github.com/dsx-ai-factory/cluster-api-provider-nico | jq -r .Dir)"
export CAPNICO_SOURCE_DIR="${PWD}/controller/.local/capnico-source"
mkdir -p "${CAPNICO_SOURCE_DIR}"
cp -R "${CAPNICO_MODULE_DIR}/." "${CAPNICO_SOURCE_DIR}/"
chmod -R u+w "${CAPNICO_SOURCE_DIR}"
CAPNICO_STAGED_CHART_DIR="${PWD}/controller/.local/capnico-chart" KIND_CLUSTER_NAME=podvm \
  controller/hack/nico-provider/install-capnico.sh
controller/hack/podvm-kind/up.sh sim
```

`install-capnico.sh` and the script of the next step use the current context of
`kubectl`, which the first line sets.

A worker is a privileged container on the kernel of the machine, on the node
network alone. The pod network of the tenant cluster needs the kernel module
`openvswitch` there, and `up.sh sim` loads it.

## 6. Install the management plane

`controller/hack/ci/deploy-stack.sh` installs a deploy path of
`controller/deploy/` with the values of one run. `up.sh env` prints those values
for this cluster.

```bash
eval "$(controller/hack/podvm-kind/up.sh env)"
controller/hack/ci/deploy-stack.sh nvke-controller:local
```

The path sets the controller for the provider: it accepts the `infra` object,
has the RBAC for the three kinds of the provider, gives a node its identity from
a join token, and asks the provider for a new pod when a node must reboot.

## 7. Create a cluster

```bash
API_PORT=8080
kubectl --context kind-podvm -n nvke-controller port-forward service/nvke-controller "${API_PORT}:8080" &
kubectl config view --raw --minify --context kind-podvm >podvm.kubeconfig
nvkectl config set-site --name podvm --url "http://localhost:${API_PORT}" --kubeconfig "${PWD}/podvm.kubeconfig"
nvkectl create cluster -f cli/examples/podvm-cluster.yaml
```

`API_PORT` is the local port of the port forward. Take another free port when
something on the machine already listens on 8080.

`kubectl --context kind-podvm -n podvm-clusters get pods` shows one pod for each
control plane node. `nvkectl get clusters` shows the cluster as `Provisioned`
when the nodes have joined.

## Clean up

Delete each tenant cluster with `nvkectl delete cluster` first, and stop the
port forward of step 7. Then:

```bash
controller/hack/podvm-kind/down.sh
```

## What is not covered

- A restart of the machine or of a kind node. The bridge, the loop devices and
  their device nodes are gone then. Run `up.sh` again.
- More than one machine, and any real storage or network.
- `nvkeOIDCAuth`. The deploy path turns it off: the provider reads the
  kubeconfig Secret of a cluster, and with OIDC that kubeconfig needs the SPIRE
  exec-auth program, which the image of the provider does not have.
- A workflow. No lane runs this folder.
