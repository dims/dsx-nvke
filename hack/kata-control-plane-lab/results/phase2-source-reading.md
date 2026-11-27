# Phase 2: source facts for a provider that runs control plane nodes as pods

Date: 2026-11-26, 16:28 to 16:45 local time. A reading agent read the NVKE source and returned this report as text. The main session wrote the file. The agent only read. It ran no build, no test and no network request.

Tree: `/scratch/kata-cp/src/nvke-endpoint` at `c6d669ef` (main at `d625fcfa` plus the three commits of the request field `controlPlaneEndpoint`). Line numbers are from that commit.

Path prefixes: `$R` is the root of the tree, `$C` is `$R/controller/internal`, `$P` is `$R/cluster-api-provider-provisioned`. "Deduction" marks what the agent did not see as code or text. "Upstream" marks Cluster API behavior that is not in this tree (the tree has no vendor folder). No statement here is tested.

## 1. The contract of the `infra` path

| Object | What NVKE does | Source |
|---|---|---|
| Infra cluster | Applies the caller manifest with the cluster name in the management namespace. Sets or removes the paused annotation. Reads no field of it directly | `$C/capi/resources.go:39-48`, `:89-100` |
| Cluster | Creates it with `spec.infrastructureRef` only. No control plane reference | `$C/capi/resources.go:58-78` |
| Cluster | Reads `status.initialization.infrastructureProvisioned` and `status.failureDomains` with `controlPlane: true` | `$C/controllers/controlplane/failure_domain_discovery.go:56-65` |
| Cluster | Writes `spec.controlPlaneEndpoint` itself from the admin kubeconfig. It does not take an endpoint from the infra cluster | `$C/controllers/tenantaccess/capi_contract.go:113-147` |
| Infra machine | Renders it in memory from `infra.machineTemplate`, name = node name, and applies it. The template object is never applied | `$C/clients/capi/machine.go:29-56`, `:75` |
| Bootstrap Secret | `<node>-bootstrap-data`, key `value`, type Opaque, no `format` key | `$C/clients/shared/machine.go:145-163` |
| Machine | Name = node name. `spec.version`, `spec.failureDomain`, `spec.bootstrap.dataSecretName`, `spec.infrastructureRef`. Labels: cluster name, control plane | `$C/clients/shared/machine.go:168-206`, `:234-242` |
| Machine annotations | Agent connection mode, host ID, attestation method, SPIFFE flag, two "skip drain" annotations. With a join token: the SPIRE agent ID path | `$C/clients/shared/machine.go:245-267`, `$C/clients/capi/machine.go:110-112` |
| Machine | Reads `spec.providerID` (empty = Pending) and the message of `InfrastructureReady` | `$C/temporal/activities/capi_node_resources.go:249`, `:357-362`, `:393-399` |
| Address | Waits for `status.addresses` of the Machine, else of the infra machine. Order: InternalIP, ExternalIP, any | Same file, `:262-285`, `:401-449` |
| Infra machine | Generic reads of `spec.instanceTypeID`, `status.instanceID`, `status.machineID` (NICo fields) | Same file, `:456-475`, `$C/clients/shared/machine.go:48-72` |
| Machine, later | Reboot annotation. Health issue annotation before the delete | Same file, `:163-173`, `:506-561` |

- NVKE stores the address one time as `node.IP` (`capi_node_resources.go:314`, the only writer). It is the agent dial address, the kubelet `node-ip`, the API server advertise address (`$C/kubeadmconfig/init.go:180,188`, `join.go:269,283`) and the only IP SAN that the kubelet serving certificate approval accepts (`$C/controllers/tenant/csr/controller.go:413-436`).
- NVKE does not read the ready condition or `status.initialization.provisioned` of the infra machine. The provider comment says Cluster API core waits for that field on the infra cluster (`$P/controllers/cluster_controller.go:31-34`).
- The main flow does not read `Machine.status.nodeRef`. Two opt in controllers do (`$C/controllers/kubeletcsr/client_controller.go:251`, `$C/controllers/bootstrap/bootstrap_authorization_controller.go:330`). The provisioned provider sets the Node `providerID` itself (`$P/controllers/machine_controller.go:429-488`).

