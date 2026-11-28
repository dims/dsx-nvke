# Node image for pod machines

This folder builds the image that the pods of `cluster-api-provider-podvm` run.
The image is the container node image of this repository
(`controller/hack/capd-kindest-node`) plus the files below. In the pod it runs
systemd, containerd, the kubelet, the SPIRE agent and the NVKE node agent, so
the NVKE controller drives the node as it drives a machine.

The Kubernetes version, the node agent and the CNI packages come from the base
image. Build one image for each Kubernetes version.

## Build

### The base image

A pod has no TPM, so the node gets its SPIRE identity from a join token. Build
the base image for that method, and give the NVKE controller the same method:
the chart value `nodeAgent.spireAttestationMethod: joinToken`, which needs
`spiffe.enabled: true`. [Pod VM](../../docs/site-bootstrap/infrastructure-providers.md#pod-vm)
has the other chart values.

The backend E2E of the repository builds the base image with two commands
(`controller/hack/ci/backend-e2e.sh`). These are the two commands, with each
input that this image needs:

```bash
cd controller
bundles="$PWD/.local/podvm-bundles"
arch="$(go env GOARCH)"

# The SPIRE agent bundle and the OVN-Kubernetes packages, from public sources,
# for the architecture of the machine.
CNI_PLUGIN=ovn-kubernetes BUNDLE_ARCH="$arch" bash hack/ci/prepare-capd-bundles.sh "$bundles"

# CAPD_SPIRE_ATTESTATION_METHOD   join token in place of the default, tpm
# CAPD_NODE_AGENT_LOCAL_BUILD     the node agent of this tree, from agent/
# SPIRE_AGENT_BUNDLE_PATH         the SPIRE agent of the first command
# CAPD_CNI_*_DEB_PATH, CAPD_HELM_DEB_PATH
#                                 the charts and images of OVN-Kubernetes, and
#                                 Helm: the node installs its CNI from them
# CAPD_KINDEST_NODE_IMAGE         the name of the base image
CAPD_SPIRE_ATTESTATION_METHOD=joinToken \
CAPD_NODE_AGENT_LOCAL_BUILD=true \
SPIRE_AGENT_BUNDLE_PATH="$bundles/spire-agent.tgz" \
CAPD_CNI_CHARTS_DEB_PATH="$bundles/nvke-cni-ovn-charts-2.4.2_2.4.2_${arch}.deb" \
CAPD_CNI_IMAGES_DEB_PATH="$bundles/nvke-cni-ovn-images-2.4.2_2.4.2_${arch}.deb" \
CAPD_HELM_DEB_PATH="$bundles/nke-e2e-helm.deb" \
CAPD_KINDEST_NODE_IMAGE=cwe-capd-kindest-node:local \
  bash hack/capd-kindest-node/build-image.sh
```

Use these two commands: CI runs them. The package names carry the
OVN-Kubernetes version, so take them from that script when they change.
`make -C controller capd-image CAPD_SPIRE_ATTESTATION_METHOD=joinToken` is a
shorter form for a developer machine. The target does not name the variable.
`make` gives it to `build-image.sh` through the environment, from the command
line or from the environment of `make`.

One input is not on the command lines: the version of the node agent.
`build-image.sh` takes it from `git describe --tags --always --dirty --match 'v*'`
of the tree. A clone with no version tag gives a bare commit ID there. The NVKE
controller reads the agent version before some changes, and it refuses a
version that it cannot read: the change that turns etcd encryption on needs
0.1.26 or newer. So the clone needs its version tags and the commits back to
the newest one, which a shallow clone does not have. Fetch the tags before the
build, and check the version in the image after it:

```bash
git fetch --tags
docker run --rm --entrypoint /usr/local/bin/nvke-agent cwe-capd-kindest-node:local --version
```

A good version starts with `v` and a release number. A bare commit ID does not.

### This image

The base image must be in the local image store.

```bash
BASE_IMAGE=cwe-capd-kindest-node:local IMAGE=registry.example.com/nvke/podvm-node:1.36.4 \
  cluster-api-provider-podvm/node-image/build-image.sh
```

The script compiles `podvm-bootstrap` with the Go toolchain of the host and
runs one `docker build` with no network. Push the image to a registry of the
host cluster, and name it in `spec.template.spec.image` of the
`PodVMMachineTemplate`.

## What the image adds to the base image

| File | Difference from the base image | Kind |
|---|---|---|
| `podvm-entrypoint` | The entry point. It mounts the two volumes, keeps node state on the `/var` volume, sets the kernel values that a node needs, checks the hostname, and starts the entry point of the base image | Contract |
| `format-if-empty` | It makes ext4 on a volume device, and only when the device proves to be empty | Contract |
| `bootstrap/`, `units/podvm-bootstrap*.service` | The program `podvm-bootstrap` and its two units apply the bootstrap data | Contract |
| `podvm-endpoint-ready` | The program of the readiness probe | Contract |
| `units/zz-podvm-endpoint-gate.conf` | Three health gate flags for the node agent | Contract |
| `Dockerfile` | `/etc/default/nvke-agent` is a link into the `/var` volume, so the agent settings stay through a new pod | Contract |
| `Dockerfile` | `/var/lib/dbus/machine-id` is a link to `/etc/machine-id` | Correction of the base image |
| `ovs-datapath-check`, `units/zz-podvm-builtin-datapath.conf` | The start step of Open vSwitch accepts a datapath that is built into the kernel | Correction of the base image |
| `build-ctr`, `Dockerfile` | The CNI image package of the base image is installed at build time | Correction of the base image |

`build-image.sh` builds the image, and `kernel/` holds the guest kernel options.

The right place for the three corrections is the base image:

- Each node of the base image has the same machine ID, because the image
  carries a D-Bus machine ID file and systemd takes it first.
- The start step of the base image loads the Open vSwitch module when
  `/sys/module/openvswitch` is absent. A kernel with the datapath built in has
  no such folder and no module, so the step fails there.
- A base image with a CNI image package installs it at each start of a node,
  before both agents. That delays each start, also the start of a new pod for a
  lost one. This image installs the package one time, at build. The package
  keeps its archive and the containerd store has the images, so the image grows
  by about two times the size of the archive.

## The contract with the provider

The provider side is in [the provider README](../README.md#the-pod).

| Point of the pod | What the image does |
|---|---|
| No command and no arguments | The entry point runs as PID 1 and ends in systemd |
| `/dev/podvm-var`, `/dev/podvm-etcd` | It makes ext4 on a device with no filesystem. It mounts the first at `/var`, with the `/var` content of the image at the first use, and the second at `/var/lib/etcd`. When it cannot tell if a device is empty, it formats nothing and the start stops |
| `/etc/podvm/bootstrap/value` | The cloud-config text of the NVKE controller. The image applies it one time for each Machine: the files before the SPIRE agent and the node agent start, the commands when the system is up. Then `cloud-init status` answers `done`, or `error` when a step fails |
| `PODVM_MACHINE_NAME` | The entry point stops with an error when the variable is absent or the hostname is another name |
| `PODVM_NODE_ADDRESS`, `PODVM_NODE_INTERFACE` | The CNI of the host cluster sets the address. The entry point only writes a warning when the address is not on the interface |
| Startup probe on port 15005 | The node agent listens there, on its secure port |
| Readiness probe `/usr/local/bin/podvm-endpoint-ready` | It passes when the gate file `/var/lib/nvke/control-plane-endpoint.gate` does not exist and `/readyz` of the local API server answers with a success code within 2 s |
| A new pod for the same Machine | `/var` and `/var/lib/etcd` are the volumes. The image also keeps `/etc/kubernetes`, `/etc/spire-agent`, `/kind`, the agent settings and one machine UUID on the `/var` volume |

How the bootstrap data is applied:

- A file takes a quoted octal mode or a bare number, as in cloud-init, up to
  `0777`.
- A new pod for the same Machine is a new container, so each path outside the
  `/var` volume has the content of the image again. The image writes each such
  file of the bootstrap data again. A file on the volume stays as it is.
- No command runs a second time for a Machine. The commands stop at the first
  one that fails, where cloud-init goes on with the next one.

## The health gate flags

The Service of the shared control plane endpoint sends traffic to each ready
pod. Before an operation that stops the API server or etcd of a node, the node
agent takes the node out of that Service. The drop-in sets three flags of the
node agent for that:

| Flag | Value | Why |
|---|---|---|
| `--control-plane-endpoint-gate-file` | `/var/lib/nvke/control-plane-endpoint.gate` | The agent makes this file, and the readiness probe fails while it exists |
| `--control-plane-endpoint-backend-interface` | `eth0` | The connections of the Service arrive on the pod network interface. The agent closes them and checks that no new one arrives |
| `--control-plane-endpoint-gate-settle` | `15s` | The agent waits this time before it closes the connections. The readiness probe of the provider needs up to 9 s to take a pod out, and the Service then drops the endpoint. 15 s leaves room for both |

The flags do nothing with a node agent that has no endpoint gate. Such an agent
does not know them, and an agent stops at a flag that it does not know. So the
build keeps the drop-in only when the node agent of the base image knows the
three flags, and prints a notice when it removes the drop-in. The image then has
no gate: the readiness probe follows `/readyz` only, and a node leaves the
Service when its API server stops and not before.

## What the host cluster and Kata must give

The image is tested with Kata Containers 4.4.0 and its Rust runtime: on amd64
with Cloud Hypervisor (the configuration `clh-runtime-rs`), and on arm64 with
QEMU (the configuration `qemu-runtime-rs`). That release has `clh-runtime-rs`
for amd64 only. The names below are those of that release. The provider README
lists the other needs of the host cluster.

### The guest kernel

The guest kernel configuration of that release has no Open vSwitch and no
socket diagnostics. `kernel/ovs.conf` has 8 options for the Open vSwitch
datapath with Geneve, which OVN-Kubernetes needs on a node. `kernel/sockdiag.conf`
has 3 options for `ss -K`, which the node agent uses to close the connections of
a node: without them `ss -K` ends with exit code 0 and closes nothing.

Build the kernel with the two files. Start in the root of this repository:

```bash
nvke="$PWD"
mkdir -p ~/kata-kernel && cd ~/kata-kernel
git clone --depth 1 --branch 4.4.0 https://github.com/kata-containers/kata-containers.git
cp "$nvke"/cluster-api-provider-podvm/node-image/kernel/*.conf \
  kata-containers/tools/packaging/kernel/configs/fragments/common/
build() {
  kata-containers/tools/packaging/kernel/build-kernel.sh -a "$(uname -m)" -v v6.18.62 -f \
    -u https://cdn.kernel.org/pub/linux/kernel/v6.x/ -x -m "$@"
}
build setup
build build
DESTDIR="$PWD/out" PREFIX=/opt/kata build install
```

The version, the URL and the options `-x -m` are those of the release kernel,
for x86_64 and for aarch64, so the kernel differs from the stock kernel only by
the two files. `-a` names the architecture of the machine. The build is tested
on x86_64 and on aarch64.
The build host needs a C compiler, `make`, `patch`, `flex`, `bison`, `yq` and
the headers of `libelf`. `tools/packaging/static-build/kernel/Dockerfile` of
Kata has the full package list. The result is
`out/opt/kata/share/kata-containers/vmlinux-6.18.62-211`.

### The Kata handler and the RuntimeClass

Copy the kernel file to each host node. The Kata installer does not bring it.
Then a Kata handler must name the kernel, the guest image and the block device
setting, and a RuntimeClass must name the handler. With the chart `kata-deploy`
that is one custom runtime in the chart values (`docs/helm-configuration.md` of
Kata, "Custom Runtimes"):

```yaml
customRuntimes:
  enabled: true
  runtimes:
    podvm:
      baseConfig: clh-runtime-rs
      dropIn: |
        [hypervisor.clh]
        kernel = "/opt/kata/share/kata-containers/vmlinux-podvm"
        image = "/opt/kata/share/kata-containers/kata-containers-podvm.img"
        block_device_cache_direct = true
      runtimeClass: |
        kind: RuntimeClass
        apiVersion: node.k8s.io/v1
        metadata:
          name: kata-podvm
        handler: kata-podvm
        overhead:
          podFixed:
            memory: "512Mi"
```

`spec.runtimeClassName` of the `PodVMCluster` is then `kata-podvm`. The two
file paths are examples. The reasons for the settings:

- **`overhead`.** The hypervisor runs in the cgroup of the pod, and its own
  memory counts there. The chart default for this runtime is 130Mi. With too
  little overhead the cgroup kills the hypervisor when the guest uses all of
  its memory.
- **`block_device_cache_direct`.** Without it the hypervisor writes a block
  volume through the page cache of the host, and those pages count in the
  cgroup of the pod. A write burst in the guest can then get the hypervisor
  killed.
- **`image`.** The guest image must have a Kata agent with the two changes
  below.

### The Kata agent

The node runs systemd in the container. The Kata agent of the guest image needs
two changes for that. Neither is in a release of Kata Containers.

- **Kill.** systemd moves each process of the container into a child cgroup.
  The agent looks for the processes of a container only in the cgroup of the
  container itself, so a kill reaches none of them. Without the change a stop
  of the container and a delete of the pod do not end the node until the
  runtime gives up, and a node that hangs cannot be killed. Kata Containers
  issue 14062 describes it.
- **Exec.** The agent puts the process of an exec into the cgroup of the
  container. After systemd starts, that cgroup has child cgroups with
  controllers, and the kernel refuses a process there with `EBUSY`. Without the
  change `kubectl exec` fails. The readiness probe of the provider is an exec
  probe, so no control plane pod gets ready. Kata Containers pull request 13627
  has such a change.

## What is not covered

- No test runs the image in a pod. The checks are the image build, the unit
  tests of `podvm-bootstrap` and the test of `format-if-empty`.
- No workflow builds or publishes the image.
- The chart values for the Kata handler follow the chart of Kata Containers
  4.4.0. No test installs Kata with them.
- The image carries no kernel config file. The kubeadm wrapper of the base
  image ignores the `SystemVerification` check, which reads that file.
- The image adds no container image to those of the base image. A node pulls
  the pause image and the images of the cluster add-ons, so it needs a registry
  that it can reach.
- A new pod gives the node a new Open vSwitch system ID, because that file is
  not on the volume. OVN then sees a new chassis, and the old chassis row stays
  until OVN removes it.
- The journal is in memory. A new pod has no earlier log lines, also not the
  output of a bootstrap command.
- The join token of a node works one time. A node that is down for longer than
  the life of its SPIRE identity cannot get a new identity.
- The entry point needs both volume devices, also for a worker.
- The bootstrap data replaces the agent arguments of the base image, with its
  flag `--disable-mlx5-rescan`. In a Kata guest the rescan sees only the
  devices of the guest.
- Not tested: arm64, IPv6, another hypervisor, and a runtime that is not Kata.
