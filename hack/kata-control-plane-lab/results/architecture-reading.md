Date 2026-11-25. NVKE commit `bcc4376f`. No test ran.

# Architecture reading for NVKE control plane nodes as Kata pods

This note supports [nvke-control-planes-as-kata-pods.md](../nvke-control-planes-as-kata-pods.md) and [evidence.md](../evidence.md). It answers six questions about the NVKE code and about Cluster API. It ends with candidate answers for four architecture questions and with a list of the items that I did not verify.

## Path prefixes

All NVKE line numbers are as of commit `bcc4376f`. The references use these prefixes:

- `R` = `~/go/src/github.com/nvidia/nvke`
- `CI` = `R/controller/internal`
- `AG` = `R/agent/internal/agent`
- `PP` = `R/cluster-api-provider-provisioned`
- `K8S` = `~/go/src/k8s.io/kubernetes`, a local checkout at `v1.38.0-alpha.2-199-g057137c2889`
- `B14` = `https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.4`
- `B15` = `https://github.com/kubernetes-sigs/cluster-api/blob/v1.15.0-rc.0`

## Q1. Lifecycle of a control plane node

**Conclusion.** NVKE owns the whole lifecycle. A control plane node is one bare `Machine` with a random name, and NVKE never uses that name again. NVKE creates the node, joins it and deletes it. It never updates it and never reboots it. Upgrade and repair both add a new Machine and then delete the old one. A pod provider must make the pod, the volumes and the Service, publish one stable address, keep that one pod alive with the same identity until NVKE deletes the Machine, and then delete everything. A StatefulSet with one replica for each Machine fits the "keep alive" part better than a bare Pod.

### Create

- Scale-up makes node rows with the name `<cluster>-cp-<8 hex>`. NVKE does not repeat a name in a cluster (`CI/controllers/controlplane/scale.go:86-141`).
- Scale-up waits for placement discovery. Discovery needs `Cluster.status.initialization.infrastructureProvisioned` to be true (`CI/controllers/controlplane/reconciler.go:112-118`, `CI/controllers/controlplane/failure_domain_discovery.go:56-58`). Without it NVKE creates no control plane node.
- `CreateMachine` on the `infra` path does these steps (`CI/clients/capi/machine.go:29-118`):
  1. It renders the InfraMachine from the template of the caller. The name is the node name.
  2. It makes a SPIRE join token if the node uses that method.
  3. It applies the Secret `<node>-bootstrap-data`. The key `value` holds `#cloud-config` text with `write_files` and `runcmd` (`CI/clients/capi/bootstrap_userdata.go:150-163`, `CI/clients/shared/machine.go:145-163`).
  4. It applies the `Machine` with `bootstrap.dataSecretName`, `failureDomain` and `version` (`CI/clients/shared/machine.go:168-206`). The failure domain does not change after the first apply (`CI/clients/shared/machine.go:213-229`).
- The workflow then waits for an address, runs the agent preflight and marks the node ready to join (`CI/temporal/workflows/provision_node.go:211-247`).
- The first node runs kubeadm init. The control plane controller joins the other nodes one at a time (`CI/temporal/workflows/provision_cluster.go:58-70`, `CI/controllers/controlplane/reconciler.go:172-180`).

### What NVKE reads from the infrastructure objects

- **Address.** NVKE reads `Machine.status.addresses`. It takes the first `InternalIP`, then the first `ExternalIP`, then any address. If the Machine has no address, NVKE reads `status.addresses` of the InfraMachine. The value becomes `node.IP` (`CI/temporal/activities/capi_node_resources.go:262-285, 314, 401-449`).
- **providerID.** NVKE uses `Machine.spec.providerID` only as the signal that the infrastructure is allocated. While it is empty, the node stays `Pending` (`CI/temporal/activities/capi_node_resources.go:249, 357-376`).
- **Ready.** NVKE does not read `status.initialization.provisioned` or a ready field of the InfraMachine. It reads the `InfrastructureReady` condition only for a wait message during provisioning (`CI/temporal/activities/capi_node_resources.go:393-399`). After provisioning it reads no Machine condition.
- **Failure domains.** NVKE reads the entries of `Cluster.status.failureDomains[]` that have `controlPlane: true`. It also reads `Machine.status.failureDomain` or `Machine.spec.failureDomain` (`CI/controllers/controlplane/failure_domain_discovery.go:61-65, 91`). With no domains NVKE requests none (`CI/controllers/controlplane/failure_domain_assignment.go:69-77`).
- **Optional fields.** NVKE reads `spec.instanceTypeID`, `status.instanceID` and `status.machineID` of the InfraMachine. It ignores them when they are absent (`CI/temporal/activities/capi_node_resources.go:456-475`, `CI/clients/shared/machine.go:48-72`).