Generic and named code:

- Generic: all rows above. The controller code names no provisioned kind.
- Names NICo: instance labels when a template renders a `NicoMachine` (`$C/clients/capi/machine.go:120-147`), and two `NicoMachine` controllers.
- Names Docker: the kind `DockerMachineTemplate` selects the kubeadm container mode and the sentinel file preflight (`$C/temporal/activities/capi_shared.go:20-64`, `node_preflight.go:107-134`, `kubeadm.go:39-45`).
- Names provisioned: only the chart RBAC (`$R/controller/deploy/charts/controller/templates/rbac-capi.yaml:48-61`, `:70-79`).

A new kind with no controller change: yes for the create path. Conditions:

- The API group is exactly `infrastructure.cluster.x-k8s.io` (`$C/clients/capi/manifestvalidate.go:16`, `:65-71`).
- `infra` is in `supportedInfraProviders` (`$C/server/clusters.go:393-400`; the chart default is `nico`, `values.yaml:358`).
- RBAC for the kinds, and `get` on their CRDs. CAPD has it as a ClusterRole outside the chart (`$R/controller/hack/capd-provider/controller-rbac.yaml:4-50`).

On record against this:

- The docs call the provider set closed. They say `infra` "is not an infrastructure provider in its own right", and a new provider is "a change to NVKE, not configuration" with six parts (`$R/docs/operate/infrastructure-providers.md:60-71`).
- The `infra` schemas have `x-fern-ignore: true` (`$R/controller/api/openapi.yaml:3154-3155`).

What it means for a pod provider:

- The provider must give a provider ID and one stable address for the life of the Machine, and that address must be on an interface of the guest.
- A pod kind is treated as a real machine: the cloud-init status preflight, and the kubeadm system check on.
- The provider must not use the field names `status.instanceID`, `status.machineID` or `spec.instanceTypeID` for its own data (deduction).
- The endpoint must be in the request before create, because NVKE ignores an endpoint on the infra cluster.

## 2. Bootstrap data

| Who | What | Source |
|---|---|---|
| NVKE | Makes the Secret. Cloud-config text: `write_files` (caller `bootstrapFiles`, trust bundle, `agent.conf` with the join token, agent environment file) and `runcmd` (caller `preKubeadmCommands`, then a restart of the agent unit) | `$C/clients/capi/bootstrap_userdata.go:70-164`, `$C/temporal/activities/activities.go:64-93` |
| NVKE | Order: infra machine, join token, Secret, Machine | `$C/clients/capi/machine.go:75-115` |
| NICo, LaunchLayer | The provider gives the Secret to the machine as user data. cloud-init in the image applies it | `$R/docs/operate/infrastructure-providers.md:36-38` |
| nico-sim containers | Parses the cloud-config, writes each file by exec and copy, runs the commands detached, writes `running`, `done` or `error` to a status file that a `cloud-init` shim prints | `$R/controller/nico-sim/internal/container/docker.go:136-221`, `$R/controller/hack/capd-kindest-node/Dockerfile:61-67` |
| nico-sim VMs | A metadata server gives the user data to real cloud-init | `$R/controller/nico-sim/internal/cloudinit/metadataserver.go:26-60` |
| e2e substrate | Does not use the Secret. `agent.conf`, the CA and the status `done` are in the image. Identity is a software TPM | `$R/cli/e2e/bootstrap/substrate/node/Dockerfile:32-38`, `:71-78` |
| Provisioned provider | Does not read the Secret. Its `secrets get` right is for the kubeconfig | `$P/controllers/machine_controller.go:26-31`, `tenant_client.go:58` |
| Reference image | Unit order: cloud-init, `nvke-spire-configure`, `spire-agent`, `nvke-agent` (waits for the SPIRE socket) | `$R/os-image/SPEC.md:33`, `$R/os-image/files/nvke-spire-configure.service:10-11`, `spire-agent.service:7-9`, `nvke-agent-spire.conf:8-12` |
| Preflight | The agent runs `cloud-init status --long`. A regular file `/var/lib/dsxos/.cidata-consumed` also passes | `$C/temporal/activities/node_preflight.go:116-119`, `$R/agent/internal/agent/preflight.go:98-126` |

