# Control plane nodes as Kata pods

**Status:** proposed
**Date:** 2026-11-27

## Context

The [roadmap](../../ROADMAP.md) lists "Run control planes on virtual machines" as work in progress. Today the control plane follows the provider of its cluster (`CreateClusterControlPlaneConfig` in [`openapi.yaml`](../../controller/api/openapi.yaml)), and with NVIDIA Infra Controller (NICo) each control plane node is a dedicated bare-metal machine.

NVKE keeps its control plane lifecycle in the node agent and in the controller workflows. The agent runs kubeadm, and kubeadm runs the API server and etcd as static pods of the kubelet. By our count, 14 of the 53 RPCs in [`node_agent.proto`](../../agent/pkg/agent/proto/node_agent.proto) act on those static pods, so a form of hosting with no kubelet needs new code for them.

CI already runs control plane nodes as privileged containers, with [nico-sim](../../controller/nico-sim/README.md). A Kata pod runs such a container in a small virtual machine with its own kernel, the guest. A comment in [`spire-values.yaml`](../../cli/internal/bootstrap/controllerdeploy/manifests/spire-values.yaml) records that the control plane nodes of a site run Kata.

No provider in the tree can make such a pod. `infra` only accepts Cluster API manifests from the caller ([Infrastructure providers](../operate/infrastructure-providers.md)), and the [provisioned provider](../../cluster-api-provider-provisioned/README.md) cannot delete a machine that claimed a host. The proposed [composable architecture](20261105-capi-architecture.md) names infrastructure machines that join the workload cluster as control plane nodes as one possible hosting model.

We tested the form in a lab on one amd64 machine with nested virtualization, where the cluster that ran the pods had three worker nodes, each a container. With Kata Containers 4.4.0, Cloud Hypervisor and a prototype of the provider, one request to the NVKE API made a cluster with three control plane nodes in each of five creates. Delete, node replace, rollout, etcd encryption, key rotation, certificate renewal and an upgrade from Kubernetes 1.35.5 to 1.36.4 completed with the workflows that exist, after the agent fix that Consequences describes.

## Decision

We will let NVKE run each control plane node of a workload cluster as one Kata pod on a host cluster, which is the Kubernetes cluster that runs the pods. The pod runs a node image with systemd, containerd, the kubelet and `nvke-agent`. NVKE uses the same node agent and the same controller workflows as on bare metal.

We will add a Cluster API infrastructure provider as a new module beside `cluster-api-provider-provisioned`. For each Machine, the provider makes the pod, its volumes and its bootstrap data, and it removes them when NVKE deletes the Machine. It makes a lost pod again with the same name, volumes and address. Until the provider has its own object in the REST API, a caller reaches it through `infra`.

The lab settled the following parts:

- **Node address.** Each pod has a fixed address on a second interface, on a network that reaches the other nodes with no NAT. The provider takes the address from a range in its cluster object and keeps it for the life of the Machine.
- **Endpoint.** The API servers of a cluster share one endpoint address, which forwards only to pods whose API server is ready. The caller gives the address to NVKE in a new optional field of the cluster create request, and NVKE configures no kube-vip for that cluster.
- **Storage.** Each pod has two raw block volumes, one for `/var` and one for the etcd data. A new Machine gets empty volumes.
- **Placement.** The provider publishes one failure domain for each host node, and it places each pod in the failure domain that NVKE chose.

We propose the following parts, and they have no test result yet:

- **Health gate.** The node agent gets a second way to withdraw a node before an operation, for an endpoint that the node does not run. The agent closes a gate that the health check of the load balancer reads, and then closes the open connections of remote clients. With no gate configured, the agent behaves as today.
- **Capacity signal.** An infrastructure machine reports the condition `Ready` as `False` with the reason `FailureDomainUnavailable` when its provider cannot place it in the failure domain of its Machine. The client for template-backed providers reads that reason, so the rule that moves a pending control plane node to another failure domain applies.

## Consequences

A workload cluster needs no dedicated bare-metal machines for its control plane, and NVKE keeps one control plane lifecycle. A replace or a rollout needs no spare host, because the provider makes a pod on demand. With fixed addresses, etcd runs with the kubeadm defaults, and pod traffic between the control plane nodes worked in 6 of 6 directions in the lab.

The decision makes the following parts harder:

- **Host cluster.** The host cluster must supply a secondary network that gives a pod an interface with the address and the hardware address from the pod specification, a storage driver that gives a new raw block volume to each claim, and a load balancer for the endpoint. The lab used lab parts for all three.
- **Guest kernel.** The stock Kata guest kernel has no Open vSwitch and no Geneve, so the kernel datapath of the pod network needs a guest kernel build for each Kata release. Upstream Kata does not test a kubelet in the guest, and the lab needed two changes to the Kata agent.
- **Node image.** The node image of the pods has no place in the repository yet, because `os-image/` builds a QCOW2 only.
- **Agent.** The agent can no longer assume that the node address is on the interface of the default route. Today it gives kubeadm a config for the `upload-certs` phase only on the node that ran `kubeadm init`, so with the node address on a second interface no new control plane node can join after that node is gone.
- **Operations on a node.** A pod has no kube-vip, so the kube-vip guard does nothing. Until the health gate exists, an operation that stops etcd or the API server on a node does not move client connections away first. In the lab, 6 of 593 calls to the endpoint failed during a forced certificate renewal.
- **Rollout.** A rollout puts its surge node in the failure domain of the node that it replaces. When that host node has no room, the surge node waits with no end until the capacity signal exists, and an upgrade in the lab waited 1006 s until an operator made room.

The decision gives up the following:

- The control plane fails with its host cluster. Nothing moves a pod after the loss of a host node.
- Each control plane node carries a node userspace, a kubelet and a second container runtime, which a hosted control plane with no kubelet does not need.
- The tests exist only in the lab above. No test ran in CI, on a site, on arm64, or with this address design on a machine with no nested virtualization.
- A cluster has one provider, so the decision does not solve workers on bare metal in the same cluster. The lab tested one worker that is also a pod.

## Options considered

- **A node as a Kata pod, through a new infrastructure provider (chosen):** keeps the node agent and the workflows, and adds no virtual machine operator to the host cluster.
- **Full virtual machines on the host cluster:** keeps the lifecycle too, but adds a virtual machine operator with its own API and controllers to the host cluster.
- **A hosted control plane with no kubelet:** has the smallest guest, but needs new agent code for the RPCs that act on static pods and gives NVKE a second lifecycle.
- **The provisioned provider with pods that exist before the request:** made a cluster in the lab with no change to NVKE, but NVKE cannot delete that cluster, replace a node or roll out.
- **A LoadBalancer address for each pod as the node address:** needs no secondary network and no kernel build, but pod traffic between the control plane nodes failed in 6 of 6 directions and etcd needed two special settings.
- **A readiness gate that the provider sets when the controller asks:** needs a new contract between the controller and each provider, and does not cover the withdrawals that the agent starts by itself.