### Delete

- `TeardownNode` drains the node. The agent stops the API server and etcd. A surviving node removes the etcd member. The agent runs kubeadm reset. Then NVKE deletes the `Machine` (`CI/temporal/workflows/teardown_node.go:118-175, 180-273, 444-471`).
- NVKE can put the annotation `nvke.nvidia.com/machine-health-issue` on the Machine before the delete (`CI/temporal/activities/capi_node_resources.go:158-173`).
- NVKE does not wait until the Machine is gone. It deletes the Kubernetes Node and the node row next.
- NVKE runs one delete at a time for each cluster (`CI/controllers/controlplane/delete.go:33-85`).
- NVKE sets `ForceUnreachable` automatically for a node that is not healthy (`CI/nodes/control_plane_delete_request.go:74-77, 123`).

### Replace

- **Rollout.** A change of the Kubernetes version, of `infra.machineTemplate` or of the bootstrap files needs a rollout (`CI/db/control_plane_configurations.go:280-333`). NVKE adds a surge node and then deletes an old node (`CI/controllers/controlplane/upgrade.go:48-71, 148-153`). So a new image is always a new Machine.
- **Remediation.** It starts only from the condition `MarkedForRecycling` (`CI/controllers/controlplane/remediation.go:21-74`). For a control plane node that condition comes only from the tenant Node condition `NeedsRecycle` (`CI/controllers/tenant/nodestatus/conditions.go:15-27`). The auto mode controller skips control plane pools (`CI/controllers/automode/controller.go:120-123`).
- **Stuck pending.** NVKE places a pending node again only when the provider reports that the failure domain has no capacity. NVKE reads that report only from a NicoMachine condition. The `infra` client always answers false (`CI/clients/capi/rotation.go:28-32`, `CI/clients/nico/failuredomain.go:37-44`, `CI/db/nodes.go:277-285`). So NVKE never places a pod again when the pod cannot schedule in its domain.
- **VIP gate.** Scale above one node, delete, remediation, rollout and rebalance all need `controlPlaneVIP`. The development setting `allowControlPlaneWithoutVIP` removes the gate (`CI/controllers/controlplane/controlplane.go:29-31`, `CI/controllers/controlplane/remediation.go:34-37`, `CI/controllers/controlplane/upgrade.go:57`, `CI/controllers/controlplane/rebalance.go:141`, `CI/controllers/controlplane/stuck_pending.go:82`, `CI/server/control_plane_vip.go:18-35`, `CI/config/config.go:430-432`).

### Reboot

- NVKE never reboots a control plane node. The workflow ends with the status "not allowed" (`CI/temporal/workflows/reboot_node.go:83-93`). NVKE refuses teardown by label in the same way (`CI/temporal/workflows/teardown_node.go:72-85`).
- For a worker, the hard reboot is the Machine annotation `nvke.nvidia.com/reboot` with an RFC3339 time as its value (`CI/clients/capi/rebootannotation.go:13-15`, `CI/temporal/activities/capi_node_resources.go:506-561`).
- NVKE accepts the reboot as complete when the boot ID of the tenant Node changes. It also accepts it when the Machine has the annotation `nvke.nvidia.com/reboot-complete-timestamp` with a time later than the request (`CI/temporal/activities/wait_for_node_reboot.go:87-105, 121-142`).
- So the provider sees only that annotation for a reboot. For a replacement it sees a Machine delete and a new Machine.

### What a pod provider must implement

