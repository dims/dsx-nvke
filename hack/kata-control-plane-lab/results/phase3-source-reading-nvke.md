# Phase 3 source reading of NVKE for a control plane in pods with workers on NICo

State on 2026-11-27 at 15:57. I read source only. I changed no code, and I ran no cluster and no test. Each statement comes from the source at the given place. The mark "(deduction)" is on each statement that the source does not state directly.

The plan for phase 3 is `nvke-control-planes-as-kata-pods.md`. The open problem from phase 2 is "a cluster has exactly one provider today" (`results/phase2-results.md`, sections 5 and 7).

What I read, with the short names that the references use:

- `$R` is the NVKE checkout `/home/dsrinivas/go/src/github.com/nvidia/nvke` at commit `d625fcfa`. `$C` is `$R/controller/internal`.
- `$N` is CAPNICo, the NICo provider for Cluster API, at `v0.1.0` in the Go module cache (`github.com/dsx-ai-factory/cluster-api-provider-nico`, the version of `$R/controller/go.mod:9`). The install manifest of NVKE runs the image `v0.3.0-rc.1` (`$R/deploy/nico/capnico/capnico.yaml:2180`). I read the Go source of `v0.1.0` and the CRD text of `v0.3.0-rc.1`.
- `$K` is Cluster API `v1.13.7` in the Go module cache (`$R/controller/go.mod:67`).
- `$P` is the provider of the lab, `/scratch/kata-cp/src/nvke-podvm/cluster-api-provider-podvm` at commit `d2880014`.
- `$E` is the branch with the request field `controlPlaneEndpoint`, `/scratch/kata-cp/src/nvke-endpoint` at commit `c6d669ef`.

## Summary

- "One provider for a cluster" is a rule of the request checks and of 13 small factory functions. All of them read one column, `clusters.provider_type`. The node pool, the node set and the node already store their own provider data, and most controllers already act on one Machine.
- The `infra` path already lets the control plane and each node pool carry its own machine template. The only check is the API group. NVKE has code for a `NicoMachine` that comes from such a template.
- CAPNICo already supports a `NicoMachine` in a Cluster whose infrastructure cluster object is from another provider. The machine carries `spec.siteID`, and CAPNICo then reads no `NicoCluster`.
- The mock NICo flow of the repository uses the `infra` path with `NicoMachineTemplate` manifests today.
- A lab can test a control plane in pods with workers on the mock NICo with no new NVKE code (deduction, not tested). The request is one `infra` cluster with a `PodVMCluster`, a `PodVMMachineTemplate` for the control plane and a `NicoMachineTemplate` with `siteID` for each pool.
- The limits of that form are one SPIRE attestation method for a deployment, OVN settings that are the same for each node of a cluster, and a pool that has none of the functions of the `nico` request object.
- NVKE has no code, no setting and no doc for Konnectivity.

## 1. Where "one provider for a cluster" is decided and enforced

### The provider types

NVKE has three provider types, `nico`, `capi` and `launchlayer` (`$C/db/clusters.go:29-41`). The comment says that the type names "who authors the manifests, not ... whether CAPI reconciles the cluster". The API names are `nico`, `infra` and `launchLayer` (`$C/config/config.go:22-27`). Each type has one client package under `$C/clients`. The deployment setting `supportedInfraProviders` lists the request objects that the API accepts (`$C/config/config.go:205-207`, `$C/server/providers.go:18`).

### Where the rule is

| Place | Rule | Reference |
|---|---|---|
| API schema, cluster create | Exactly one of `nico`, `infra`, `launchLayer`. "The provider payload is fixed at creation" | `$R/controller/api/openapi.yaml:1076-1092` |
| API schema, control plane config | "The control plane follows its cluster's provider" | `openapi.yaml:1394-1412` |
| API schema, node pool | "The provider follows the cluster's and is fixed at creation" | `openapi.yaml:1819-1830` |
| Handler, cluster create | Takes the type from the one request object that is set | `$C/server/clusters.go:392-422` |
| Handler, control plane config at create | An `infra` cluster refuses `controlPlaneConfig.nico`. A `nico` cluster refuses `controlPlaneConfig.infra` | `$C/server/cluster_control_plane_config.go:170-180`, `:184-187`, `:242-248` |
| Handler, control plane config at update | The request object must match the type of the cluster | `$C/server/clusters.go:797-821`, `$C/server/cluster_control_plane_config.go:264-275` |
| Handler, node pool create | The type of the cluster picks the check. Each check refuses the other request objects | `$C/server/node_pools.go:274-294`, `:296-299`, `:325-331` |
| Handler, node pool update | The same | `$C/server/node_pools.go:630-691`, `:726-741`, `:791-817` |
| Database, cluster | One column `provider_type` and three payload columns. Each setter clears the two other payloads. `NicoProvider()` returns an error for a cluster of another type | `$C/db/clusters.go:94-97`, `:127-135`, `:185-206` |
| Database, node pool and node set | No type column. Three payload columns each. `ResolveProviderType` derives the type from the payload that is set | `$C/db/node_pools.go:205-212`, `:273-288`, `$C/db/node_sets.go:40-42`, `:98-109` |
| Database, node | Its own `nico` and `launch_layer` payloads, and its own agent profile | `$C/db/nodes.go:38-41`, `:52-54` |
| Provider client | `GetProviderClient(cluster)` calls 13 factories. Each factory is a `switch` on `cluster.ProviderType` | `$C/clients/provider.go:84-152`, for example `$C/clients/machine.go:55-66` |
| Docs | "the control plane and every node pool must carry the same one" | `$R/docs/first-cluster.md:161-162` |
| Docs | "The provider set is closed". A new provider needs a request object, a client, a chart rule and an entry in `nvkectl` | `$R/docs/operate/infrastructure-providers.md:60-70` |

- No code outside the tests calls `ResolveProviderType` of a node pool or of a node set (search of `$R`).
- I found no database constraint that ties the payload of a pool to the type of the cluster (deduction from a search of `$C/db/migrations`).

### Each place that picks a provider client