The Cluster API contract text is not in this tree. Upstream, from memory of the agent and not checked: the infra machine controller waits for `dataSecretName`, reads the key `value` and gives it to the instance as user data.

What it means for a pod provider:

- The provider waits for the owner Machine, reads `spec.bootstrap.dataSecretName`, and puts the cloud-config into the pod before the pod starts, for example as a mounted volume.
- The image needs one unit, ordered before the SPIRE agent unit, that applies `write_files` and `runcmd`. The image must answer the cloud-init status check.
- The Secret is in the management namespace, so the pods run there or the provider copies it.
- NVKE renders the Secret again only when `CreateMachine` runs again, so the SPIRE data folder must be on the volume.

## 3. Delete

1. Node teardown asks for the Machine delete and does not wait (`$C/temporal/workflows/teardown_node.go:444-471`). Then it deletes the node row (`:170`).
2. Cluster teardown order: node pools, control plane nodes, etcd key Secret, `DeleteCAPIClusterResources`, cluster row (`teardown_cluster.go:46-75`).
3. `DeleteCAPIClusterResources` waits for zero Machines with the cluster label (poll each 2 s), then deletes the infra cluster and waits, then the Cluster and waits (`$C/temporal/activities/capi_cluster_resources.go:63-91`, `:103-128`). Each attempt has 20 minutes, and the attempts have no limit (`workflows/shared.go:38-49`).
4. The provider puts a finalizer on each machine (`$P/controllers/machine_controller.go:42`, `:129-136`). On the delete of a machine with a provider ID or a claim it sets `DeletionNotSupported` and returns. No code removes the finalizer (`:104-127`).
5. Claims are cluster scoped with no owner, and the provider has no delete right on them (`:30`, `claims.go:79-93`, `:123-128`).
6. This is the recorded intent: "bootstrap-only", with a TODO (`:121-122`, `$P/README.md:77-87`).
7. Deduction (upstream): Cluster API keeps a Machine until its infra machine is gone, so the count never reaches zero.

NVKE itself removes the SPIRE entry (`$C/controllers/capi/machine_spire_entry_controller.go:76-81`) and the Secret (`capi_node_resources.go:191-203`).

What it means for a pod provider:

- On the delete of its machine object the provider deletes the pod, applies its volume rule, frees the address and removes its finalizer, in each state of the machine.
- It must not hold the infra cluster when no machine is left.
- NVKE gives no order between "pod gone" and "node row gone", so the provider cannot rely on a kubeadm reset.

## 4. Replace, remediation, recycling, scale

Files with no prefix in this table are in `$C/controllers/controlplane/`, `$C/temporal/workflows/` or `$C/temporal/activities/`.