1. A cluster kind that reports `status.initialization.provisioned`. It also reports `status.failureDomains` if the replicas must spread.
2. A machine kind that does all of these:
   - It waits for the owner Machine and for `dataSecretName`.
   - It makes the volumes, the Service and the pod. It changes `Machine.spec.failureDomain` into node affinity.
   - It gives the bootstrap Secret to the pod as cloud-init data.
   - It sets `spec.providerID` early.
   - It publishes the stable address as the first `InternalIP`.
   - It sets `Node.spec.providerID` in the tenant cluster. Cluster API waits for a Node with that ID (`B14/core/reconcilers/machine/machine_controller_noderef.go#L84-L116`). CAPD and the provisioned provider both set it themselves.
3. Delete of the pod, the volumes and the Service on Machine delete, also when the host is dead.
4. Reboot support is optional for control plane nodes.

### Owner of the pod

| Topic | Bare Pod that the provider makes again | StatefulSet with 1 replica for each Machine |
|---|---|---|
| Who makes the pod again | The provider, across the kubeconfig to the host cluster. No repair occurs when the provider or its cluster is down | The host cluster itself |
| Objects that the provider makes | The Pod, each PVC and the Service | The StatefulSet, a headless Service and the LoadBalancer Service. The PVCs come from claim templates. A retention policy deletes them |
| Names | The pod name can equal the Machine name | The pod name is `<machine>-0`. NVKE gives kubeadm the node name (`CI/kubeadmconfig/init.go:186`), so this is acceptable |
| Host drain | `kubectl drain` needs `--force`, and the pod is then gone | Eviction with a PodDisruptionBudget, then a new pod with the same name |
| Two pods with one identity | The provider must prevent it | The controller waits until the old pod object is gone (`K8S/pkg/controller/statefulset/stateful_set_control.go:465-467`) |
| Template updates | Not applicable | Not used. Set `OnDelete`, because NVKE never changes a Machine in place |

The StatefulSet fits better. Between create and delete the only job is to keep exactly one pod with this identity and these volumes. That job must work when the management side is not reachable. With both owners the pod needs tolerations for `node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable` with no time limit, because a local volume cannot move.

## Q2. The provisioned provider

**Conclusion.** `cluster-api-provider-provisioned` can bind three pods and their Services for a bootstrap test. The inventory address is the LoadBalancer IP of each Service. It gives a join test only. It does not give the bootstrap data to the pod, it refuses a delete after a claim, and it needs its own cluster kind as the `infrastructureRef` of the `Cluster`.

### How it binds

- The inventory is a list of `hostname` and `ipAddress` pairs. Each entry can have a `tpmEkPubHash` and labels (`PP/api/v1alpha1/provisionedcluster_types.go:14-56`).
- A machine takes the first free host that matches `spec.hostSelector`. The provider writes `spec.providerID` as `provisioned://<cluster>/<ip>`. The value cannot change afterwards (`PP/api/v1alpha1/provisionedmachine_types.go:13-32`, `PP/controllers/machine_controller.go:243-337`).
- A `ProvisionedHostClaim` with cluster scope locks the IP across all clusters. The claim is permanent (`PP/controllers/claims.go:60-129`).
- The provider reports the machine as provisioned when the machine holds a host. The addresses are `Hostname` and `InternalIP` (`PP/controllers/machine_controller.go:488-508`, `PP/controllers/inventory.go:171-176`).
- The provider sets `Node.spec.providerID` through the Secret `<cluster>-kubeconfig`. It looks for the Node with the Machine name (`PP/controllers/machine_controller.go:429-486`).

### Kinds

The provider has four kinds (`PP/README.md:24-31`):

- `ProvisionedCluster`
- `ProvisionedMachine`
- `ProvisionedMachineTemplate`
- `ProvisionedHostClaim`, with cluster scope

### Limits

- The provider refuses a delete after a claim. The finalizer stays, and the reason is `DeletionNotSupported` (`PP/controllers/machine_controller.go:104-127`, `PP/README.md:77-87`). So there is no rollout, no scale-down, no repair and no cluster delete through NVKE.
- The `infrastructureRef` of the cluster must be a `ProvisionedCluster` (`PP/controllers/machine_controller.go:215-221`). So it cannot be the second provider in a cluster.
- It has no failure domains and no control plane endpoint (`PP/api/v1alpha1/provisionedcluster_types.go:44-56, 78-105`).
- It has no reboot handling.
- The inventory is fixed after the cluster is created.