| Call site | What it asks for | What the call site holds |
|---|---|---|
| `$C/capi/resources.go:106` | The manifest of the infrastructure cluster object | The cluster |
| `$C/kube/tenant_client.go:115` | How NVKE reaches the API of the tenant cluster | The cluster |
| `$C/temporal/activities/capi_node_resources.go:75` | `CreateMachine` | The node, its node set and its node pool |
| `$C/temporal/activities/capi_node_resources.go:232` | The message and the retry for a waiting Machine, and the identity of the instance | The node, its node set, its node pool and the Machine |
| `$C/temporal/activities/capi_node_resources.go:524` | The annotation keys for a hard reboot | The node |
| `$C/temporal/workflows/provision_node.go:672` | The machine ID label of the Node | The node |
| `$C/temporal/activities/configure_kube_vip.go:110` | The source of the BGP peer number | A control plane node and its pool |
| `$C/controllers/nodepool/controller.go:239` | The payload of a new node set | The node pool |
| `$C/controllers/nodeset/controller.go:251` | The payload of a new node | The node pool |
| `$C/controllers/controlplane/reconciler.go:68`, `:84` | The node payload and the Machine checks for scale up, rollout and rebalance | The cluster and its control plane nodes |
| `$C/nodes/context.go:86` | The node set and node pool records that NVKE builds for a control plane node | The control plane config of the node |
| `$C/server/node_pools.go:312`, `:347`, `:367`, `:744`, `:762`, `:849` and `$C/server/cluster_control_plane_config.go:197`, `:232` and `$C/server/clusters.go:355`, `:369` | The checks of a request | The request |

Two of the 13 functions belong to the cluster by their nature. Cluster API allows one infrastructure cluster object for a Cluster, and the tenant API has one address. Each of the other 11 functions already holds a node, a node set, a node pool or a control plane config when it runs. It still picks its client by the type of the cluster.

### What already works for one node pool or one node

- The machine template. On the `infra` path the control plane config and each pool carry their own template, and the only check is the API group `infrastructure.cluster.x-k8s.io` (`$C/clients/capi/manifestvalidate.go:47-74`, `$C/clients/capi/nodepoolvalidate.go:13-19`).
- A `NicoMachine` from a template. The `capi` client puts the NVKE instance labels on it (`$C/clients/capi/machine.go:120-147`), returns the reboot key of CAPNICo (`$C/clients/capi/rebootannotation.go`), and records the instance and machine IDs (`$C/clients/capi/newnode.go`). The comments name the case "a CAPI template may render a NicoMachine".
- The controllers that act on the infrastructure kind of one Machine. `NicoSpiffeController` and `NicoProviderIDController` watch each `NicoMachine` (`$C/controllers/capi/nico_spiffe_controller.go:46-88`, `$C/controllers/capi/nico_provider_id_controller.go:61-66`). NVKE starts them when the `NicoMachine` CRD exists, not by the type of a cluster (`$R/controller/cmd/worker/main.go:389-409`). `MachineSpireEntryController` acts on each Machine (`$C/controllers/capi/machine_spire_entry_controller.go:54-62`).
- The connection to the node agent. NVKE stores the profile on each node, and the transport reads the profile of the node (`$C/db/nodes.go:38-41`, `$C/agent/transport.go:136-157`).
- The config profile and the kubeadm container mode. Both read the payload of the node set (`$C/temporal/activities/get_node_config_profile.go:51-58`, `$C/temporal/activities/capi_shared.go:41-63`). The container mode has a guard on the cluster type `capi` before it (`capi_shared.go:37-39`).
- The kubelet serving certificate. NVKE approves it by the node name and the node IP (`$C/controllers/tenant/csr/controller.go:332-345`, `:413-435`).
- The delete of a node. NVKE deletes the Machine, and Cluster API deletes the infrastructure machine (`$C/temporal/activities/capi_node_resources.go:137-211`).

### What is a setting of the whole deployment

- The SPIRE attestation method and the transport of the agent. `PinAgentProfile` copies them from the controller config to each new node (`$C/nodes/agent_profile.go:14-22`, called at `$C/controllers/nodeset/controller.go:250` and `$C/controllers/controlplane/scale.go:116`). The docs say "The node attestation method applies to every new node of a deployment" (`$R/docs/operate/infrastructure-providers.md:58`).
- The soft reboot, `NODE_REBOOT_SOFT_REBOOT_ENABLED` (`$C/config/config.go:232-237`).
- `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP`, which puts each node of each cluster on the contract of a container node (`$C/config/config.go:372-381`, `$C/temporal/activities/capi_shared.go:20-29`).

## 2. What a cluster on NICo does today

### The request and the objects

The caller gives `nico` with `orgID`, `siteID` and `vpcID` (`$C/server/clusters.go:508-519`). The control plane config needs `nico.instanceTypePreference` and `nico.release` (`$C/server/cluster_control_plane_config.go:242-259`). A pool needs `nico.instanceTypeID` and `nico.release` (`$C/server/node_pools.go:325-352`).

NVKE makes the following objects in the management namespace:

- One `Cluster` with an `infrastructureRef` and no control plane reference (`$C/capi/resources.go:58-78`).
- One `NicoCluster` with the site ID and the label key `failure_domain` (`$C/clients/nico/scaffold.go:29-49`).
- For each node one `NicoMachine`, one Secret `<node>-bootstrap-data` and one `Machine` (`$C/clients/nico/machine.go:114-176`, `$C/clients/shared/machine.go:145-206`).
- For each Machine one SPIRE `ClusterStaticEntry` (`$C/controllers/capi/machine_spire_entry_controller.go:104-115`).
- The Secret `<cluster>-kubeconfig`, the Secret of the cluster CA, and the endpoint in `Cluster.spec.controlPlaneEndpoint`. NVKE reads the values from the admin kubeconfig of a joined control plane node (`$C/controllers/tenantaccess/capi_contract.go:38-80`, `:113-147`, `$C/controllers/tenantaccess/controller.go:47`).

NVKE makes no `KubeadmControlPlane`, no `MachineDeployment`, no `MachineSet` and no template object. A search of `$C` and of `$R/management-engine` finds no use of these kinds outside the tests.

### How NVKE makes a NICo machine

The source calls the path "template-less" (`$C/clients/nico/bootstrap_userdata.go:24`), because NVKE builds the `NicoMachine` and the caller gives no template.

1. NVKE reads the release by its name. A control plane node reads a `ClusterRelease`, and a worker reads a `NodePoolRelease`. The release names a `MachineImage` with the iPXE script and a template for the user data (`$C/clients/nico/release.go:28-44`).
2. NVKE builds the `NicoMachine` from the pool. The fields are the VPC, the instance type, one interface, the InfiniBand and NVLink partitions, the SSH key groups, the iPXE script and the instance labels (`$C/clients/nico/machine.go:178-230`, `:248-257`).
3. NVKE renders the user data from the template of the release. The data has the host name, the Kubernetes version, the CNI packages, the agent port, the SPIRE server address and port, the trust bundle and the Teleport settings (`$C/clients/nico/bootstrap_userdata.go:79-204`).
4. NVKE applies the `NicoMachine`, the Secret and the Machine. The path makes no SPIRE join token (`$C/clients/nico/machine.go:109-113`).
5. CAPNICo makes the instance in NICo. NVKE waits until the Machine has an address (`$C/temporal/activities/capi_node_resources.go:217-285`).