| Flow | Trigger and gate | New Machine | Source |
|---|---|---|---|
| Delete through the API | The intent is recorded. Needs a VIP or endpoint and a joined survivor. One teardown at a time: drain, graceful shutdown, etcd member remove, kubeadm reset, Machine delete, Node delete. Then scale up refills | Yes, with a new name | `$C/nodes/control_plane_delete.go:85-97`, `delete.go:33-85`, `teardown_node.go:180-273` |
| Unhealthy node | Only a node with `MarkedForRecycling` is replaced. It comes from the Node condition `NeedsRecycle`, which an outside system sets. Not Ready alone starts nothing. Delete first, then scale up | Yes | `controlplane.go:108-117`, `remediation.go:21-74`, `:122-214`, `$C/controllers/tenant/nodestatus/conditions.go:15-27`, `$R/docs/tenant-clusters/node-lifecycle.md:54` |
| Stuck in provisioning | The monitor skips control plane nodes. A pending node is placed again only on a capacity signal, which the `infra` client never gives | No | `$C/controllers/nodeprovisioningmonitor/controller.go:107-110`, `stuck_pending.go:35-47`, `:118-135`, `$C/clients/capi/rotation.go:28-32` |
| Scale up | `desiredCount` above the node count: a pending node with a failure domain, then the infra machine, the Secret, the Machine | Yes | `reconciler.go:295-330`, `scale.go:46-131` |
| Scale down | Surplus above `desiredCount`. Holds at the fault tolerant floor | No | `scaledown.go:22-92` |
| Recycle | The pinned config differs in the Kubernetes version, `infra.machineTemplate`, bootstrap files or commands. Needs `enableCPNodeRecycling`. With `maxSurge: 1` a new node comes first, in the failure domain of the node it replaces | Yes | `$C/db/control_plane_configurations.go:280-333`, `upgrade.go:37-71`, `:148-153` |
| Hard reboot | The reboot annotation on the Machine. The provider acts | No | `capi_node_resources.go:506-561`, `$C/clients/capi/rebootannotation.go:10-15` |

- Each replace gate needs a stable endpoint (`controlplane.go:29-31`).
- With the provisioned provider each new Machine takes a free inventory host (`$P/controllers/machine_controller.go:256-268`). A host never returns, and the inventory is fixed (`$P/api/v1alpha1/provisionedcluster_types.go:52-53`). So each flow with "Yes" uses up one spare host. The README forbids rollouts, scale down and remediation (`$P/README.md:85-87`).

What it means for a pod provider:

- A new Machine is a new pod with a new name, a new empty volume and its own address, made on demand, with no spare.
- A new pod for the same Machine is a different event that NVKE does not know. Phase 1 showed that NVKE keeps the node then.
- No part of NVKE starts a replace when a host node is lost.
- A surge at a rollout puts two control plane pods in one failure domain for a time.

## 5. Upgrade

- NVKE replaces nodes. Steps: the kubeadm ConfigMap, the condition "upgrading", a recycle of each node, then `kubeadm upgrade apply` through the agent of one joined node for the add-ons (`$C/controllers/controlplane/k8s_upgrade.go:42-146`, `$C/temporal/activities/kubeadm_upgrade.go:34-37`, `:79-81`).
- Docs: "adding each new node before it removes an old one" (`$R/docs/workload-clusters/upgrade.md:11-17`). Image contract: "Nodes take updates through a new image, never in place" (`$R/os-image/SPEC.md:31`).
- NVKE does not check the kubeadm version of a node. There is a FIXME (`k8s_upgrade.go:150-151`).
- The reference image stages one `nvke-kubeadm-distro-<version>` package for each version, and a `runcmd` installs one (`$R/docs/operate/prepare-nodes.md:17-25`, `:44-46`). The controller calls no package or bundle RPC.
- CAPD: the image name is in the template. The script builds the image again under the same name before the version PATCH (`$R/controller/hack/capd-upgrade.sh:7-10`).
- The CNI install after init reads charts from a package on the node (`values.yaml:459-463`).

What it means for a pod provider:

- No in place path is needed.
- The new pod must have the Kubernetes version of `Machine.spec.version`. Three ways: an image tag that the provider picks, a template change in the same PATCH, or one image with several staged versions and a `runcmd`. The last way needs a provider that runs the commands of the cloud-config.

## 6. Mixed providers