### What is missing for the test with three pods

1. **Bootstrap data.** The provider never reads the bootstrap Secret. The join token, the SPIRE files and the agent files do not reach the pod. The test needs one of these:
   - TPM attestation with a software TPM, with the key hash in the inventory.
   - An agent with SPIFFE off.
   - A script that reads `ProvisionedMachine.status.hostName` and copies the cloud-init content into the pod, as nico-sim does.
2. **Preflight.** NVKE asks the agent for `cloud-init status`. The exceptions are a template of kind `DockerMachineTemplate` and the development flag (`CI/temporal/activities/node_preflight.go:101-134`, `CI/temporal/activities/capi_shared.go:20-64`, `AG/preflight.go:98-185`). The kind node image has no cloud-init.
3. **Endpoint.** Three nodes need a VIP or the development setting. With a VIP, NVKE configures kube-vip with BGP in the pod. With the development setting, the endpoint is the IP of the first node (`CI/temporal/activities/kubeadm_init.go:80-83`). That is sufficient for a test.
4. **Node address.** See Q4.
5. **Second run.** An operator must delete the old claims by hand.
6. **Install.** Only `nvkectl bootstrap` installs the provider. The chart has RBAC for these kinds when `capi.rbac.create` is set (`R/controller/deploy/charts/controller/templates/rbac-capi.yaml:48-61`).

## Q3. The infra path

**Conclusion.** A pod provider that comes through `infra` needs no new provider type in NVKE and hits no new switch arm. All the data for the pod comes through the two manifests. But NVKE has behaviour that depends on a VIP, on kube-vip and on the kind `DockerMachineTemplate`. That behaviour needs changes.

### What comes through manifests with no NVKE code

- The API takes `infra.cluster`, which is any manifest. For the control plane and for each pool it takes `machineTemplate`, `bootstrapFiles` and `preKubeadmCommands` (`R/controller/api/openapi.yaml:3111-3124, 3373-3395, 3634-3656`).
- The validation checks only the group `infrastructure.cluster.x-k8s.io` and that a kind is present (`CI/clients/capi/manifestvalidate.go:36-74`).
- NVKE gives the cluster object the name of the cluster and makes it the `infrastructureRef` (`CI/capi/resources.go:39-78`).
- The 13 capabilities of the `infra` client are all generic (`CI/clients/capi/*.go`). They copy the payload, they have no handling for a stuck machine, they reach the tenant API through the Secret, they use the reboot key `nvke.nvidia.com/reboot`, and they accept each agent profile.

### What a fourth provider type needs

A fourth provider type needs one arm in each of the 22 switches, 13 capability implementations, and the payload types in the API and the database. The 22 switches are in these places:

- The 13 factories in `CI/clients/`, which are `scaffold.go:33`, `machine.go:56`, `kubevipconfig.go:31`, `nodesetprovider.go:32`, `controlplaneconfignodeprovider.go:33`, `newnodeprovider.go:44`, `nodepoolpayloadvalidator.go:31`, `controlplaneconfigpayloadvalidator.go:31`, `tenantapiaccess.go:32`, `nodemachineidlabel.go:33`, `rebootannotation.go:33`, `nodeagentprofilevalidator.go:30` and `spireagentpath.go:36`
- `CI/db/clusters.go:166`
- `CI/server/cluster_control_plane_config.go:170, 265, 364`
- `CI/server/clusters.go:802`
- `CI/server/node_pools.go:275, 633, 731, 792`

The code has 7 more comparisons with a provider type:

- `CI/db/clusters.go:128, 138, 150`
- `CI/dbmetrics/dbmetrics.go:389`
- `CI/server/clusters.go:956`
- `CI/server/node_pools.go:223`
- `CI/temporal/activities/capi_shared.go:37`

### What a pod provider hits on the infra path

