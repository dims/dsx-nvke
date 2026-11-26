# Source reading for phase 1: NVKE and the provisioned provider

Date: 2026-11-26. NVKE commit `bcc4376f`. A read-only agent read the source in two rounds and returned its reports as text. The main session wrote this file. No test ran. Paths are relative to the NVKE repository. "Deduction" marks a statement that comes from the source text and is not tested.

This file supports `phase1-design.md`. The earlier reading is `results/architecture-reading.md`.

## Corrections to the earlier reading

- The provisioned provider can also be installed with `kubectl apply -k cluster-api-provider-provisioned/config/default` (`cluster-api-provider-provisioned/README.md:100-104`). The earlier note named only `nvkectl bootstrap`.
- The deployment gate for a cluster create is `controller/internal/server/clusters.go:396-398`. The line in `server/node_pools.go:276-279` is the gate for node pools.
- The preflight has a third exception: a regular file `/var/lib/dsxos/.cidata-consumed` passes the cloud-init check (`agent/internal/agent/preflight.go:20,103-108`).
- The setting `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP` also selects the kubeadm container mode, not only the preflight (`controller/internal/temporal/activities/kubeadm.go:38-44`).

## How `nvkectl` uses the provisioned provider

- The request (`cli/internal/bootstrap/sitecluster/sitecluster.go:45-195`): `infra.cluster` is a `ProvisionedCluster` with `spec.hosts[]`, each host with `hostname`, `ipAddress` and an optional `tpmEkPubHash`. The machine template is a `ProvisionedMachineTemplate` with an empty spec. The request has no node pools, no `bootstrapFiles`, no `preKubeadmCommands` and no `nodeAgentConfig`.
- Identity is set up outside the provider. With TPM, the provider puts the SPIFFE ID path on the Machine, and NVKE makes the SPIRE entry for the host ID (`cluster-api-provider-provisioned/controllers/machine_controller.go:43-53,397-423`, `controller/internal/controllers/capi/machine_spire_entry_controller.go:60-125`). With `--disable-mtls` the agent runs with no mTLS. Join tokens are not used on this path.
- NVKE still writes the bootstrap Secret, but nothing on the host reads it.
- What must be on a host before the flow (`docs/site-bootstrap/pre-provisioned-nodes.md:36-63,175-212`): Ubuntu 24.04 or 26.04, containerd 2.2.0 or later, kubeadm, kubelet and kubectl, CNI binaries, swap off, Open vSwitch for OVN, and `nvke-agent` with its environment file.
- A precedent: the bootstrap e2e runs three privileged containers as hosts that exist (`cli/e2e/bootstrap/substrate/substrate.go:298-338`), with a VIP and a BGP speaker.

## The flow of `nvkectl bootstrap site`

- It makes its own seed cluster with kind through nerdctl and containerd (`cli/internal/nvkectl/bootstrap.go:418-424`, `engine/bootstrapengine.go:16-17,45-62`). Docker is not supported, and it cannot use a cluster that exists.
- It installs PostgreSQL, Temporal, SPIRE, Cluster API, the provisioned provider and the controller chart, in that order (`controllerdeploy.go:569-775`).
- The site spec accepts only `ovn-kubernetes` as the CNI (`sitespec.go:146-149,832-835`). The identity choices are TPM and no mTLS. The chart values are fixed flags with no hook for more values, so `nodeAgent.spireAttestationMethod` stays `tpm`.
- A VIP is necessary for more than one node unless the flag `--allow-control-plane-without-vip` is set (`sitespec.go:870-876`).
- It ends with no move of NVKE into the new cluster, and it deletes the seed cluster.

## The local NVKE stack

