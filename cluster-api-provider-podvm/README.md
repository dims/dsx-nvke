# Pod VM Cluster API infrastructure provider

This provider makes one pod for each Cluster API machine. The pod runs in a
virtual machine through a Kata RuntimeClass of the host cluster, so the node
has its own kernel. Each pod has two block volumes and one fixed address on the
node network.

Use it to run the control plane nodes of a cluster as pods of the cluster that
runs Cluster API. A new machine needs no spare host: the provider makes the pod,
the volumes and the address on demand, and it deletes them with the machine.

## Layout

| Path | Content |
|---|---|
| `api/v1alpha1/` | The three kinds, their deepcopy functions, and the provider ID format |
| `controllers/` | The cluster and machine reconcilers |
| `cmd/manager/` | The standalone controller-manager binary |
| `config/` | CRDs, RBAC, and the controller Deployment |
| `config/samples/` | Sample objects and a sample cluster request, with example values |
| `Dockerfile` | The standalone provider image |
| `node-image/` | The node image that the pods run, and the guest kernel options that it needs |

The provider imports nothing from the NVKE controller. It reads only the
Kubernetes API, Cluster API, and its own types. It has its own Go module, binary,
image, and deployment.

## Kinds

| Kind | Scope | Purpose |
|---|---|---|
| `PodVMCluster` | Namespaced | Says where and how the pods of one cluster run, and holds its address range |
| `PodVMMachine` | Namespaced | One machine: one pod, two volume claims, one address |
| `PodVMMachineTemplate` | Namespaced | The template that Cluster API renders into a machine |

A `PodVMCluster`:

```yaml
spec:
  podNamespace: cluster-pods        # must exist, the provider does not make it
  runtimeClassName: kata-clh        # a Kata runtime with a node kernel
  networkAttachment:
    name: nodenet                   # NetworkAttachmentDefinition of the node network
  addressRange:
    cidr: 172.28.1.0/24             # the block that the provider gives out
    prefixLength: 16                # the prefix length of the node network
  failureDomainLabelKey: topology.kubernetes.io/zone
  controlPlaneService:              # optional: the provider makes the Service
    annotations:                    # of the control plane endpoint
      lb.example.com/address: 192.0.2.10
```

A `PodVMMachineTemplate`:

```yaml
spec:
  template:
    spec:
      image: registry.example/podvm-node:v1.36.4
      resources:
        cpu: "2"
        memory: 6Gi
      volumes:
        var:
          storageClassName: fast-block
          size: 20Gi
        etcd:
          storageClassName: fast-block
          size: 8Gi
```

## What the cluster controller does

It checks the spec and reports `status.initialization.provisioned`. The core
Cluster API machine controller waits for that field.

```
1. spec.addressRange is an IPv4 block inside the node network, with at least
   one usable address.
2. The namespace of spec.podNamespace exists.
3. The block does not overlap the block of an older PodVMCluster. The older
   cluster keeps its range, so a new cluster cannot take addresses from it.
4. Publish status.failureDomains from the nodes of the host cluster.
5. With spec.controlPlaneService: make the Service of the control plane
   endpoint, and wait until the load balancer gave it an address.
```

The provider does not use the first and the last address of the block, and it
does not use the network address and the broadcast address of the node network.
The block `172.28.1.0/24` gives the addresses `172.28.1.1` to `172.28.1.254`.

A failure domain is one value of the node label `spec.failureDomainLabelKey`.
When no node carries that label, each host node is one failure domain, from the
label `kubernetes.io/hostname`. A node that is unschedulable, or that has a
taint with the effect `NoSchedule` or `NoExecute`, is in no failure domain. Each
domain has `controlPlane: true`.

A cluster with no control plane Service has no finalizer, and its delete never
waits for the provider.

### Fields that cannot change

The provider makes the pod of a machine again after a lost pod and after a
reboot request, from the `PodVMCluster` as it is at that time. So a changed
field would reach the machines that exist one at a time, in no order, each on
the volumes of its old pod. The API server refuses a change of these fields:

| Field | What a change would do |
|---|---|
| `podNamespace` | New machines would run in another namespace than the machines that exist and the control plane Service |
| `addressRange` | The machines that exist hold addresses of the old block |
| `controlPlaneService` | See [The control plane Service](#the-control-plane-service) |
| `runtimeClassName` | The next pod of each machine would run in another runtime. What the RuntimeClass names can change in the host cluster, for example with a new version of Kata |
| `networkAttachment` | The next pod of each machine would be on another network than the pods that still run, with an address of the same block |
| `failureDomainLabelKey` | The cluster would report other failure domains than the ones that the machines that exist name. The next pod of a machine that was placed by a value of the old label would find no host node |

These are all fields of the spec: a `PodVMCluster` does not change after it
exists. The labels of the host nodes can change, and the cluster then reports
the failure domains of the new values. A machine that exists keeps the failure
domain that it names, so a host node must keep a value that such a machine
names.

### The control plane Service

With `spec.controlPlaneService` the cluster controller makes the shared endpoint
of the API servers: one Service of the type `LoadBalancer` in the pod namespace.

| Point | Value |
|---|---|
| Name | `<cluster-name>-control-plane`, from the name of the owner Cluster |
| Selector | `cluster.x-k8s.io/cluster-name: <cluster-name>` and `cluster.x-k8s.io/control-plane: ""`, the two labels of a control plane pod |
| Port | 6443, to port 6443 of the pod |
| From the spec | `annotations`, `loadBalancerClass` and `externalTrafficPolicy` |

The NVKE controller takes the endpoint from its own cluster request, so the
address of the Service must be known before the request. Ask the load balancer
for a fixed address in `annotations`, and give the same address to the NVKE
controller as `controlPlaneEndpoint`.

The cluster is not provisioned before the Service has an address, because the
first node of the cluster needs the endpoint. Until then the `Ready` condition
is false with one of these reasons:

| Reason | Meaning |
|---|---|
| `WaitingForOwnerCluster` | Cluster API has not set the owner reference yet. The Service selects the name of the owner Cluster |
| `ControlPlaneServiceNameInvalid` | The name of the Cluster gives no valid Service name. It must start with a letter, have no dot, and have at most 49 characters |
| `ControlPlaneServiceConflict` | A Service with that name exists and belongs to something else. The provider does not change it and does not delete it |
| `WaitingForLoadBalancerAddress` | The Service exists, and the load balancer gave it no address yet |

`spec.controlPlaneService` cannot be added, removed or changed after the
`PodVMCluster` exists. The provider makes a Service that is gone again, and it
does not change a Service that exists.

A finalizer holds a `PodVMCluster` with a control plane Service until that
Service is gone. The provider deletes only the Service that carries its owner
labels with the UID of the cluster.

With no `spec.controlPlaneService` the provider makes no Service, and the caller
brings the endpoint.

## What the machine controller does

```
1. Wait for the owner Machine and for its spec.bootstrap.dataSecretName.
2. Take the lowest free address of the range. The set of used addresses is
   status.address of every PodVMMachine, read from the API server at that
   moment. There is no allocation table.
3. Write status.address, status.hardwareAddress, status.podNamespace and
   status.podName. This happens before any object exists.
4. Copy the bootstrap Secret into the pod namespace, one time.
5. Make the two volume claims and the pod.
6. When the node agent in the pod answers, write status.addresses, then
   spec.providerID, then status.initialization.provisioned.
7. Set spec.providerID on the Node of the new cluster.
```

### When a machine is ready

A machine is ready when the node agent in its pod answers. The pod has a startup
probe that opens a TCP connection to port 15005, the secure port of
`nvke-agent`, each 2 seconds. When the connection works, the kubelet marks the
container `node` as started. The provider then writes `status.addresses`, the
provider ID and the provisioned flag, in that order.

The reason is the next step of the NVKE controller. It waits for an address,
stores it one time, and calls the node agent at that address a moment later. A
failed call costs it a long retry wait. So the provider does not report the
address at the allocation, when no pod exists. `status.address` holds the
address from the allocation on, for the uniqueness rule and for an operator.

The probe gives a node 20 minutes to come up. After that the kubelet starts the
container again, with the same volumes.

Until then the `Ready` condition is false. The reason is `WaitingForPod` while
the pod does not run, and `WaitingForNodeAgent` while the pod runs and the agent
does not answer. A pod that the scheduler cannot place has a reason of its own,
see [A pod with no place](#a-pod-with-no-place).

A create call that the API server of the host cluster rejects has the reason
`CreateRejected`, and the message is the answer of the API server. Examples are
a RuntimeClass that does not exist, a pod security rule of the pod namespace
and a quota. The controller tries again after 30 seconds.

The controller reconciles one machine at a time, and the Deployment runs with
leader election. Both are needed: step 2 is safe only when one writer gives out
addresses.

The machine controller keeps a cache of the pods that carry its owner labels
only. It reads Secrets and volume claims directly from the API server and keeps
no cache of them.

### The pod

This is the contract with the node image. The image side is in
[node-image/](node-image/README.md).

| Point | Value |
|---|---|
| Name and hostname | The name of the owner Machine. A new pod for the same machine has the same name |
| Namespace | `spec.podNamespace` of the `PodVMCluster` |
| Container | One container named `node`, privileged, with the image of the machine. No command and no arguments |
| Runtime class | `spec.runtimeClassName` of the `PodVMCluster` |
| Resources | The CPU and the memory of the machine, as limits and as requests |
| Volume devices | `/dev/podvm-var` and `/dev/podvm-etcd`, from the claims `<name>-var` and `<name>-etcd` with the volume mode `Block` |
| Bootstrap data | The Secret `<name>-bootstrap`, mounted read only at `/etc/podvm/bootstrap`, with the file `value` |
| Environment | `PODVM_MACHINE_NAME`, `PODVM_NODE_ADDRESS` (the address with the prefix length), `PODVM_NODE_INTERFACE` (`net1`) |
| Network annotation | `k8s.v1.cni.cncf.io/networks` with one entry: the name and the namespace of the network attachment, `ips` with the address, `mac` with the hardware address |
| Hardware address | `02:00` and the four bytes of the address. `172.28.1.21` gives `02:00:ac:1c:01:15` |
| Labels | `cluster.x-k8s.io/cluster-name`, `cluster.x-k8s.io/control-plane` when the Machine has it, `podvm.infrastructure.cluster.x-k8s.io/machine-name`, and three labels that name the owner `PodVMMachine` |
| Startup probe | For each machine: a TCP connection to port 15005 (`nvke-agent`), each 2 seconds, for at most 20 minutes |
| Readiness probe | For a control plane machine: the program `/usr/local/bin/podvm-endpoint-ready` of the node image, run in the container `node`, each 2 seconds, with 3 seconds for an answer. The pod is out after 3 failures in a row |
| Grace period | 20 seconds for a pod that is deleted |
| Provider ID | `podvm://<pod-namespace>/<pod-name>` |

The pod has no token of the host cluster and no service links.

The control plane Service selects the first two labels, so it is one shared
endpoint for the API servers. Only a pod with a ready API server is behind it.
The provider makes that Service when the `PodVMCluster` asks for it, see
[The control plane Service](#the-control-plane-service).

The readiness probe is the health check of that Service. It runs the program
`podvm-endpoint-ready` in the guest, and the node image must have it. The
program passes when both of these are true:

- The endpoint gate file of the node does not exist.
- `/readyz` of the local API server answers within 2 seconds with a status
  code below 400.

The node agent writes the gate file before an operation that restarts the API
server, and removes it after the operation. So the Service stops new connections
to a node while its API server still answers. A call from the kubelet to port
6443 cannot see the gate, which is why the probe runs a program and makes no
HTTPS call. The provider does not know the path of the gate file: the node image
sets it for the program and for the node agent. The gate needs a node agent
that has it, see [What the NVKE controller needs](#what-the-nvke-controller-needs).

The readiness probe takes a pod out of that Service after about 6 seconds of
failed answers, and after about 9 seconds when each probe runs into its time
limit. One slow answer does not take a pod out.

A deleted pod gets 20 seconds to stop. A control plane node does not stop by
itself in the default of 30 seconds, so a longer time only delays the new pod
after a reboot request, and the end of a delete.

### Placement

`Machine.spec.failureDomain` becomes a required node rule of the pod: the node
has that value in the label `spec.failureDomainLabelKey`, or it is the host node
with that name. The pods of one cluster prefer different host nodes. That rule
is a preference, so the extra pod of a rollout can start.

### A pod with no place

The scheduler of the host cluster can find no node for a pod, for example when
the host node of the failure domain has no free volume or not enough memory. It
then writes the pod condition `PodScheduled` with the status `False` and the
reason `Unschedulable`. The pod stays pending, and the scheduler tries again
when the host cluster changes.

The provider reports that state in the `Ready` condition of the `PodVMMachine`,
with the status `False`:

| The Machine | Reason | Message |
|---|---|---|
| Names a failure domain | `FailureDomainUnavailable` | The pod, the failure domain and the text of the scheduler |
| Names no failure domain | `PodUnschedulable` | The pod and the text of the scheduler |

The provider does not delete the pod and does not move it. When the pod gets a
node, the reason goes back to `WaitingForPod`, and the machine comes up the
usual way. Another reason of `PodScheduled`, for example `SchedulerError`, is
not reported this way.

`FailureDomainUnavailable` is a contract with the NVKE controller. Cluster API
copies the `Ready` condition of the `PodVMMachine` into the
`InfrastructureReady` condition of the Machine, with the same status, reason
and message. The NVKE controller reads the reason there. When a control plane
node that never ran waits for 15 minutes with that reason, and the cluster has
another failure domain, the NVKE controller deletes the node and makes a new
one in another failure domain. It then does not use the first failure domain
for 3 hours. It also shows the message as the pending message of the node. The
provider sets this reason for no other state. The move needs an NVKE controller
that reads the reason, see
[What the NVKE controller needs](#what-the-nvke-controller-needs).

The new node can land on a host node that already has a control plane node of
the cluster, because the spread rule of the pods is a preference.

### A lost pod and a reboot

When the pod of a machine is gone, the provider makes it again with the same
name, the same claims, the same address and the same hardware address. The node
keeps its state on the two volumes. The provider does not copy the bootstrap
Secret again when the copy exists. A pod in the phase `Failed` or `Succeeded`
counts as lost: the provider deletes it and makes it again.

While the new pod starts, `status.addresses`, the provider ID and the
provisioned flag stay as they are. The NVKE controller already knows the node
by them, and a removed address would look like a lost machine. Only the `Ready`
condition says that the node is not there yet.

The NVKE controller asks for a hard reboot with the annotation
`nvke.nvidia.com/reboot` on the Machine. The provider answers each new value of
the annotation one time: it deletes the pod, and the rule above makes the pod
again. It records the value in `status.lastRebootRequest`. The new virtual
machine has a new boot ID, which is the signal that the NVKE controller waits
for. The provider does not remove the annotation and does not write the
annotation `nvke.nvidia.com/reboot-complete-timestamp`: the NVKE controller
removes its request when it sees the new boot ID.

### Delete

On the delete of a `PodVMMachine`, in each state of the machine, the provider
deletes the pod, the two volume claims and the copy of the bootstrap Secret.
It waits until all of them are gone and then removes its finalizer. The address
is free when the `PodVMMachine` is gone, so no new machine gets the address
while the old pod still runs.

The provider deletes only objects that carry its owner labels with the UID of
the machine. An object with the same name that belongs to something else stays.

A run can start from a cache that still shows a machine that is gone, most often
right after the finalizer was removed. Its write then gets "not found". The
provider asks the API server for the machine, and when the machine does not
exist the run ends with one line at the info level and no error. A "not found"
answer for a machine that exists is still an error.

## How the Node gets its provider ID

After the node agent answers, the machine controller reads the standard CAPI
`<cluster-name>-kubeconfig` Secret from the cluster namespace. It uses that
kubeconfig to find the Node with the name of the Machine in the new cluster and
sets `Node.spec.providerID`.

The machine controller does not overwrite a different provider ID. It reports
that conflict in the `Ready` condition. It waits and tries again when the
kubeconfig Secret or the Node does not exist yet.

An API server that does not answer is a wait too, not an error. This is the
state of a cluster before its first node is initialized and after the NVKE
controller reset its control plane nodes for a delete. The machine stays ready,
the message of the `Ready` condition says that the provider ID of the Node is
not checked, and the controller looks again after 30 seconds. An API server
that answers and rejects the call, for example for missing rights, is an error.

The controller does not look at the Node of a machine that is being deleted:
neither when the `PodVMMachine` has a delete time, nor when its owner Machine
has one.

The look ends when Cluster API has found the Node. Cluster API finds the Node
by the provider ID and then sets `status.nodeRef` of the Machine. From then on
the controller does not call the new cluster for that machine. Each look has a
limit of 5 seconds, because the controller reconciles one machine at a time.

## What the provider does not do

- It does not make the pod namespace, the RuntimeClass, the network attachment
  or a storage class. They are inputs.
- It does not choose the address of the control plane endpoint. The caller asks
  the load balancer for a fixed address and gives the same address to the NVKE
  controller.
- It does not move a pod after the loss of a host node. A volume of a lost node
  may not attach on another node, and nothing fences the old virtual machine.
  An operator starts the replace.
- It does not act on a pod that cannot be scheduled. The pod stays pending, and
  the machine stays not provisioned. The provider reports the state, and the
  NVKE controller decides.
- It does not check another user of the node network. The address range must
  belong to the provider alone.
- It does not support IPv6 addresses. The hardware address comes from an IPv4
  address.
- It does not change a pod in place. A new image, a new size or new volumes
  are a new machine. The API server enforces it: `spec.image`,
  `spec.resources` and `spec.volumes` of a `PodVMMachine` cannot change. A
  `PodVMMachineTemplate` can change, and the change reaches only machines that
  are made after it.
- It does not build the node image. The image must meet the pod contract above,
  as the image of `node-image/` does.

## Use with the NVKE controller

The NVKE controller takes the two objects on its `infra` path. The shape of the
request:

```json
{
  "controlPlaneEndpoint": "<shared address>:6443",
  "controlPlaneConfig": {
    "desiredCount": 3,
    "infra": {
      "machineTemplate": {
        "apiVersion": "infrastructure.cluster.x-k8s.io/v1alpha1",
        "kind": "PodVMMachineTemplate",
        "spec": {"template": {"spec": {"image": "...", "resources": {}, "volumes": {}}}}
      }
    }
  },
  "infra": {
    "cluster": {
      "apiVersion": "infrastructure.cluster.x-k8s.io/v1alpha1",
      "kind": "PodVMCluster",
      "spec": {
        "podNamespace": "...", "runtimeClassName": "...", "networkAttachment": {}, "addressRange": {},
        "controlPlaneService": {"annotations": {"lb.example.com/address": "<shared address>"}}
      }
    }
  }
}
```

The controller chart grants the NVKE controller the rights for the three kinds
and their CRDs with the values `capi.rbac.create` and `capi.rbac.podvm`.

### Samples

`config/samples/` has a complete set with example values. Each value is a
placeholder for a value of your site.

| File | Content |
|---|---|
| [`podvmcluster.yaml`](config/samples/podvmcluster.yaml) | A `PodVMCluster` with a control plane Service |
| [`podvmmachinetemplate.yaml`](config/samples/podvmmachinetemplate.yaml) | A `PodVMMachineTemplate` for control plane machines |
| [`networkattachmentdefinition.yaml`](config/samples/networkattachmentdefinition.yaml) | A NetworkAttachmentDefinition that takes the address and the hardware address from the pod annotation |
| [`storageclass.yaml`](config/samples/storageclass.yaml) | A storage class for block volumes that binds at the first use |
| [`nvke-cluster-request.json`](config/samples/nvke-cluster-request.json) | An NVKE cluster request that carries the two objects |

A test checks each object of the provider against the schema of its generated
CRD, and that the five files name each other.

### Roll to a new image

A machine never gets a new image or a new size. To change one of them for the
control plane nodes, send the whole machine template again with the new value.
`<API_URL>` and the API token are described in
[Manage node pools](../docs/workload-clusters/node-pools.md).

```bash
curl -X PATCH "<API_URL>/api/clusters/<CLUSTER_ID>" \
  -H 'Content-Type: application/json' \
  -d '{"controlPlaneConfig": {"infra": {"machineTemplate": {
        "apiVersion": "infrastructure.cluster.x-k8s.io/v1alpha1",
        "kind": "PodVMMachineTemplate",
        "spec": {"template": {"spec": {
          "image": "registry.example.com/nvke/podvm-node:1.36.3-2",
          "resources": {"cpu": "4", "memory": "8Gi"},
          "volumes": {
            "var": {"storageClassName": "block-storage", "size": "40Gi"},
            "etcd": {"storageClassName": "block-storage", "size": "10Gi"}
          }
        }}}
      }}}}'
```

The NVKE controller then replaces each control plane node whose template
differs from the new one, one node at a time. The rules are those of step 1 in
[Upgrade the control plane](../docs/workload-clusters/upgrade.md#upgrade-the-control-plane):
`enableCPNodeRecycling` must be on, and with `maxSurge: 1` each new node comes
before an old one goes. The NVKE controller refuses the request for a cluster
with no shared endpoint, see
[What the NVKE controller needs](#what-the-nvke-controller-needs).

Each new node is a new Machine with a new pod, two new volumes and a new
address. So a rollout with `maxSurge: 1` needs one free address in the range
and two free volumes. The address of an old node is free, and its two claims
are deleted, when its `PodVMMachine` is gone.

## What the NVKE controller needs

The chart values that the NVKE controller needs for this provider are in
[Pod VM](../docs/site-bootstrap/infrastructure-providers.md#pod-vm) of the
infrastructure providers page: the `infra` provider, the rights for the three
kinds, node attestation with a join token, and the reboot setting.

Three behaviors on this page are not part of the provider. Each one is a change
of the NVKE controller or of the node agent with its own review. In a build that
does not have the change, the behavior is absent.

| Behavior | Needs | Without it |
|---|---|---|
| The cluster request takes `controlPlaneEndpoint` | An NVKE controller with that request field | The endpoint of a cluster is the address of its first control plane node, and the control plane Service is not used |
| The node agent writes the endpoint gate file | A node agent with the endpoint gate, and a node image that tells it the gate file | The readiness probe follows `/readyz` only, so a node leaves the Service when its API server stops and not before |
| The NVKE controller moves a control plane node that waits with `FailureDomainUnavailable` | An NVKE controller that reads this reason for a provider on the `infra` path | The NVKE controller shows the message, and the node waits |

## Install

### What the host cluster needs

- Cluster API core that serves `cluster.x-k8s.io/v1beta2`.
- A Kata RuntimeClass. Its guest kernel must have what a node of the new
  cluster uses: Open vSwitch and Geneve for the pod network, and socket
  diagnostics with the destroy operation, which the node agent uses to close
  the connections of a node.
- A Kata agent that can run a program in a container in which systemd runs.
  The readiness probe of a control plane pod is such a call. With Kata
  Containers 4.4.0 the call fails without a change of the agent, and then no
  control plane pod gets ready.
- Multus, and a NetworkAttachmentDefinition that takes the address and the
  hardware address from the pod annotation. See
  [The node network](#the-node-network).
- A storage class for block volumes. See
  [The block volumes](#the-block-volumes).
- A pod namespace that allows privileged pods. The container `node` is
  privileged.
- For the control plane Service: a load balancer for Services of the type
  `LoadBalancer` that can give a fixed address.

### The node network

Each pod has a second interface, `net1`, on the node network. Its address is
the address of the node. The NVKE controller calls the node agent there, and it
sets the same address as the node address of the kubelet and as the advertise
address of the API server.

The network attachment must take the address and the hardware address from the
pod annotation. For the bridge plugin that is the capabilities `ips` and `mac`
with the static address plugin, as in the
[sample](config/samples/networkattachmentdefinition.yaml). The sample sets no
gateway and no masquerade, so the default route of a pod stays on its first
interface.

The node network must connect these, with no address translation between them:

- The pods of one cluster on all host nodes. A bridge that is not connected
  between the host nodes joins only the pods of one host node.
- Each worker of the cluster. The control plane nodes and the workers call each
  other at their node addresses, and the pod network of the cluster runs
  between these addresses.
- The NVKE controller, which calls port 15005 of each node address.

On `net1` a pod has the prefix length of the node network,
`addressRange.prefixLength`. So it reaches each address of the node network
directly, and the sample gives it no route there to an address outside of it.

### The block volumes

Each machine has two volume claims, `<name>-var` and `<name>-etcd`, with the
volume mode `Block` and the access mode `ReadWriteOnce`. The machine template
names the storage class and the size of each. The node image makes the
filesystems.

The storage class must give:

- Block volumes. With a class that gives only filesystem volumes the claims
  stay pending.
- Binding at the first use, `volumeBindingMode: WaitForFirstConsumer`, when a
  volume stays on one host node. The scheduler then picks a host node in the
  failure domain of the machine first, and the volume follows. With immediate
  binding the volume can be on a host node outside the failure domain, and the
  pod never gets a node.
- An empty volume for each new machine. The provider deletes the two claims
  with the machine and wipes nothing. What happens to the volume then is the
  reclaim policy of the class. A volume that is kept is `Released`, and no new
  claim binds to it before someone cleans it and makes it available again.

A volume that stays on one host node ties the machine to that node: a new pod
for the same machine runs there again. When no host node of the failure domain
has a free volume, the scheduler cannot place the pod, and the machine reports
`FailureDomainUnavailable`, see [A pod with no place](#a-pod-with-no-place).

[`config/samples/storageclass.yaml`](config/samples/storageclass.yaml) is a
class for volumes that an operator makes by hand. A CSI driver that makes block
volumes on demand has its own class.

### Build and push the image

No image of the provider is published. Build it and push it to a registry that
the host cluster can pull from. From the repository root:

```bash
REPO=registry.example.com/nvke/cluster-api-provider-podvm
make -C cluster-api-provider-podvm docker-push-arch IMG_REPO="$REPO" PUSH_TAGS=v0.1.0 ARCH=amd64
make -C cluster-api-provider-podvm docker-push-arch IMG_REPO="$REPO" PUSH_TAGS=v0.1.0 ARCH=arm64
make -C cluster-api-provider-podvm docker-manifest IMG_REPO="$REPO" PUSH_TAGS=v0.1.0
```

`docker-push-arch` builds one architecture and pushes it as
`<repo>:<tag>-<arch>`. Run it on a machine of that architecture, or with a
builder that can build it. `docker-manifest` joins the two into `<repo>:<tag>`.
For a host cluster with one architecture, run the first command only and use
the tag `v0.1.0-amd64` below.

`make docker-build` pushes nothing. It writes an OCI archive for both
architectures to `out/cluster-api-provider-podvm.oci.tar`.

### Render and apply the manifests

```bash
CONTROLLER_IMG="$REPO:v0.1.0" cluster-api-provider-podvm/hack/release-manifests.sh
kubectl apply -f cluster-api-provider-podvm/out/infrastructure-components.yaml
kubectl -n podvm-system rollout status deployment/podvm-controller-manager
```

The manifests hold the three CRDs, the RBAC and the Deployment
`podvm-controller-manager`, in the namespace `podvm-system`.
`out/infrastructure-components.yaml` and `out/metadata.yaml` are also the
artifacts for a clusterctl provider repository.

`kubectl apply -k cluster-api-provider-podvm/config/default` installs the same
objects with the placeholder image
`docker.io/library/cluster-api-provider-podvm:latest` and the pull policy
`IfNotPresent`. It gives a running provider only where that image is already in
the image store of the node, for example in a local test cluster that loads the
image.

## Regenerating

The module pins `controller-gen`. Generate the deepcopy implementations, CRDs,
and controller RBAC with:

```bash
make -C cluster-api-provider-podvm generate manifests
```

Commit the generated files. `generate-check` fails when they are stale.