1. **Kind check.** The kind `DockerMachineTemplate` selects the preflight that checks a sentinel file. It also selects the kubeadm container mode, which has these parts: ignore `SystemVerification`, `failSwapOn: false`, small reservations and no conntrack tuning (`CI/temporal/activities/capi_shared.go:59`, `CI/capi/manifest.go:14-35`, `CI/kubeadmconfig/render.go:304-325, 358-372`, `CI/kubeadmconfig/init.go:193-197`). A `PodMachineTemplate` gets the bare metal behaviour.
2. **Endpoint.** NVKE configures kube-vip when the cluster has a VIP. It skips kube-vip only when the VIP is empty (`CI/temporal/activities/configure_kube_vip.go:85-93`). An empty VIP blocks the lifecycle, as Q1 shows. NVKE has no mode for an endpoint with no kube-vip.
3. **etcd arguments.** The operator `extraArgs` cover the API server, the controller manager and the scheduler only (`CI/kubeadmconfig/extra_args.go:19-25`).
4. **Chart RBAC.** The chart names each infrastructure kind (`R/controller/deploy/charts/controller/templates/rbac-capi.yaml:48-61, 70-79`). New kinds need a rule.
5. **Deployment gate.** The deployment must enable the `infra` provider (`CI/server/node_pools.go:276-279`).
6. **Kubelet reservations.** The default is 16Gi plus 2Gi unless the pool sets them (`CI/kubeadmconfig/init.go:49-54`).
7. **Cluster API version.** NVKE compiles with Cluster API `v1.13.7` and the `v1beta2` types (`R/controller/go.mod:67`).

## Q4. Node address

**Conclusion.** NVKE uses one value, `node.IP`, for the agent dial, the kubeadm advertise address, the kubelet `node-ip`, kube-vip and the check of kubelet serving certificates. A LoadBalancer IP that is not on an interface in the pod breaks the kubelet and etcd. It also needs a path from the pod to its own address. The strongest form is the LoadBalancer IP as the node address, with the same IP on a dummy interface in the guest. NVKE then needs only the etcd listen addresses and the endpoint mode.

### Where NVKE uses the node IP

- **Set.** `CI/temporal/activities/capi_node_resources.go:262-314`.
- **Agent dial.** `CI/agent/transport.go:123-127` and `CI/rollout/adapters/controller/adapter.go:57`.
- **kubeadm init.** The `advertiseAddress` and the kubelet `node-ip` (`CI/kubeadmconfig/init.go:179-190`).
- **kubeadm join.** The `node-ip` for each join, and the `advertiseAddress` for a control plane join (`CI/kubeadmconfig/join.go:265-288`).
- **Endpoint fallback.** `CI/temporal/activities/kubeadm_init.go:80-83`.
- **kube-vip.** The field `NodeIp` in the request (`CI/temporal/activities/configure_kube_vip.go:138-145`). The agent finds the BGP interface by that address and uses the address for the health check (`AG/kube_vip.go:89, 221, 554`).
- **Kubelet serving certificate.** The IP in the request must equal `node.IP`, or NVKE does not approve the request (`CI/controllers/tenant/csr/controller.go:338, 357-364, 427-436`). The API server has `kubelet-certificate-authority` set (`CI/kubeadmconfig/init.go:251`).
- **etcd.** NVKE sets no etcd address (`CI/kubeadmconfig/init.go:225-239`).
- **certSANs.** NVKE sets none (`CI/kubeadmconfig/init.go:241-334`).
- **Other.** Some guards need an IP that is not empty, for example `CI/controllers/nodeagentreadiness/controller.go:117`.

### What breaks with a LoadBalancer IP that is not on an interface

1. **Kubelet.** `validateNodeIP` fails with the text "not found in the host's network interfaces". The node address setter then fails (`K8S/pkg/kubelet/kubelet_node_status.go:769-803`, `K8S/pkg/kubelet/nodestatus/setters.go:85-88`).
2. **etcd.** kubeadm sets `listen-client-urls` and `listen-peer-urls` from the advertise address (`K8S/cmd/kubeadm/app/phases/etcd/local.go:250-253`). etcd cannot bind to an address that is not local.
3. **API server probes.** The probe host is the advertise address (`K8S/cmd/kubeadm/app/phases/controlplane/manifests.go:67-69`, `K8S/cmd/kubeadm/app/util/staticpod/utils.go:298-304`). The pod must reach its own LoadBalancer IP, or the kubelet restarts the API server.
4. **kube-vip.** The agent cannot find an interface for the address.