- The quickstart (`docs/get-started/quickstart-local.md`): a kind cluster with Cluster API, the NVKE management plane from Tilt on `localhost:8080`, and `nico-sim`. It needs 6 CPUs, 12 GiB of free memory, 100 GiB of disk. Ports: 179, 2222, 5432, 7233, 8080, 8081, 10350, 18080, 30440, 30443.
- Tilt deploys PostgreSQL, Temporal, SPIRE and the controller (`controller/Tiltfile:551-613,819,1166`). It can use a kind cluster that exists: the name comes from `KIND_CLUSTER_NAME`, and the context must be `kind-<name>` (`Tiltfile:180-199,239-242`, `controller/Makefile.dev:34,437-446`).
- Tilt settings: `supportedInfraProviders` gets `infra` when the provider list has `capd` or `nico` (`Tiltfile:145-153,1140`). `capi.rbac.create=true` is fixed. `NODE_AGENT_SPIRE_ATTESTATION_METHOD` and `INSTALL_CNI_AFTER_INIT` come from `.env.tilt`. `allowControlPlaneWithoutVIP` has no Tilt setting. The documented hook is an external provider with `controller_chart_flags` (`Tiltfile:406-446`), or an edit of `hack/tilt-controller-chart-values.yaml`.
- Tilt builds the controller image and the profiles image. The charts pull about 15 to 25 images (deduction). The provisioned provider is not wired into Tilt.
- The way with no Tilt: `make -C controller capi-core-up` and `make -C controller run-local`. PostgreSQL runs as a container, Temporal as a dev server on the host, and the controller runs on the host with `go run`. The settings file is `controller/hack/local-controller-config.yaml`.

## The cluster create request on the `infra` path

- `controlPlaneVIP` is necessary for more than one node unless the deployment has `allowControlPlaneWithoutVIP` (`controller/api/openapi.yaml`, about lines 1131 to 1146, `server/control_plane_vip.go:18-23`).
- The control plane configuration has `desiredCount`, `systemReservedMemory` (default 16Gi), `infra.machineTemplate`, `bootstrapFiles`, `preKubeadmCommands`, and `extraArgs` for the API server, the controller manager and the scheduler.
- `nodeAgentConfig` has only `version`. The identity method is a deployment setting.
- The request has no field for etcd arguments and none for the kube reserved memory of the control plane.
- `bootstrapFiles` and `preKubeadmCommands` reach a node only through cloud-init data, which the provisioned provider does not deliver.

## kubeadm rendering

- Patches: `InitConfiguration.Patches.Directory` and the same field of the join configuration are `/etc/kubernetes/patches` (`controller/internal/kubeadmconfig/init.go:176-178`, `join.go:253-254`). NVKE writes two files there. The agent writes its files and does not clean the folder (`agent/internal/agent/kubeadm_prerequisite_files.go:43-59`). Deduction: an etcd patch file that is in the pod before the call is applied at init and at join.
- etcd arguments: the function `etcdExtraArgs` (`init.go:225-239`) sets the quota, the compaction, the metrics URL and the defrag threshold. No API field or setting reaches it.
- Endpoint: `temporal/activities/kubeadm_init.go:80-83` uses the VIP, or the node IP when the VIP is empty. kube-vip is skipped with no VIP (`configure_kube_vip.go:90-93`). A join reads the endpoint from the join string of a joined node (`kubeadm_join.go:93-126`).
- Container mode: selected by the kind `DockerMachineTemplate` or by the deployment-wide setting (`activities/capi_shared.go:20-64`). It ignores `SystemVerification`, sets the conntrack values of kube-proxy to 0, sets `failSwapOn: false` and uses reservations of 256Mi.
- Reservations: the kubelet patch defaults to 16Gi for the system and 2Gi for kube. `systemReservedMemory` of the request reaches it (`kubeadm_init.go:116-117`).

## Preflight

- NVKE asks the agent for the cloud-init status (`activities/node_preflight.go:101-120`). With the container mode it checks the file `/run/cluster-api/bootstrap-success.complete`.
- The agent runs `cloud-init status --long` (`agent/internal/agent/preflight.go:126`). `done` passes, `error` is permanent, each other value is "not done".
- The CAPD node image has a `cloud-init` shim that reads `/var/lib/nico-containers/cloud-init/status` (`controller/hack/capd-kindest-node/Dockerfile:66`).

## Agent identity

