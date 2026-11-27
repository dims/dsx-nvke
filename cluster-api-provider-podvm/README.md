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
| `config/` | CRDs, RBAC, the controller Deployment, and sample objects |
| `hack/nvke-controller-rbac.yaml` | The rights that the NVKE controller needs for the kinds, for a lab |
| `Dockerfile` | The standalone provider image |

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
```

The provider does not use the first and the last address of the block, and it
does not use the network address and the broadcast address of the node network.
The block `172.28.1.0/24` gives the addresses `172.28.1.1` to `172.28.1.254`.

A failure domain is one value of the node label `spec.failureDomainLabelKey`.
When no node carries that label, each host node is one failure domain, from the
label `kubernetes.io/hostname`. A node that is unschedulable, or that has a
taint with the effect `NoSchedule` or `NoExecute`, is in no failure domain. Each
domain has `controlPlane: true`.

The cluster controller holds no finalizer. A delete of the `PodVMCluster` never
waits for the provider.

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
failed call costs it a retry wait that starts at 30 seconds and grows to 2
minutes. So the provider does not report the address at the allocation, when no
pod exists. `status.address` holds the address from the allocation on, for the
uniqueness rule and for an operator.

The probe gives a node 20 minutes to come up. After that the kubelet starts the
container again, with the same volumes.

Until then the `Ready` condition is false. The reason is `WaitingForPod` while
the pod does not run, and `WaitingForNodeAgent` while the pod runs and the agent
does not answer.

The controller reconciles one machine at a time, and the Deployment runs with
leader election. Both are needed: step 2 is safe only when one writer gives out
addresses.

The machine controller keeps a cache of the pods that carry its owner labels
only. It reads Secrets and volume claims directly from the API server and keeps
no cache of them.

### The pod

This is the contract with the node image. The image side is not in this module.

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
| Readiness probe | For a control plane machine: HTTPS GET `/readyz` on port 6443, each 2 seconds, with 3 seconds for an answer. The pod is out after 3 failures in a row |
| Grace period | 20 seconds for a pod that is deleted |
| Provider ID | `podvm://<pod-namespace>/<pod-name>` |

The pod has no token of the host cluster and no service links.

A Service of the caller can select the first two labels to get one shared
endpoint for the API servers. Only a pod with a ready API server is behind it.
The provider does not make that Service.

The readiness probe takes a pod out of that Service after about 6 seconds of
failed answers, and after about 9 seconds when each probe runs into its time
limit. One slow answer does not take a pod out. With a time limit of 1 second
and one failure, a slow disk took every pod of a control plane out at one time.

A deleted pod gets 20 seconds to stop. A control plane node does not stop by
itself in the default of 30 seconds, so a longer time only delays the new pod
after a reboot request, and the end of a delete.

### Placement

`Machine.spec.failureDomain` becomes a required node rule of the pod: the node
has that value in the label `spec.failureDomainLabelKey`, or it is the host node
with that name. The pods of one cluster prefer different host nodes. That rule
is a preference, so the extra pod of a rollout can start.

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

## What the provider does not do

- It does not make the pod namespace, the RuntimeClass, the network attachment
  or a storage class. They are inputs.
- It does not make the shared endpoint Service of the control plane. The caller
  makes it before the cluster request.
- It does not move a pod after the loss of a host node. A volume of a lost node
  may not attach on another node, and nothing fences the old virtual machine.
  An operator starts the replace.
- It does not report "no capacity". A pod that cannot be scheduled stays
  pending, and the machine stays not provisioned.
- It does not check another user of the node network. The address range must
  belong to the provider alone.
- It does not support IPv6 addresses. The hardware address comes from an IPv4
  address.
- It does not change a pod in place. A new image or a new size is a new
  machine.
- It does not build the node image. The image must meet the pod contract above.

## Use with the NVKE controller

The NVKE controller takes the two objects on its `infra` path:

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
      "spec": {"podNamespace": "...", "runtimeClassName": "...", "networkAttachment": {}, "addressRange": {}}
    }
  }
}
```

The controller chart grants no rights for these kinds. For a lab, apply
`hack/nvke-controller-rbac.yaml`. `config/samples/` holds a `PodVMCluster` and a
`PodVMMachineTemplate` with complete specs.

## Install

Build the image and render the clusterctl artifacts from the repository root:

```bash
make -C cluster-api-provider-podvm docker-build \
  IMG=registry.example/cluster-api-provider-podvm:v0.1.0
CONTROLLER_IMG=registry.example/cluster-api-provider-podvm:v0.1.0 \
  cluster-api-provider-podvm/hack/release-manifests.sh
```

For a source-tree installation:

```bash
kubectl apply -k cluster-api-provider-podvm/config/default
```

The generated `cluster-api-provider-podvm/out/infrastructure-components.yaml`
and `metadata.yaml` are the artifacts for a clusterctl provider repository.

The host cluster needs a Kata RuntimeClass, Multus with a network attachment
that takes the address and the hardware address from the pod annotation, and
a storage class for block volumes.

## Regenerating

The module pins `controller-gen`. Generate the deepcopy implementations, CRDs,
and controller RBAC with:

```bash
make -C cluster-api-provider-podvm generate manifests
```

Commit the generated files. `generate-check` fails when they are stale.