### Guest interface

The agent reads each `/32` address on `lo` that is not a loopback address as the kube-vip VIP. The graceful shutdown removes that address (`AG/control_plane_graceful_shutdown.go:577-614`). So put the LoadBalancer IP on a dummy interface, not on `lo`.

### Listen address

The API server already binds `0.0.0.0` (`CI/kubeadmconfig/render.go:38`). I expect that a Service changes the destination to the pod IP. If it does, etcd must listen on `0.0.0.0` also when the LoadBalancer IP is on a guest interface. I did not test this.

### PR 2467

I read the description of [#2467](https://github.com/dsx-ai-factory/nvke/pull/2467) only. The pull request is open.

- It adds `nodeAgentConfig.tokenFrom` with the values `tokenExchange` and `metadataService`.
- It adds a `nodes.capi` payload with an optional agent dial address. `AgentDialHost()` falls back to `node.IP`.
- Both are outside the provider payload.
- It splits only the dial from the node address. The kubeadm, kubelet, kube-vip and certificate uses stay on `node.IP`.
- The description does not say which component writes the dial address.

## Q5. Restart and repair

**Conclusion.** NVKE has no automatic reaction to a restart or to a lost host of a control plane node. It sees two conditions change and starts nothing. If the address and the volumes stay, NVKE does not see a restart in place or a pod that is made again. A lost host stays a dead replica until some actor sets `NeedsRecycle` on the tenant Node or deletes the node through the API.

### Detection

- **Boot ID.** The reboot workflow compares `Node.status.nodeInfo.bootID` (`CI/temporal/activities/wait_for_node_reboot.go:87-93`).
- **Boot time.** The agent reads `journalctl --list-boots`, then `/proc/uptime` and `/proc/sys/kernel/random/boot_id` (`AG/node_reboot.go:98-165`). NVKE registers the workflow `RebootNodeWaitForUptime`, but I found no code that starts it.
- **nico-sim.** It binds a boot ID file from `/var`. It changes the ID only for a requested reboot (`R/controller/nico-sim/internal/container/service.go:29-42, 179-186`). No e2e test restarts a node container.
- **Health.** `NodeAgentReady` comes from an agent probe (`CI/controllers/nodeagentreadiness/controller.go:67-125`). `KubernetesReady` comes from the tenant Node (`CI/controllers/tenant/nodestatus/conditions.go:15-17`).
- **Cluster API.** It does nothing for a bare Machine. It records an error when the InfraMachine is gone (`B14/core/reconcilers/machine/machine_controller_phases.go#L260-L273`). MachineHealthCheck repairs only Machines that have a MachineSet or a KubeadmControlPlane as owner (`B14/docs/book/src/tasks/automated-machine-management/healthchecking.md#L239`).

### The three cases

| Case | What changes | What NVKE sees | What NVKE does |
|---|---|---|---|
| The container starts again in place | The pod IP and the volumes stay. The root filesystem returns to the image content. I expect the same Kata guest and so the same kernel boot ID (not tested) | `NodeAgentReady` is false for the gap. `KubernetesReady` can be false | Nothing |
| The pod is made again with the same volumes and Service | The pod IP, the guest and the boot ID are new. The LoadBalancer IP, the etcd data and the certificates stay | The same two conditions, and a new boot ID on the Node | Nothing. `node.IP` does not change |
| The host is lost | The pod cannot run. The local volume is lost or not reachable | Both conditions stay false or unknown | Nothing until `NeedsRecycle` or an API delete |

After a trigger for the lost host, NVKE checks the preconditions and the VIP gate (`CI/controllers/controlplane/remediation.go:34-37, 122-214`). It then deletes the node with `ForceUnreachable`, removes the etcd member and makes a new Machine.

### State that must stay

- The agent state is in `/var/lib/nvke/state.json`.
- The SPIRE agent keys are on disk in `/var/lib/spire-agent` (`CI/clients/capi/capi_spire_agent.conf.tmpl:19-23`).
- The join token is in the bootstrap data only.

## Q6. Cluster API

**Conclusion.** Versions 1.14 and 1.15 use the same `v1beta2` contract, and it fits the design. The core does not block two providers in one cluster. The limit is in the providers and in the single source of cluster data. Issue 14373 is open and has no accepted design. Existing projects use a StatefulSet for a control plane with state and a Deployment for a control plane with no state. The providers that make a node give the restart to a local owner, or they do not restart at all.

### Contract in v1.14.4 and v1.15.0-rc.0

- **InfraCluster.**
  - The contract requires `status.initialization.provisioned` (`B14/docs/book/src/developer/providers/contracts/infra-cluster.md#L334-L362`).
  - `spec.controlPlaneEndpoint` is optional, and the user can give the endpoint (`B14/docs/book/src/developer/providers/contracts/infra-cluster.md#L219-L260`).
  - `status.failureDomains` is a list of entries with `name`, `controlPlane` and `attributes` (`B14/docs/book/src/developer/providers/contracts/infra-cluster.md#L291-L330`).
- **InfraMachine.**
  - The contract requires `spec.providerID`. The value must equal the value on the Node (`B14/docs/book/src/developer/providers/contracts/infra-machine.md#L212-L235`).
  - Two Nodes with one ID are an error (`B14/core/reconcilers/machine/machine_controller_noderef.go#L240-L242`).
  - The contract requires `status.initialization.provisioned` (`B14/docs/book/src/developer/providers/contracts/infra-machine.md#L301-L329`).
  - The provider must place the machine in `Machine.spec.failureDomain` (`B14/docs/book/src/developer/providers/contracts/infra-machine.md#L237-L274`).
  - `status.addresses` is optional, and the core does not use it (`B14/docs/book/src/developer/providers/contracts/infra-machine.md#L278-L299`).
- **Difference in 1.15.** It has one new optional field, `status.interruptible` (`B15/docs/book/src/developer/providers/contracts/infra-machine.md#L371`).
- **Kinds.** The Machine controller reads only `Machine.spec.infrastructureRef`. It does not compare it with the kind of the cluster (`B14/core/reconcilers/machine/machine_controller_phases.go#L244-L377`).
- **Cluster data.** The endpoint and the failure domains come from the one InfraCluster (`B14/core/reconcilers/cluster/cluster_controller_phases.go#L217-L239`).

### Issue 14373

The issue is at https://github.com/kubernetes-sigs/cluster-api/issues/14373.

- It is open. It has the labels `priority/backlog` and `triage/accepted` and no milestone. Its create date is 2026-10-15.
- The problem is that machine controllers find their cluster object through the one `infrastructureRef`.
- It proposes no change in the core. It points to a method at the provider level, which copies the cluster settings to the machines.
- One maintainer comment says that it needs research and design for ClusterClass, for validation, and for the question of which provider defines the endpoint.
- The last comment names https://github.com/numspot/cluster-api-provider-composite as an early attempt.

### Existing projects

- **CAPD.** The machine controller makes the container itself. It does not make a provisioned container again. It only sets a condition. The address is the container IP. It sets the Node providerID itself. The source is https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.4/test/infrastructure/docker/internal/controllers/backends/docker/dockermachine_backend.go#L156-L250, and also lines 714 to 762 and 1012 to 1036 of that file.
- **KubeVirt provider, branch main.** It makes a `VirtualMachine`, and KubeVirt restarts the instance by the run strategy. The providerID is `kubevirt://<name>`. The address is the first interface IP of the instance. On a host drain it tries a live migration. If that is not possible, it reports a terminal state "so the MachineHealthCheck and MachineSet controllers" replace the machine. NVKE has neither of those. The source is https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt/blob/main/pkg/kubevirt/machine.go#L118-L176, and also lines 183 to 212, 405 to 412 and 434 to 500 of that file.
- **Kamaji.** It makes a `Deployment`. The data store is outside the pod, so the pods have no state. The source is https://github.com/clastix/kamaji/blob/26.11.5-edge/internal/builders/controlplane/deployment.go#L114-L155.
- **k0smotron.** It makes a `StatefulSet`. The persistence is `emptyDir` by default, or `hostPath`, or `pvc` through claim templates. The source is https://github.com/k0sproject/k0smotron/blob/v2.3.1/internal/controller/k0smotron.io/k0smotroncluster_statefulset.go#L126-L152, and also lines 343 to 391 of that file.
- **vcluster, branch main.** It makes a `StatefulSet` with a claim that has the retention `Retain`, and a headless Service. The backing store is embedded or external. The source is https://github.com/loft-sh/vcluster/blob/main/chart/values.yaml#L643-L717, and also lines 361 to 505 of that file.

## Candidate answers

### 1. Owner of the pod

The candidate is one StatefulSet for each `PodMachine`.

- It has these settings: 1 replica, `OnDelete`, claim templates with delete on StatefulSet delete, a PodDisruptionBudget, and tolerations for `node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable` with no time limit.
- The provider owns the StatefulSet and the Services. It never changes the template.
- The reason is that the Machine does not change, and the pod must return with no help from the management side.
- A bare Pod is the simpler fallback if a gate shows a problem with the pod name or with the claim templates.

### 2. Node address

The candidate is one LoadBalancer IP for each replica as `node.IP`, with the same IP on a dummy interface in the guest. It needs these changes:

- The node image adds the dummy interface.
- NVKE sets the etcd `listen-client-urls` and `listen-peer-urls` at `CI/kubeadmconfig/init.go:225-239`.
- The provider makes a Service with the agent port and the ports 6443, 2379, 2380 and 10250.

The other two forms have these limits:

- The advertise address becomes the endpoint of the `kubernetes` Service, so workers on a different network must reach it. A pod IP does not give that.
- A fixed pod IP needs a feature of the host CNI and the dial address of #2467.
- A separate dial address with a replacement at each restart needs #2467 and an automatic trigger. NVKE does not have that trigger.

### 3. Provider kinds and Cluster API change

The candidate is three kinds, `PodCluster`, `PodMachine` and `PodMachineTemplate`, through the `infra` path. It needs no new NVKE provider type. No source change in Cluster API is necessary.

- `PodMachine` must take its cluster settings from its own reference, not from `Cluster.spec.infrastructureRef`.
- For the cluster with two providers, `PodCluster` is the better `infrastructureRef`, because NVKE reads failure domains only for the control plane.
- Work on issue 14373 is optional. The issue has no agreed direction.

This design does need these NVKE changes:

1. An endpoint that is not kube-vip, and the VIP gates that go with it.
2. The etcd listen addresses.
3. The preflight and the kubeadm container mode for a kind that is not `DockerMachineTemplate`. The alternative is cloud-init in the image.
4. Chart RBAC for the new kinds.

### 4. Restart and repair

- A restart in place and a pod that is made again need no NVKE action, if the address stays and the volumes for `/etc/kubernetes`, `/var` and etcd stay.
- A lost host needs a replacement by NVKE, but some component must start it. One candidate is a small controller that sets `NeedsRecycle` on the tenant Node from the `PodMachine` state. The other candidate is a change in NVKE to read a condition of the InfraMachine.
- The provider must be able to delete a `PodMachine` when its pod and its volume are on a dead host.

## Not verified

- No test ran. The Kata behaviour on a container restart, the destination change by a Service and the dummy interface form are expectations.
- I did not read the diff of PR #2467, #2403 or #2379.
- `evidence.md` says that the NICo provider v0.1.0 does not need its cluster kind as the `infrastructureRef`. I did not verify that statement. The module cache has only an older version.
- The Kubernetes behaviour for a bare Pod and for a StatefulSet on a lost node, on a drain and with a local volume is from general knowledge. I read only the StatefulSet lines that this note cites.
- The SPIRE behaviour after a pod is made again with its key directory is from general knowledge.
- A helper read the Cluster API sources for the contract and for issue 14373. I checked a sample of its statements against the source text, not all of them.
- For Cluster API, I did not check the state of the issues and pull requests that issue 14373 links, the composite provider, `clusterctl move`, or ClusterClass with two kinds.
- The URLs for the KubeVirt provider and for vcluster are on branch main, not on a tag.
- I did not read `management-engine`, the etcd StatefulSet of k0smotron, or the cluster controller of the KubeVirt provider with its endpoint Service and its `infraClusterSecretRef`.
- I do not know if OVN-Kubernetes on the data hall cluster can give a fixed pod IP.