| Level | Rule | Source |
|---|---|---|
| Cluster | Exactly one of `infra`, `nico`, `launchLayer`, fixed at create | `$C/server/clusters.go:390-419`, `openapi.yaml:119-122` |
| Control plane | An `infra` cluster rejects `controlPlaneConfig.nico`. A `nico` cluster rejects `controlPlaneConfig.infra`. No control plane node pools | `$C/server/cluster_control_plane_config.go:150-154`, `:184-186`, `:294-296` |
| Node pool | The provider type of the cluster decides | `$C/server/node_pools.go:274-299`, `:325-328` |
| Docs | "the control plane and every node pool must carry the same one" | `$R/docs/first-cluster.md:161-162` |
| Template kind | On `infra`, the control plane and each pool carry their own template. The only check is the API group. Code handles a `NicoMachine` from a template | `$C/clients/capi/nodepoolvalidate.go:13-19`, `machine.go:120-147`, `spireagent.go:21-25` |
| CAPNICo CRD | `NicoMachine.spec.siteID`: "When set, the controller does not read a NicoCluster" | `$R/deploy/nico/capnico/capnico.yaml:908-913` |
| Attestation | One method for a deployment, pinned on each new node | `$C/nodes/agent_profile.go:14-22`, `$R/docs/operate/infrastructure-providers.md:58` |

- Not possible today on the product path: a `nico` cluster cannot have an `infra` control plane.
- Deduction, not tested: an `infra` cluster can carry a pod template for the control plane and a `NicoMachineTemplate` with `siteID` for a pool. Such a pool loses what the `nico` client does (release, OS image, user data template, `$C/clients/nico/machine.go:114-175`), and it gets the attestation method of the deployment.

What it means for a pod provider: mixed clusters need either the `infra` path for the whole cluster, with the caller in charge of the NICo template content, or a controller change that lets the control plane provider differ from the cluster provider. In both cases one attestation method for each deployment is a second limit.

## 7. `cluster-api-provider-provisioned`

| Part | Fact | Source |
|---|---|---|
| Module | Its own Go module in the workspace. Imports nothing from the controller, "can move to its own module or repository without a code change" | `$R/go.work`, `$P/controllers/inventory.go:4-10` |
| Kinds | `ProvisionedCluster` (inventory), `ProvisionedMachine` (`providerID` immutable, `hostSelector`), `ProvisionedMachineTemplate`, `ProvisionedHostClaim` (cluster scoped lock) | `$P/api/v1alpha1/provisionedcluster_types.go:14-56`, `provisionedmachine_types.go:13-32`, `provisionedhostclaim_types.go:18-66` |
| Controllers | Cluster: checks the inventory, sets `provisioned`, no finalizer. Machine: finalizer, claim, provider ID, TPM path annotation, addresses, Node provider ID | `$P/controllers/cluster_controller.go:78-136`, `machine_controller.go:93-181`, `:243-337`, `:397-509` |
| Claim model | The provider ID is the record. The used set is derived at each reconcile. The claim object locks a host across clusters. First free host in inventory order | `inventory.go:27-81`, `claims.go:50-129` |
| Rights | None on pods. No delete on claims | `machine_controller.go:26-31` |
| Tests | 50 test functions with the fake client, no envtest. The site bootstrap e2e uses it | `$P/controllers/test_helpers_test.go:5-36`, `$R/cli/e2e/bootstrap/run.sh:708` |
| Build | Makefile: test, lint, generate, manifests, image for two architectures | `$P/Makefile:40-161`, `$P/Dockerfile:20-52` |
| Release | Its own image workflow and tag form. Release component `capi-provisioned`, in the qualification list | `$R/.github/workflows/image-provisioned-nvcr.yml:42-57`, `tag-publish.yml:221`, `$R/release/registry.yaml:67-70`, `qualification.yaml:39` |
| Install | kustomize `config/default`, clusterctl files, and a copy inside `nvkectl bootstrap site`. No Helm chart | `$P/README.md:89-109`, `$P/hack/release-manifests.sh:16-19`, `$R/cli/internal/bootstrap/controllerdeploy/embed.go:26-28`, `capi.go:353-380` |
| Scope on record | "bootstrap-only", "temporary CAPI provider", "not a tenant-cluster infrastructure provider and is not installed on a site cluster" | `$P/README.md:85-87`, `$R/docs/site-bootstrap/pre-provisioned-nodes.md:13`, `$R/docs/site-bootstrap/infrastructure-providers.md:197` |

What it means for a pod provider:

- A pod mode inside this provider goes against its recorded scope and its rights. It creates nothing and deletes nothing.
- The module layout, CI and release entries are a ready pattern for a second module beside it.
- The NICo and LaunchLayer providers show the third pattern, a repository of their own.

## 8. The node image

- `os-image/` gives a QCOW2 from Packer and QEMU only (`$R/os-image/README.md:22-33`).
- Its contract (`$R/os-image/SPEC.md`): Ubuntu 26.04 or 24.04 with the NVIDIA kernel (`:20-21`), `nvke-agent` on 15005 with mTLS (`:22`), `spire-agent` with a join token or TPM (`:23-25`), DOCA Open vSwitch in kernel mode (`:28`), the etcd folder (`:29`), masked apt and multipath (`:30-31`), the unit order (`:33`). Identity data comes at first boot, never in the image (`:96-104`). It is "not a cluster-ready Kubernetes image" (`:5-8`).
- `capd-kindest-node` adds, on `kindest/node` (`$R/controller/hack/capd-kindest-node/Dockerfile`): a reboot shim (`:36-48`), a kubeadm wrapper for the system check (`:50-59`), a `cloud-init` status shim (`:61-67`), stock Open vSwitch and netplan (`:75-90`), a container network unit and an Open vSwitch drop in (`:101-112`), the agent and the SPIRE agent (`:153-175`), a software TPM (`:224-232`), a kubelet swap flag (`:238-239`), agent arguments with `NKE_LOCAL_DEV` (`:242-257`). It keeps the kind entrypoint.
- The e2e substrate image derives from it (`$R/cli/e2e/bootstrap/substrate/node/Dockerfile:21-22`, `:80-83`).
- Packages as `.deb` builds: `$R/os-image/packages/` (agent, SPIRE agent, kubeadm distro, CNI, DOCA Open vSwitch).

What it means for a pod provider:

- A pod image needs: systemd as the entrypoint, the agent and SPIRE agent units in the reference order, a unit that applies the bootstrap data, a cloud-init status answer, Open vSwitch, containerd, and the Kubernetes and CNI packages.
- In a Kata guest it does not need the kubeadm wrapper, the swap flag or the software TPM (deduction from phase 1).
- The repository has no place for a container node image for production. `os-image/` builds only QCOW2, and the CAPD image is under `hack/`.

## 9. Failure domains and placement

- NVKE reads the domains from the Cluster, picks the least used one and writes it to the node and to `Machine.spec.failureDomain` (`failure_domain_discovery.go:56-94`, `failure_domain_assignment.go:22-38`, `:84-93`, `scale.go:103`, `$C/clients/shared/machine.go:198`). A later apply keeps the domain (`:213-229`). Scale down keeps the spread (`scaledown.go:61`).
- With no domain NVKE asks for none (`failure_domain_assignment.go:32-38`).
- The provisioned provider has no failure domains in its status (`$P/api/v1alpha1/provisionedcluster_types.go:80-105`). Placement is inventory order plus `hostSelector`, which is the same for all machines of one template (`inventory.go:65-81`).

What it means for a pod provider:

- The rule can live in NVKE with no NVKE change: the provider publishes one domain for each host node or zone with `controlPlane: true` and turns `Machine.spec.failureDomain` into a node rule of the pod.
- A strict anti affinity rule in the pod would block the surge of a rollout.
- NVKE cannot learn "no capacity in this domain" from an `infra` provider.

## 10. What the repository records