- The profile comes from deployment settings: `spire.spiffeEnabled`, `nodeAgent.spireAttestationMethod` (`tpm`, `joinToken`, `dsxImds`), and the TLS settings (`controller/internal/nodes/agent_profile.go:14-22`).
- Join token: `createCAPISpireJoinToken` (`activities/capi_node_resources.go:103-127`) makes a token with the agent ID `spiffe://<trust domain>/join-token-spire-agent/host-id/<node ID>` and the life `joinTokenTTL` (default 1 hour). NVKE puts that ID path on the Machine, and `MachineSpireEntryController` makes the entry for `spiffe://<trust domain>/host/<node ID>` with the selector `unix:uid:0`.
- The bootstrap Secret `<node>-bootstrap-data`, key `value`, is cloud-config text (`clients/capi/bootstrap_userdata.go:70-164`): the files of the caller, `/etc/spire-agent/initial-trust-bundle.pem`, `/etc/spire-agent/agent.conf`, the agent environment file, and commands that end with a restart of the agent unit.
- The SPIRE server address in `agent.conf` is the setting `spiffe.spire.serverAddress` with `spire.serverPort`. In Tilt it is the kind gateway with the NodePort 30440.
- `nico-sim` copies the cloud-config into a container with `applyCloudConfig` (`controller/nico-sim/internal/container/docker.go:136-218`): it writes each file, runs the commands, and writes `done` or `error` to the status file of the shim.
- TPM in a container needs `/dev/vtpmx` from the kernel module `tpm_vtpm_proxy`.

## Dial path

- The controller dials `node.IP` and the port 15005 (`controller/internal/agent/transport.go:123-127`). On this path `node.IP` is the `ipAddress` of the host in the inventory.
- The controller accepts only the ID `spiffe://<trust domain>/host/<node ID>`, where the node ID is the ID of the node in the NVKE database (`transport.go:227-262`).
- The agent accepts only callers under `/tenant/nvke/service/`, `/nvke-service/` and two older prefixes (`agent/cmd/agent/main.go:208-260`).
- Ports that a Service in front of a pod must have (deduction): 15005, 6443, 2379, 2380, 10250, and the ports of the CNI.

## The provisioned provider

- Inventory fields: `hostname`, `ipAddress`, `tpmEkPubHash`, `labels`. An empty `hostSelector` matches each host, and the first free host in the list wins (`controllers/inventory.go:65-92`).
- The providerID is `provisioned://<cluster>/<ip>`. The provider finds the Node by the Machine name. NVKE gives kubeadm the same name as the node name.
- A bound Machine cannot be deleted (`controllers/machine_controller.go:103-126`).
- The provider sets no endpoint.

## CNI

- The API accepts `calico` and `ovn-kubernetes` (the default). `calico` needs the deployment setting `allowLegacyCalicoClusterCreation`. No value means "no CNI".
- OVN: a step before the join, `ConfigureOpenVSwitch`, tries with no end (`temporal/workflows/provision_node.go:404-437`). The agent needs the Open vSwitch package. The agent has the setting `NKE_OVS_DATAPATH_TYPE` with the values `system` and `netdev` (`agent/internal/agent/open_vswitch.go:57-58`). Deduction: `netdev` needs no kernel module and needs TUN.
- With OVN, NVKE skips kube-proxy (`kubeadm_init.go:113`).
- The bootstrap e2e and the CAPD example both use `ovn-kubernetes`.

## What makes NVKE report "provisioned"

- Cluster (`temporal/workflows/provision_cluster.go:48-97`): the Cluster API objects, one node ready to join, kube-vip (skipped with no VIP), `kubeadm init`, the CNI install, the first node joined, the DNS install, the namespace labels, then "provisioned".
- The DNS install applies node-local-dns with `hostNetwork: false` and tries until a ready pod with the label `dns-role=cluster-dns` exists (`activities/install_kube_local_dns.go:53-88,209-251,288-315`).
- Control plane joins start only after the cluster is provisioned (`controllers/controlplane/join.go:85-91`).
- NVKE does not wait for a ready Node, for kube-proxy, for the approval of a kubelet serving certificate, or for workloads on a node that joins.
- Deduction: with no working pod network on the first node, the cluster does not reach "provisioned".

## Image access at kubeadm time

- The control plane images come from `registry.k8s.io` by default. The kind node image has the images of its own version.
- With the CNI install after init, the agent reads the charts from a package in the image and does not run apt.
- node-local-dns pulls `registry.k8s.io/dns/k8s-dns-node-cache:1.26.8`.