### The control plane endpoint

- With `controlPlaneVIP`, NVKE configures kube-vip on each control plane node through the agent call `ReconcileKubeVip`. The call carries the VIP, the local BGP number, the node IP and the source of the peer number, which is a static value or the metadata service of the node (`$C/temporal/activities/configure_kube_vip.go:85-145`, `$C/clients/nico/kubevip.go:14-20`).
- Each control plane node advertises the VIP by BGP to its default gateway on port 179 (`$R/docs/operate/plan-installation.md:46`, `:61`).
- With no VIP, the endpoint is the IP of the first control plane node (`$C/temporal/activities/kubeadm_init.go:79-83`). Such a cluster has one control plane node, unless a development setting is on (`openapi.yaml:1131-1143`).
- kubeadm gets the value as its `controlPlaneEndpoint` (`$C/kubeadmconfig/init.go:317`).

### How a worker joins

- The workflow of the node makes the Machine, waits for the address, checks the agent, runs the preflight, configures Open vSwitch and then joins the node in the same workflow (`$C/temporal/workflows/provision_node.go:64-110`, `:211-247`).
- NVKE asks the agent of a joined control plane node for the join strings and takes the worker string (`$C/temporal/activities/kubeadm_join.go:93-105`, `:216-231`).
- NVKE renders a kubeadm join config and calls `ExecuteKubeadmJoin` on the agent of the worker (`kubeadm_join.go:115-186`). The config uses the bootstrap token and the endpoint of the join string, and it sets the kubelet `node-ip` to the node IP (`$C/kubeadmconfig/join.go:256-271`).
- After the join NVKE sets the labels and taints. With OVN it sets `k8s.ovn.org/zone-name=<node name>` (`provision_node.go:300-310`, `:684-688`).

### What the node agent needs on the machine

The image contract is `$R/os-image/SPEC.md`:

- `nvke-agent` on TCP port 15005 with mTLS (`SPEC.md:22`).
- `spire-agent` with the join token attestor or the TPM attestor, chosen at the first boot (`SPEC.md:23-25`).
- Open vSwitch from DOCA in kernel mode (`SPEC.md:28`).
- An OS that applies cloud-init user data (`$N/README.md:155`).
- kubeadm and the Kubernetes programs are not in the image. The agent installs them later (`SPEC.md:5-8`).

### What NVKE reads from the NICo side

I found no NICo API client in the controller code (deduction from a search of `$C` and `$R/controller/cmd` for the NICo SDK). NVKE reads the `NicoMachine` object that CAPNICo fills:

- The address, through the Machine (`capi_node_resources.go:262-285`, `$N/controllers/nicomachine_controller.go:411-416`).
- `status.instanceID` and `status.machineID`, for the node record (`$C/clients/shared/machine.go:48-72`).
- `status.tpmEkPubHash` or `status.primaryDPUMachineID`, for the SPIRE agent path (`$C/controllers/capi/nico_spiffe_controller.go:166-184`).
- `spec.providerID`, the machine ID and the site and VPC names, for the provider ID and the labels of the tenant Node (`$C/controllers/capi/nico_provider_id_controller.go:178-198`).
- The reasons of the conditions, for example `FailureDomainUnavailable` and `InstanceTypeUnavailable`, for the retries of a waiting Machine (`$C/clients/nico/failuredomain.go:37-44`, `$C/clients/nico/rotation.go:73`, `:240`).
- The failure domains of the `NicoCluster`, through `Cluster.status.failureDomains`, for the place of each control plane node (`$C/controllers/controlplane/failure_domain_discovery.go:38-67`).

NVKE writes two Machine annotations for CAPNICo, the reboot key and the machine health issue key (`$R/deploy/nico/capnico/capnico.yaml:2171-2172`, `capi_node_resources.go:158-173`, `:536-541`).

## 3. What the `infra` path does

### What the caller gives

- `infra.cluster`, one manifest of an infrastructure cluster object (`openapi.yaml:3118-3131`).
- `controlPlaneConfig.infra` with `machineTemplate`, `bootstrapFiles` and `preKubeadmCommands` (`openapi.yaml:3641-3664`).
- For each pool `infra` with the same three fields (`openapi.yaml:3380-3402`).
- On the lab branch `$E`, the field `controlPlaneEndpoint`.

NVKE checks that each manifest has an `apiVersion` and a `kind` and that the group is `infrastructure.cluster.x-k8s.io` (`$C/clients/capi/manifestvalidate.go:47-74`). It refuses a bootstrap file at one of the two SPIRE paths (`$C/server/node_pools.go:226-245`). It does not compare the kind of a machine template with the kind of `infra.cluster` (deduction from the checks at `$C/server/clusters.go:491-506`, `$C/server/cluster_control_plane_config.go:184-205` and `$C/server/node_pools.go:296-323`).

### What NVKE owns

- The infrastructure cluster object under the name of the cluster, and the `Cluster` that refers to it (`$C/capi/resources.go:26-86`).
- For each node, the infrastructure machine that NVKE renders from the template, a SPIRE join token when the node uses that method, the cloud-config Secret and the Machine (`$C/clients/capi/machine.go:62-118`).
- The cloud-config. It has the files of the caller, the trust bundle, the SPIRE `agent.conf` for the method of the node, the agent files, the commands of the caller and a restart of the agent unit (`$C/clients/capi/bootstrap_userdata.go:70-164`, `$C/clients/capi/capi_spire_agent.conf.tmpl`).
- The place of each control plane node in a failure domain, kubeadm through the agent, the CNI, the identity, the upgrades and the delete. The workflows are the same as for NICo.

The control plane and a worker pool differ only in the workflow. A control plane node joins through the control plane controller, one node at a time. A worker joins inside its own workflow (`provision_node.go:89-110`).

### What the `capi` client does not do

- It has no retry for a waiting Machine, and `FailureDomainUnavailable` is always false on main (`$C/clients/capi/rotation.go`).
- It has no release, so it has no OS image and no user data template. The caller gives the template with the boot script.
- It has no config profile, so it has no hooks. NVKE reads the profile name only from a `nico` payload (`$C/temporal/activities/get_node_config_profile.go:55-58`).
- It has no Teleport settings (`$C/clients/nico/bootstrap_userdata.go:52-68` is in the `nico` client only).
- It gives no machine ID label from the workflow (`$C/clients/capi/nodemachineidlabel.go`). `NicoProviderIDController` still writes the label for a `NicoMachine` (`nico_provider_id_controller.go:185-198`).