| Item | Source |
|---|---|
| Roadmap, "Working on it": "Run control planes on virtual machines" and "more Cluster API providers, including virtual machine nodes". The roadmap is "direction, not commitments" | `$R/ROADMAP.md:3-5`, `:28-29` |
| Roadmap: manage the nodes of the management cluster through NVKE (coming soon). Separate control plane and worker networks | `$R/ROADMAP.md:18`, `:30` |
| ADR, status proposed: three layers, a control plane provider (`NVKEControlPlane`), hosting models that include "hosted control planes", the REST API retired, first providers as shims | `$R/docs/adrs/20261105-capi-architecture.md:3`, `:32-34`, `:59`, `:152-157` |
| Proposal "BYO-OS": the operator owns the OS. Kubernetes and CNI packages come later through the agent | `$R/docs/design/byo-os.md:3-5`, `:106-129` |
| Management cluster nodes run Kata workloads. The 26.04 image loads erofs and dm-verity for the Kata snapshotter | `$R/deploy/nico/spire/values.yaml:70-81`, `$R/os-image/SPEC.md:32` |
| Virtual machines as nodes today: LaunchLayer `vmProfile`, and nico-sim VMs for development | `$R/docs/operate/provider-launchlayer.md:78`, `$R/controller/nico-sim/README.md:6-9` |
| KubeVirt: only in the audit policy | `$C/kubeadmconfig/audit_policy.yaml:88-89` |

Not found: a hosted control plane in code, pods as nodes, Kata as the runtime of a node, a feature flag for any of these.

What it means for a pod provider: the note should name the roadmap item on control planes on virtual machines and the proposed ADR, and say how a pod provider relates to a later `NVKEControlPlane` provider. It should not call `infra` a product path.

## Design decisions that the source leaves open

1. Where does the provider live? A mode inside the provisioned provider, a new module beside it, or a repository of its own.
2. How does NVKE use it? The `infra` path with caller manifests and one extra RBAC object, or a first class provider with its own request object and provider client.
3. How does the bootstrap data reach the guest? A mounted Secret or copy, an init container, or exec. Which part answers the cloud-init status check: real cloud-init, a shim, or the marker file?
4. In which namespace do the pods run, given that the Secret is in the management namespace?
5. Which identity do pods use? A join token with the SPIRE data on the volume, or a new attestor. What happens when the SPIRE data is lost?
6. Is a new pod for the same Machine a provider event (like a reboot), and does the reboot annotation map to it?
7. Who starts a replace after a host node loss? An outside system that sets `NeedsRecycle`, the provider, or a new NVKE rule.
8. Who gives a new Machine its address? A pool in the infra cluster object, an IPAM object, or one Service for each Machine.
9. Who makes the shared endpoint, and when? The caller before the request, or the provider with an NVKE change that reads the endpoint from the infra cluster.
10. What happens to volumes at a Machine delete?
11. What is a failure domain: a host node, a rack or a zone? Does NVKE place, or the scheduler of the host cluster?
12. Should two control plane pods of one cluster share a host node during a surge, or should upgrades run with `maxSurge: 0`?
13. Who maps the Kubernetes version to the pod image: the provider, the caller, or a `runcmd` in one image with several versions?
14. Where is the pod node image built, and from which packages?
15. Mixed clusters: the `infra` path for the whole cluster, or a controller change for a control plane provider that differs from the cluster provider? One attestation method for each deployment, or one for each pool?
16. Should the provider report "no capacity", which needs a provider client in NVKE today?

## What the agent could not determine

- The text of the Cluster API contract for bootstrap data and for the delete order. It is not in the tree.
- Whether the template kind needs a CRD, and whether the controller needs `get` on the CRDs of a new kind. Both depend on upstream functions.
- How CAPNICo acts for a `NicoMachine` whose cluster has another infra kind. Only the CRD text is in the tree.
- Whether a Kata pod can see a mounted Secret before systemd starts its units.
- Where NVKR builds node images, and whether a container image fits there.
- What sets `NeedsRecycle` on a control plane node in a real site.
- The worker node pool flows on the `infra` path (node pool controller) and `management-engine`. The agent did not read them in depth.

## Files that matter most for an implementation

- `cluster-api-provider-provisioned/controllers/machine_controller.go`
- `controller/internal/clients/capi/machine.go`
- `controller/internal/temporal/activities/capi_node_resources.go`
- `controller/internal/temporal/activities/capi_cluster_resources.go`
- `controller/internal/controllers/controlplane/reconciler.go`