### Who uses the `infra` path in the repository

- The docs say that `infra` "accepts raw Cluster API manifests from the caller and is not an infrastructure provider in its own right" (`$R/docs/operate/infrastructure-providers.md:62`). The API fields have the mark `x-fern-ignore` (`openapi.yaml:1173-1175`, `:3119`, `:3381`, `:3642`).
- The mock NICo. "Mock NICo uses `infra`, supplying the `NicoCluster` and `NicoMachineTemplate` manifests directly; a real site uses `nico`" (`$R/docs/first-cluster.md:161-164`). The example request is `$R/cli/examples/nico-mock-cluster.yaml:33-97`.
- CAPD, with `$R/cli/examples/capd-cluster.yaml`.
- The site cluster with `cluster-api-provider-provisioned` (`results/phase1-source-reading.md`).
- The management engine. The `NVKECluster` reconciler reads three templates from one ConfigMap, with the keys `clusterTmpl`, `controlplaneTmpl` and `nodepoolTmpl`, and sends them to the NVKE controller as `infra` (`$R/management-engine/controllers/nvkecluster_controller.go:49-51`, `:138-180`, `:207-222`, `:607-611`). Its test data uses `NicoMachineTemplate` (`$R/management-engine/controllers/testdata/nvkecluster-update-nodepool-scale-up/expected_nvke_controller.yaml:20-37`).

## 4. The ways to get a control plane in pods and workers on NICo in one cluster

### What the Cluster API contract says

- A Cluster has one `infrastructureRef`. The infrastructure cluster object must report `status.initialization.provisioned`. A control plane endpoint and failure domains are optional (`$K/docs/book/src/developer/providers/contracts/infra-cluster.md:46-59`).
- The endpoint can come from the user, from the control plane provider or from the infrastructure provider (`infra-cluster.md:220-222`). NVKE writes it on the Cluster itself (`$C/controllers/tenantaccess/capi_contract.go:113-147`).
- `Cluster.status.failureDomains` comes only from the one infrastructure cluster object (`$K/internal/controllers/cluster/cluster_controller_phases.go:230-238`).
- The core Machine controller reads the infrastructure machine by the reference of the Machine, and it takes the contract version from the kind of that object (`$K/internal/controllers/machine/machine_controller_phases.go:244-300`). I found no check that compares the kind with the infrastructure kind of the Cluster (deduction from the absence in that file and in `$K/internal/webhooks/machine.go`).
- The contract for a machine controller says to stop when the Cluster cannot be found or its infrastructure is not ready (`$K/docs/book/src/developer/providers/contracts/infra-machine.md:620-632`). It does not say that the infrastructure cluster object must be of the same provider.

So Cluster API itself allows machines of two infrastructure kinds in one Cluster (deduction). What breaks is in each provider, because a machine controller reads its own cluster kind through `Cluster.spec.infrastructureRef`:

- CAPNICo reads the `NicoCluster` by the name in that reference (`$N/controllers/nicomachine_controller.go:742-751`). When `NicoMachine.spec.siteID` is set, it builds the settings from the machine and reads no `NicoCluster` (`:728-740`, `$N/api/v1alpha1/nicomachine_types.go:95-120`). The docs show a template that "supplies NICo settings independently of the provider named by `Cluster.spec.infrastructureRef`" (`$N/docs/api-reference.md:340-360`). The settings apply "throughout creation, adoption, placement, reboot, and deletion" (`$N/docs/architecture.md:69-74`). The CRD of the deployed version has the field (`$R/deploy/nico/capnico/capnico.yaml:908-913`).
- The provider of the lab refuses a Cluster whose infrastructure is not a `PodVMCluster` (`$P/controllers/machine_controller.go:266-276`).
- A machine of the second provider gets no failure domains in the Cluster. For a `NicoMachine` with `siteID`, the field `failureDomainLabelKey` "does not publish cluster failure domains" (`$N/docs/api-reference.md:323`).

I did not read the upstream issue 14373 that the plan names, because the task allows no network.

### Option A, one `infra` cluster with templates of two kinds

The shape is one request on the `infra` path:

- `infra.cluster` is a `PodVMCluster`.
- `controlPlaneConfig.infra.machineTemplate` is a `PodVMMachineTemplate`.
- Each worker pool has `infra.machineTemplate` with a `NicoMachineTemplate` that sets `spec.template.spec.siteID`, and the fields of the mock example (`vpcID`, `instanceTypeID`, `interfaces`, `ipxeScript`).
- `controlPlaneEndpoint` comes from the branch `$E`.

What the source already does for the shape:

- The request passes the checks, because each manifest has the right API group.
- The `capi` client makes the `NicoMachine`, the join token, the Secret and the Machine for each worker (`$C/clients/capi/machine.go:62-118`).
- CAPNICo makes the instance with the settings of the machine. With no `identityRef` it uses the credentials Secret of the provider (`$N/docs/architecture.md:96-98`, `:119-122`).
- NVKE sets the provider ID and the labels of the Node, and the reboot key works (`nico_provider_id_controller.go`, `$C/clients/capi/rebootannotation.go`).
- The failure domains of the Cluster come from the `PodVMCluster`, so they fit the control plane. A worker Machine asks for no failure domain, because no pool controller sets one (search of `$C/controllers/nodeset`, `nodepool`, `nodepoolnodescheduler` and `nodescheduling`).
- The delete removes the pools first, then the control plane nodes, then the two cluster objects (`$C/temporal/workflows/teardown_cluster.go:50-72`). CAPNICo needs no `NicoCluster` at the delete of a machine with `siteID` (`$N/controllers/nicomachine_controller.go:472`, `:728-740`).

What changes in NVKE is nothing for a lab (deduction). The deployment needs `infra` in `supportedInfraProviders`, CAPNICo with its chart rule (`$R/controller/deploy/charts/controller/templates/rbac-nico.yaml`), the rights for the pod kinds as in phase 2, and one attestation method for both kinds of node.

The option breaks nothing for clusters that exist, because no code changes.

What a pool loses is the list of section 3 under "What the `capi` client does not do". For a GPU pool on a site, the release, the config profile hooks and the retries are product functions.

### Option B, a provider for each node pool

The shape is a cluster whose pools may carry a request object of another type than the cluster. The control plane stays on the type of the cluster, which is `infra` today or a new type for pods later.

The files that change:

- The API schema at three places (`openapi.yaml:1076-1092`, `:1394-1412`, `:1819-1830`), and the generated code.
- The pool checks (`$C/server/node_pools.go:274-294`, `:630-691`, `:726-741`, `:791-817`).
- The 11 factories that work on a node. They must pick the client by the payload of the pool or of the node set. `ResolveProviderType` exists for both (`$C/db/node_pools.go:273-288`, `$C/db/node_sets.go:98-109`). The call sites are in the second table of section 1.
- The `nico` client. It reads the site, the organization and the VPC from the cluster (`$C/clients/nico/machine.go:80`, `$C/clients/nico/bootstrap_userdata.go:56`), and `Cluster.NicoProvider()` refuses a cluster of another type (`$C/db/clusters.go:127-135`). The same call is in the Teleport controller and in the metrics (`$C/controllers/teleporttoken/controller.go:450`, `$C/dbmetrics/dbmetrics.go:389-390`). The client must also set `siteID` on the `NicoMachine`, which it does not do today (`$C/clients/nico/machine.go:207-229`).
- The attestation method. The `nico` client makes no join token (`$C/clients/nico/machine.go:109-113`), and the method is one for the deployment. A pod has no TPM, so the method must become a value of the pool.
- The guard on the cluster type before the container mode check (`$C/temporal/activities/capi_shared.go:37-39`).

The size is M (my estimate, in the units of the plan). The risk for clusters that exist is in the factories, because each cluster of each type passes through them. With the default "a pool follows its cluster", the behavior of a cluster with one provider does not change (deduction).

A lab can test the option only after the code exists. The mock NICo containers use `infra` today, because "the mock's site and VPC live inside the NicoCluster and NicoMachineTemplate" (`$R/cli/examples/nico-mock-cluster.yaml:16-19`). The `nico` request object runs against nico-sim in the `nico-vms` tests (`$R/controller/test/e2e/cp_controller_test.go:627-628`).

### Option C, a NICo cluster whose control plane comes from a second provider

The shape is a cluster of the type `nico`, with a `NicoCluster`, and `controlPlaneConfig.infra` with a pod template.

The files that change:

- The control plane checks at create and at update (`$C/server/cluster_control_plane_config.go:170-180`, `:242-248`, `:264-275`, `$C/server/clusters.go:797-821`).
- The client for a control plane node. It must follow the control plane config and not the cluster (`$C/nodes/context.go:86`, `$C/controllers/controlplane/reconciler.go:68`, `:84`, `capi_node_resources.go:75`, `:232`). The config already knows which payload it has (`$C/db/control_plane_configurations.go:121-134`).
- The container mode guard (`capi_shared.go:37-39`).
- The provider of the lab. It must work with no `PodVMCluster`, so each machine must carry the pod namespace, the runtime class, the network and its address (`$P/controllers/machine_controller.go:255-290`). The address range of a cluster then has no owner object.

What breaks is the place of the control plane nodes. NVKE reads the failure domains from the Cluster (`$C/controllers/controlplane/failure_domain_discovery.go:60-65`), and with a `NicoCluster` the list has the failure domains of NICo (`$N/controllers/failuredomain.go:59-61`). NVKE then gives a pod Machine the name of a NICo domain (deduction).

The size is M in NVKE and S to M in the provider (my estimate). A lab needs both changes before it can test.

### Option D, the direction of the proposed architecture record

The record is `$R/docs/adrs/20261105-capi-architecture.md`, with the status "proposed" (`:3`).

- The control plane becomes a control plane provider, "with `NVKEControlPlane` as an initial example". The hosting models include "backing infrastructure managed privately by the provider, and hosted control planes" (`:59`).
- The workers become `MachineDeployment` objects with infrastructure templates and a bootstrap provider (`:60`, `:95-99`).
- The REST API of the controller goes away (`:32-34`, `:138-141`).
- "reusable provider interfaces do not imply support for arbitrary provider combinations" (`:185-187`).

In that shape the Cluster has a control plane reference, and its infrastructure cluster object can be the `NicoCluster`. The control plane provider owns its pods, so the problem of two infrastructure providers in one Cluster goes away (deduction).

What exists in the repository:

- No `NVKEControlPlane` type. A search finds the name only in the record and its diagrams. No code in `$C` or in the management engine sets a control plane reference.
- Controllers for the bootstrap of a worker with a `KubeadmConfig`. One gives the Machine a temporary SPIRE identity for `kubeadm join`, and it supports only a `NicoMachine` with a TPM (`$C/controllers/bootstrap/spire_nico_tpm_bootstrap_identity_controller.go:37-70`, `:276-283`). One grants the identity the rights that kubeadm needs in the tenant cluster (`$C/controllers/bootstrap/bootstrap_authorization_controller.go:62-78`). Both are behind the setting `BootstrapControllersEnabled` (`$R/controller/cmd/worker/main.go:423-491`).
- The CA Secret and the endpoint that the kubeadm bootstrap provider needs (`$C/controllers/tenantaccess/capi_contract.go:38-48`).
- A note that the controllers of `$C/controllers/capi` will move into providers named `bootstrap`, `controlplane` or `capn` (`$C/controllers/capi/README.md`).
- The management engine, which sends `infra` requests to the REST API today.

The size is L, and the work belongs to the maintainers of the record. A lab has nothing to test for the option without new code.

### My view

I would choose option A for the lab of phase 3. The reasons are the following:

- It needs no new NVKE code beyond the branches of phase 2 (deduction, and the first thing the lab must prove).
- CAPNICo documents the case, and the mock NICo flow already uses the `infra` path with `NicoMachineTemplate`.
- It changes nothing for clusters that exist.
- The management engine already drives the controller with one template for the control plane and one for the pools, so the shape also fits the direction of the record.

For a product I would not start option B or C before the maintainers say where the record goes. Option B gives a GPU pool the functions of the `nico` request object, and the record removes the REST API that option B changes. One change is needed in each option, which is an attestation method for each pool or for each node (section 7).

## 5. Network needs

### What must reach what

| From | To | Port | Why | Reference |
|---|---|---|---|---|
| Each worker (kubeadm, kubelet, OVN) | The shared API address | 6443, or the port of `controlPlaneEndpoint` | The join and all later calls. The OVN chart gets the API address from the kubeconfig of the first node | `$C/kubeadmconfig/join.go:256-261`, `$R/agent/internal/agent/cni.go:371-387` |
| Each node (SPIRE agent) | The SPIRE server of the management cluster | 30440 | Node attestation | `$R/docs/operate/plan-installation.md:63` |
| The NVKE controller | Each node, at the first address of its Machine | 15005 | The node agent. A control plane pod and a worker are the same case | `$C/agent/transport.go:123-127`, `plan-installation.md:64` |
| The NVKE controller, Cluster API and CAPNICo | The shared API address | 6443 | The tenant client, the certificate approval, the provider ID of the Node | `plan-installation.md:65`, `nico_provider_id_controller.go:123-141`, `$N/controllers/node_provider_id.go:70-121` |
| The API server in each control plane pod | The kubelet of each worker, at the InternalIP of the Node | 10250 | Logs, exec, port forward and metrics | See section 6 |
| The API server in each control plane pod | Pods and Services on the workers | The pod network | Webhooks, aggregated APIs and the proxy calls | Deduction |
| Each node | Each other node, in both directions, between the node addresses | UDP 6081 (Geneve) | The pod network of OVN | Deduction, and `results/phase1-results.md` |
| The control plane pods | Each other | 2379, 2380 and 6443 | etcd and the API servers. The workers need none of it | Deduction |

The table of the NVKE docs says "traffic between the nodes of one cluster is not listed" (`plan-installation.md:53`).

### The CNI and what it needs between nodes

- NVKE installs OVN-Kubernetes 2.4.2 by default. Calico is a legacy choice that is off by default (`openapi.yaml:1111-1124`, `$R/docs/overview/supported-platforms.md:38`).
- The agent of the first control plane node installs the chart with Helm, one time for the cluster (`$R/agent/internal/agent/cni.go:299-325`, `:371-387`).
- Open vSwitch runs on the host of each node. The agent configures it before the join (`$C/temporal/workflows/provision_node.go:404-438`).
- Each node is its own OVN zone, by the label `k8s.ovn.org/zone-name=<node name>` (`provision_node.go:684-688`). So each node runs its own OVN databases, and the nodes need only the API server and the tunnels between them (deduction).
- The lab showed in phase 1 that the tunnels fail with address translation between the nodes. Traffic passed in 0 of 6 directions with a LoadBalancer address for each pod (`summary.md`).

### One OVN setting for the whole cluster

The gateway settings of OVN are Helm values, so they are the same for each node of a cluster (deduction from one chart install).

- A container node has the variable `NKE_OVS_DATAPATH_TYPE`. "Only the container node image sets" it (`cni.go:279-283`, `$R/controller/hack/capd-kindest-node/scripts/nvke-agent-container-ovs.conf:9`).
- With the variable, the agent makes an empty bridge `br-ex` and adds the Helm values for the local gateway mode, `--gateway-interface=br-ex --allow-no-uplink`, and no pod host port (`$R/agent/internal/agent/open_vswitch.go:261-293`, `cni.go:71-86`, `:255-273`).
- The pod image of the lab keeps the variable (`lab/phase2-node-image/result.md:51`). So a control plane in pods installs OVN with the container settings.
- A machine with the reference image has no such variable. Its agent moves the interface of the default route onto a bridge whose name is `br` and the name of that interface (`open_vswitch.go:531-543`). A bridge `br-ex` then does not exist on that machine (deduction).

So a worker on real hardware can fail in the OVN pod of its node when the control plane is a pod with the container settings (deduction, not tested). With the container form of the mock NICo the workers use the container image too, so a lab with that form does not show the problem (deduction).

### Address translation

Address translation between the control plane pods and the workers breaks two more things besides the tunnels (deduction):

- The API server calls the kubelet at the InternalIP of the Node, which is the node IP that NVKE gave to the kubelet (`$C/kubeadmconfig/join.go:268-270`).
- NVKE approves a kubelet serving certificate only when its IP is the node IP of the NVKE record (`$C/controllers/tenant/csr/controller.go:413-435`), and the API server checks the certificate (`$C/kubeadmconfig/init.go:251`).

## 6. Konnectivity

### What NVKE has today

- A search of `$R` for `konnectivity`, `egress-selector`, `EgressSelector` and `apiserver-network-proxy` finds only three `go.mod` lines with an indirect dependency (`$R/controller/go.mod:180`, `$R/management-engine/go.mod:126`, `$R/controller/k8s-apis/go.mod:92`). NVKE has no code, no setting, no chart value and no doc for it.
- A search for `kubelet-preferred-address-types` finds nothing. NVKE does not set the flag (`$C/kubeadmconfig/init.go:241-260`).
- kubeadm sets the flag to `InternalIP,ExternalIP,Hostname` by default. I read the value in the local Kubernetes checkout (`/home/dsrinivas/go/src/k8s.io/kubernetes/cmd/kubeadm/app/phases/controlplane/manifests.go:201`).
- So the API server calls a kubelet directly at the InternalIP of its Node, with a certificate check.
- A caller can give the API server more flags through `controlPlaneConfig.apiServer.extraArgs`, when NVKE does not own the flag (`$C/kubeadmconfig/extra_args.go:42-66`, `:118-146`). The two flags above are not in the list of NVKE. The API has no field for a file or a volume of the API server (`openapi.yaml:1191-1200`).

### When a routed network is enough

In the tested form each control plane node is a full node of the tenant cluster, with a kubelet and OVN. The API server then reaches a pod on a worker through the pod network of its own node. A routed network with no address translation is enough when the following is true (deduction):

- Each worker reaches the shared API address.
- Each control plane pod reaches each worker address on TCP 10250.
- The control plane node addresses and the worker addresses reach each other on UDP 6081.

Test W2 of phase 2 passed with the same conditions for a worker in a pod (`results/phase2-results.md`, section 1a).

### When Konnectivity is needed

- The workers reach the shared API address, and the control plane pods cannot open a connection to a worker address. A tenant VPC of NICo with no route from the host cluster is such a case (deduction).
- Address translation is between the two networks.
- Phase 4 of the plan, a pod with no kubelet. The API server then has no pod network of its own.

Konnectivity covers the calls from the API server to kubelets, pods and Services. It does not cover the calls from NVKE to the node agent on port 15005. It also does not give a pod on a control plane node a path to a pod on a worker, so pods such as CoreDNS must then run on the workers (deduction).

### What NVKE would have to install and where

1. The API server needs the flag `--egress-selector-config-file`, the config file and a volume for the file and for the socket or the client certificate. The places are the cluster configuration (`$C/kubeadmconfig/init.go:241-303`), the files that NVKE sends to the agent before kubeadm (`init.go:130-146`, `$C/temporal/activities/kubeadm_init.go:178-180`), the join config of a control plane node (`$C/kubeadmconfig/join.go`), the list of the flags that NVKE owns (`extra_args.go:42-66`), and a rewrite of the stored `kubeadm-config` for a cluster that exists, as NVKE does for OIDC (`$C/kubeadmconfig/configmap.go:107-135`).
2. Each control plane node needs a Konnectivity server, as a static pod or as a pod with the host network. It needs a certificate and a second port behind the shared address. The Service of the pod provider or the load balancer of the caller must carry that port. The agent has no call for it today.
3. Each worker needs a Konnectivity agent. NVKE would install it as an add-on after the init, in the way it installs the local DNS (`$C/temporal/workflows/provision_cluster.go:285`, `$C/temporal/activities/install_kube_local_dns.go`), and update it with the other add-ons (`$C/temporal/workflows/upgrade_control_plane_addons.go`).
4. The request needs a field that turns it on for a cluster.

## 7. Identity and bootstrap of a worker on NICo against a control plane in pods

### Who runs the SPIRE server

The management cluster runs one SPIRE server. Its address and port come from the controller config into the bootstrap data of each node (`$C/clients/nico/bootstrap_userdata.go:183-184`, `$C/clients/capi/bootstrap_userdata.go:128-129`). The nodes of a workload cluster reach it on port 30440 (`plan-installation.md:63`). A cluster record can hold another SPIRE server address (`$C/db/clusters.go:114-125`). I did not trace that path.

### How a NICo worker gets its identity today

1. The SPIRE agent of the image attests with the TPM of the machine (`$R/os-image/SPEC.md:25`).
2. CAPNICo reads the certificate of the TPM from the NICo instance and reports its hash in `NicoMachine.status.tpmEkPubHash` (`$N/controllers/nicomachine_controller.go:418-427`).
3. `NicoSpiffeController` writes the agent path `/spire/agent/tpm/<hash>` as an annotation on the Machine (`$C/controllers/capi/nico_spiffe_controller.go:166-174`).
4. `MachineSpireEntryController` makes a `ClusterStaticEntry` that gives the node agent the identity of the node (`$C/controllers/capi/machine_spire_entry_controller.go:88-115`).
5. NVKE calls the agent with mTLS and accepts only that identity (`$C/agent/transport.go:147-157`).

The Kubernetes side is the same for each provider. The worker joins with a bootstrap token from a joined control plane node (section 2), and NVKE approves the kubelet serving certificate by the node name and IP.

### What assumes that control plane nodes and workers come from the same provider

- The attestation method is one value for the deployment (`$C/nodes/agent_profile.go:14-22`). A NICo machine on a site attests with its TPM (`$R/docs/operate/infrastructure-providers.md:44-52`), and a Kata pod has no TPM. So a product needs the method for each pool.
- The join token exists only on the `infra` path. The `capi` client makes it (`$C/clients/capi/machine.go:79-82`, `capi_node_resources.go:103-127`), and the `nico` client never does (`$C/clients/nico/machine.go:109-113`).
- The config check for LaunchLayer forces one method on the whole deployment (`$C/controllerconfig/config.go:498-500`).
- The Teleport controller needs the `nico` payload of the cluster for each `NicoMachine` (`$C/controllers/teleporttoken/controller.go:450-453`). On an `infra` cluster the call returns an error (deduction). It applies only when Teleport is on.

I found nothing else. The identity controllers act on one Machine and its annotations, and no code compares the provider of a worker with the provider of the control plane (deduction).

### How large the change for a method for each pool is

The change is small (deduction):

- The `infra` path already renders `agent.conf` for the method of the node, for each of the three methods (`$C/clients/capi/capi_spire_agent.conf.tmpl`).
- `NicoSpiffeController` already reads the method from the annotation of the Machine (`nico_spiffe_controller.go:123-136`).
- The database payloads of an `infra` pool and of an `infra` control plane config already have the field `spire_attestation_method` (`$C/db/node_pools.go:52`, `$C/db/control_plane_configurations.go:65`). The API has no field for it, and no code reads it into the profile of a node (search).
- The missing parts are an API field, a read in `PinAgentProfile`, and the checks.

### Other identity paths in the source

- The agent can use a token of the DSX metadata service in the place of SPIRE, with TLS and JWT. The commit `c34780da` (#2379) added it for agents in KubeVirt virtual machines. It needs the external mTLS setting. The plan names it as an identity for pods.
- The bootstrap identity controllers of option D support only a `NicoMachine` with a TPM today.

## 8. What the plan calls "VMaaS cluster tests"

### What I found

- The word `vmaas` is in one file, in the names of two config profiles, `vmaas-cp-monitoring-ovn-v1` and `vmaas-w-kata-L40S-ovn-graphics-v1` (`$C/db/migrations/20251204180000_add_system_reserved_memory.go:63-64`). The profile files are not in the repository. `$R/controller/profiles` has only a README and an example.
- The word `kubevirt` is in the audit policy of the API server, as a resource group (`$C/kubeadmconfig/audit_policy.yaml:88-89`), and in the commit `c34780da` about node agents in KubeVirt virtual machines.
- `launchlayer` has a provider client with unit tests (`$C/clients/launchlayer`), and a pool can ask for a virtual machine with `vmProfile` (`$C/db/node_pools.go:72-79`). No end to end test selects LaunchLayer. The word is only in a request helper and in the login code of the `dsx` environment (`$R/controller/test/e2e/internal/nvke/request.go:825`, `$R/controller/test/e2e/internal/infra/dsx/auth.go`).
- Tests with nodes that are virtual machines use the `nico-vms` form of nico-sim, with the `nico` request object (`$R/controller/test/e2e/tenant_test.go:249`, `parallel_lifecycle_test.go:36`, `cp_controller_test.go:627-628`, `$R/.github/workflows/nico-vms-e2e.yml`).
- Tests with nodes that are containers use `capd` and `nico-containers` (`tenant_test.go:120-234`, `$R/.github/workflows/capd-e2e.yml`, `$R/.github/workflows/nico-e2e.yml`). The `nico-containers` machines "are containers, with no TPM and no GPU" (`nico-e2e.yml:114`).
- The test README says that the suite has "tables that run against different backends (`nico-vms` and `capd`)" (`$R/controller/test/e2e/README.md`).
- The site environments are `forge`, `forge-perf` and `dsx` (`$R/controller/test/e2e/environments`).

### What I did not find

- A test, a CI workflow or a doc with the name "VMaaS".
- A test for a cluster whose nodes come from two providers. Each entry of `tenant_test.go` uses one form.
- A KubeVirt provider client or a test with a KubeVirt cluster.
- The words "DPF", "Kamaji" or "static cluster", which the plan uses for the gate of phase 1.

So the "VMaaS cluster tests" of the plan are not a suite of the repository (deduction). The name refers to tests outside the repository or to tests that someone must define.

## 9. Other points for a phase 3 design

### Node pool rules

- A pool cannot be a control plane pool (`$C/server/node_pools.go:34`, `$C/server/cluster_control_plane_config.go:150-154`).
- A pool version cannot be newer than the control plane version, and a pool waits while the control plane upgrades (`$C/server/node_pools.go:704-724`).
- A lower count removes no node, and the default `systemReservedMemory` is 16Gi (`results/phase2-results.md`, findings 11 and section 1a).

### The contract of a container node

The setting `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP` exists for "the local NICo container flow" and applies to each node of the deployment (`$C/config/config.go:372-381`). With the setting, the preflight looks for the file `/run/cluster-api/bootstrap-success.complete` in the place of the cloud-init status (`$C/temporal/activities/node_preflight.go:21`, `:100-131`). kubeadm then skips its system check, and the kubelet gets small reservations (`$C/kubeadmconfig/init.go:193-197`, `$C/kubeadmconfig/render.go:358-372`).

- The mock example writes that file in `preKubeadmCommands` for the control plane and for the pool (`$R/cli/examples/nico-mock-cluster.yaml:46-48`, `:77-79`).
- Phase 2 treated a pod as a real machine, with the cloud-init status (`phase2-design.md:65`).
- If the lab needs the setting for the mock workers, the control plane pods get the container contract too, and their template needs the same command (deduction).
- I found no file in the repository that turns the setting on. The Tiltfile passes it from the environment (`$R/controller/Tiltfile:1068-1075`).

### Failure domains

- Only a control plane node gets a failure domain. NVKE reads the list from the Cluster (`$C/controllers/controlplane/failure_domain_discovery.go:38-67`).
- With option A the list has the nodes or zones of the host cluster, from the `PodVMCluster`.
- A NICo worker asks for no domain. CAPNICo then places it by the instance type only (deduction).

### The reboot path

- NVKE refuses a reboot of a control plane node (`$C/temporal/workflows/reboot_node.go:83-92`). So only the workers use the path.
- For a worker, NVKE tries the soft reboot through the agent and then sets the annotation, which CAPNICo answers with a power cycle (`reboot_node.go:45-52`, `$R/deploy/nico/capnico/capnico.yaml:2171`).
- So a cluster with pods only in the control plane does not need `NODE_REBOOT_SOFT_REBOOT_ENABLED=false`, and the default fits the NICo workers (deduction). Point 9 of `results/phase2-results.md`, section 7, applies only when a worker is a pod.

### The delete path

- NVKE removes the pools, then the control plane nodes, then waits until no Machine remains, then deletes the infrastructure cluster object and the Cluster (`$C/temporal/workflows/teardown_cluster.go:50-72`, `$C/temporal/activities/capi_cluster_resources.go:44-97`).
- The hooks of a node teardown come from the config profile, which an `infra` pool does not have (`$C/temporal/workflows/teardown_node.go:557-570`).
- The machine health issue annotation asks NICo for a repair at the delete (`capi_node_resources.go:158-173`).

### Upgrades with two kinds of nodes

- The control plane upgrade is one PATCH with the version and the template, and it does not touch a pool (`results/phase2-results.md`, section 1b).
- A pool upgrade on `infra` is a PATCH with the version and a new `NicoMachineTemplate`. The caller must put the new boot script into the template, because the pool has no release.
- NVKE does not remove the old worker by itself (`results/phase2-results.md`, section 1b).

### The guard for the shared address

The health gate of phase 2 moves the kubelets of the workers to another API server before an operation on a control plane node. The gate does not depend on the provider of the worker (deduction). A lab with NICo workers should repeat pass rule 1 of `results/phase2-results.md`, section 1c.

### The two CAPNICo versions

NVKE compiles against the API types of `v0.1.0` and installs the image `v0.3.0-rc.1`. The field `siteID` is in both (`$N/api/v1alpha1/nicomachine_types.go:99-103`, `$R/deploy/nico/capnico/capnico.yaml:908-913`).

## Points where I am not sure

1. Option A is a deduction from the source. No test has run it. The first lab step must prove that CAPNICo `v0.3.0-rc.1` makes an instance for a `NicoMachine` with `siteID` in a Cluster with a `PodVMCluster`. I read the controller source of `v0.1.0` only.
2. I could not read the OVN chart, which is in another repository. So the statement that a worker on real hardware fails with the container gateway settings is a deduction. The statement that one zone for each node means no shared OVN database is a deduction too.
3. I do not know if the `nico-containers` flow needs `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP`. I found no place that turns it on. The reading of nico-sim can answer it.
4. The kubeadm default for `kubelet-preferred-address-types` comes from a local Kubernetes checkout. I did not check its version against 1.35 and 1.36.
5. I did not find a NICo API client in the controller, by a search for the SDK import. A path that I missed can exist.
6. I did not read the upstream issue 14373, so I do not know what change in Cluster API the plan has in mind.
7. The sizes S, M and L are my estimates from the count of places in the source. I did not plan the work.
8. I did not trace the SPIRE server address of a cluster record (`$C/db/clusters.go:114-125`), and I did not check how the bootstrap controllers of option D behave with a control plane in pods.
9. For Konnectivity I described the parts from general knowledge of the component. The repository has nothing to check them against.

## The options of question 4

| Option | What changes | Size | Risk for clusters that exist | What a lab can test with the least new code |
|---|---|---|---|---|
| A. One `infra` cluster with a `PodVMCluster`, a pod template for the control plane and a `NicoMachineTemplate` with `siteID` for each pool | No NVKE code (deduction). Deployment settings only, and the branches of phase 2 | S for the lab. A product form needs the method for each pool and docs | None, because no code changes | The whole flow now, with the mock NICo. Create, join of a NICo worker, traffic between a worker and the control plane, reboot and delete of a worker, a control plane rollout with a worker present |
| B. A provider for each node pool, with `nico` pools in a cluster of another type | The API schema, the pool checks, 11 factories and their call sites, the `nico` client (site data and `siteID`), the method for each pool | M | Medium. Each cluster passes through the changed factories | Nothing before the code exists. Then a `nico` pool against nico-sim in its virtual machine form |
| C. A `nico` cluster whose control plane uses `controlPlaneConfig.infra` | The control plane checks, the client choice for control plane nodes, the container mode guard, and a pod provider that works with no `PodVMCluster` | M in NVKE, S to M in the provider | Medium. The failure domains of the Cluster are the domains of NICo, so the place of a pod is wrong | Nothing before both changes exist |
| D. The direction of the proposed record, with a control plane provider and `MachineDeployment` objects for the workers | A new control plane provider, a bootstrap provider path, and the end of the REST API | L, and not our work alone | High. The record itself asks for a transition design | Nothing. The repository has no `NVKEControlPlane` type |
