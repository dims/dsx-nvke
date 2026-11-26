# Phase 1 results: NVKE makes a cluster with its control plane on Kata pods

State on 2026-11-26 at 14:13: all steps of phase 1 are done. Phase 1 is complete.

Design: `phase1-design.md`. Log: `runlog.md`. "Deduction" marks what is not tested.

## Answer

Yes. NVKE makes a cluster with three control plane nodes on three Kata pods, with code that exists. The pass rule of phase 1 is met in 3 of 3 runs from empty volumes: NVKE reports the cluster as provisioned, and `kubectl get nodes` shows 3 Ready control plane nodes.

Phase 1 also found three things that the design note did not have:

- Pod traffic between two control plane pods does not work when each pod has a LoadBalancer address as its node address. A second address design removes the fault: a fixed address with no NAT for each pod. NVKE made a cluster on that design in 2 of 2 runs, with pod traffic in 6 of 6 directions. Both designs are in this note. Davanum decides between them in phase 2.
- The shared LoadBalancer address as the cluster endpoint needs an NVKE change. The change is written, checked and tested in the lab: a new optional request field `controlPlaneEndpoint`.
- NVKE cannot delete such a cluster through its API alone, because the provider for hosts that exist never releases a host.

## 1. Steps

| Step | Result | Report |
|---|---|---|
| 1. OVN-Kubernetes with the userspace datapath of Open vSwitch in one Kata pod | Pass, 4 of 4 runs | `lab/phase1-cni/report.md` |
| 2. The etcd settings from a kubeadm patch file | Pass, 3 of 3 runs | `lab/gate4/report-etcd-patch.md` |
| 3. The NVKE stack in the lab cluster | Pass, 67 of 67 checks | `lab/phase1-stack/report.md` |
| 4. The helper that copies the bootstrap data of NVKE into a pod | Pass | `lab/phase1-helper/report.md` |
| 1c. Dry run of the full flow with three nodes, with a lab client as the controller | Pass, 2 of 2 full runs. Pod traffic between nodes fails | `lab/phase1-dry/report.md` |
| 5. The cluster through the NVKE controller | Pass, 3 of 3 runs from empty volumes | `lab/phase1-run/report.md` |
| 6. Pod traffic between the control plane pods | Fails with a LoadBalancer address for each pod (0 of 6 directions). Passes with a fixed address and a guest kernel that has Open vSwitch (6 of 6): 2 runs with the lab client and 2 runs with the real NVKE controller, on the second machine | `lab/phase1-fixed-address/result-C1.md` to `result-D.md`, `lab/phase1-second-machine/report.md` |
| 7. The shared LoadBalancer address as the endpoint | Pass, 2 of 2 runs, with the new request field | `results/phase1-endpoint-plan.md`, `results/phase1-endpoint-change.md`, `lab/phase1-endpoint-run/report.md` |

## 2. What the runs through NVKE show

Step 5, with the address of the first node as the endpoint:

- NVKE reports "provisioned" 156.2 s, 338.3 s and 154.3 s after the request. The second run was slow from two faults of the run script.
- The create path needed no NVKE code change and no new image. It needed deployment settings only: the `infra` provider path, the join token attestation, the CNI install after init, and the development setting `allowControlPlaneWithoutVIP`.
- NVKE made the SPIRE entry and the join token for each node. Each SPIRE agent in a Kata guest attested on the first try, and the agent answered NVKE over mTLS with the correct ID.
- NVKE approved the kubelet serving certificate requests in 0 to 2 s.
- About 120 of the 156 s are fixed retry waits of NVKE and not work.

Step 7, with the shared LoadBalancer address as the endpoint:

- NVKE reports "provisioned" 157.4 s and 158.0 s after the request. The step times are equal to step 5.
- kubeadm, the API server certificates, the kubeconfig Secrets of NVKE and the join commands use the shared address. No kube-vip runs.
- In a replace of the first node pod the shared address answered 364 of 364 calls. With the first node as the endpoint the API was down for about 31 s in the same test.
- NVKE kept the cluster provisioned during the replace and started no workflow.

Block D on the second machine, with a fixed address for each pod, the kernel datapath and the shared address as the endpoint:

- NVKE reports "provisioned" 176.9 s after the request in both runs, and three Ready nodes after 296.0 s and 281.9 s. That machine runs Kata with nested virtualization, so the times do not compare with the workstation.
- Pod to pod traffic works in 6 of 6 directions, a name lookup works from each node, and the OVN pod is Ready on each node.
- etcd runs with the kubeadm default flags and rejects 0 peer connections.
- In a replace of the first node pod the shared address answered 366 of 366 calls, NVKE kept the cluster provisioned, and pod traffic worked again in 6 of 6 directions.
- No NVKE step failed by a timeout on the slow machine.

## 3. The NVKE change of phase 1

One change, on the branch `feat/control-plane-endpoint` of `dims/dsx-nvke` (three commits on top of main, no pull request):

- A new optional field `controlPlaneEndpoint` in the cluster create request, as `host` or `host:port`.
- NVKE gives the value to kubeadm as the endpoint and configures no kube-vip.
- A cluster with the field counts as a cluster with a stable endpoint at each gate that needs a VIP today.
- All checks of the repository pass. The API compatibility check reports 14 additive changes and 0 breaking.
- The lab tested the create gate, the storage with its migration on PostgreSQL, the `kubeadm init` path, the response and the update rule. It did not test the gates for scale, upgrade, rollout, node delete and remediation with a real cluster. They have unit tests.

Still necessary for a complete product change: nvkectl, an e2e test, management-engine, a decision on the kube-vip drain guard of the agent, and a metric label (`results/phase1-endpoint-change.md`, section 6).

## 4. The two address designs

Decision of Davanum on 2026-11-26: the notes keep both designs with their costs. The choice comes in phase 2.

| Point | Design A: a LoadBalancer address for each pod | Design B: a fixed address with no NAT for each pod |
|---|---|---|
| Node address | The address of a LoadBalancer Service of the host cluster, one for each pod. The guest holds it on a Linux bridge with no ports | An address on a second interface of the pod, on a node network. The address and the hardware address are in the pod spec |
| After a pod replace | The same address. The pod IP is new | The same address and the same hardware address. A peer reaches the pod again 5 to 7.5 s after the delete |
| etcd | Needs a listen on all addresses and `peer-skip-client-san-verification`, from a kubeadm patch file in the pod | The kubeadm defaults. 0 rejected peer connections |
| Open vSwitch datapath | Userspace datapath, with a datapath override for the agent and `/dev/net/tun` | Kernel datapath, the stock mode of the node image |
| Guest kernel | The stock Kata kernel | The Kata kernel with one config fragment of 8 options (Open vSwitch, Geneve), as its own Kata handler |
| Pod traffic between two control plane nodes | Fails, 0 of 6 directions. Two causes: the userspace datapath cannot send a tunnel packet through `eth0`, and the tunnel addresses do not match after the Service | Works, 6 of 6 directions. The OVN pod is Ready on each node, and DNS works from each node |
| What NVKE reports | Provisioned, with 3 Ready nodes. NVKE does not see the pod traffic fault | Provisioned, with 3 Ready nodes |
| Shared endpoint | A LoadBalancer Service for port 6443, with `controlPlaneEndpoint`. Tested with NVKE | The same form. Tested with NVKE |
| What a site must carry | A LoadBalancer implementation in the host cluster, with an address pool for the pods. If the etcd peer check must stay on (the DNS name option of gate 4), the Services also need `externalTrafficPolicy: Local` | A node network that reaches each pod host, and a CNI in the host cluster that gives a pod a second interface on it with an address and a hardware address from the pod spec. The guest kernel build for each Kata release |
| Tested with the real NVKE controller | Yes, steps 5 and 7: 5 of 5 runs on the workstation | Yes, block D: 2 of 2 runs on the second machine, with nested virtualization |
| Tested across host nodes | Yes, on the second machine with kubeadm by hand: 3 of 3 full runs, node loss tests | Yes, on the second machine: pod moves and a host node loss |
| Lab changes to the node image | Two systemd drop-ins for Open vSwitch, the datapath override, the etcd patch file, the address bridge | One systemd drop-in: the `modprobe` step of `ovs-vswitchd.service` must accept a built in datapath |

Notes on the table:

- Design A is complete only for a control plane whose nodes need no pod network to other nodes. The API server reaches webhooks and aggregated APIs on workers through the pod network, so a cluster with workers needs working tunnels (deduction: not tested, phase 1 has no worker).
- In design A the fault has two causes, and each one alone is enough. A guest kernel with Open vSwitch removes only the first one.
- In design B the address plugin of the lab has no check for two pods with one address.
- In design B a pod can move to another host node with the same address. The volume must be able to move too. Local volumes pin a pod to one host node in both designs.
- After the loss of a host node nothing moves a pod by itself in either design. With one operator step (the out-of-service taint) the pod runs on another node after 20 s and etcd has three healthy members after 30 s (design B, on the second machine, with a volume that the lab only imitates).

## 5. Findings for NVKE

From the runs, with the report that has the evidence:

1. **No delete path.** A cluster on the `infra` path with the provisioned provider cannot be deleted through the API alone. The provider refuses the delete of a bound machine, host claims are permanent, and the teardown workflow of NVKE waits with no end. The lab uses two operator steps on Kubernetes objects after the API delete. A pod provider of phase 2 must have a delete path (`lab/phase1-run/report.md`, section 7).
2. **A race at the join of the third node.** The etcd quota check before a join reads the etcd mirror pod of each joined node. A node that joined 1.3 s before has no mirror pod yet. It hit 2 of 7 runs with the real controller, and the workflow retry passed each time (`lab/phase1-run/report.md`, section 5).
3. **Fixed waits.** About 120 of 156 s to "provisioned" are retry waits: a 30 s requeue, a 30 s preflight retry and a 60 s DNS retry. The preflight retry comes from the bootstrap data: NVKE calls the agent 1 to 2 s after the bind, and the helper needs up to 5 s. A provider that gives the data at pod start removes it.
4. **NVKE reports a cluster as provisioned when its pod network between nodes does not work.** No step checks the OVN pods or traffic between nodes (`lab/phase1-dry/report.md`, section 6).
5. **The Open vSwitch step can report "configured" for a bridge that Open vSwitch could not make.** `ovs-vsctl` returns 0 when the database change is done (`lab/phase1-cni/report.md`, section 4).
6. **The datapath type is an environment setting of the agent.** NVKE has no API field and no node kind for it. The node image sets `system`.
7. **`ovs-vswitchd.service` of the node image fails with a built in datapath**, because its `modprobe` step finds no module folder.
8. **The node image has `pause:3.10`, and kubeadm v1.36.4 pulls `pause:3.10.2` in its preflight.** A node with no registry access stops there (`lab/phase1-fixed-address/result-C3.md`).
9. **The kube-vip drain guard of the agent reads each /32 on `lo` as the VIP.** A site must not put a load balancer address there (`results/phase1-endpoint-change.md`, section 5).
10. **A node is "provisioned" in NVKE before its kubelet is Ready.**
11. Deductions from the source, not tested: after a restart of the first node the file `/tmp/kubeadm-init-config.yaml` is gone and `kubeadm init phase upload-certs` runs with no config file. The agent sets `registerNode` false, so a deleted Node object does not return by itself.
12. A fault of main, not of the lab: `make license` adds a header to `controller/test/e2e/internal/oidc/testdata/auth-config.yaml`.

## 6. What the lab adds to a pod so that NVKE can use it

These are lab parts. A pod provider of phase 2 replaces them.

- **The bootstrap helper.** It reads the bootstrap data Secret of a bound `ProvisionedMachine` and writes its files into the pod through `pods/exec`. It wrote the data 3.4 to 5.1 s after the bind in the clean runs.
- **The wrapper of the pod.** It mounts the volumes, keeps `/etc/spire-agent` on the `/var` volume, writes the kernel config file for the kubeadm system check, and sets the address form of the design.
- **A readiness probe** on `/readyz` of the API server, so the shared Service forwards only to a pod with a working API server.
- **The inventory.** The request names three hosts with their addresses in a `ProvisionedCluster` object, and each pod has a label with its host name.
- **The delete procedure** of finding 1.

## 7. Not tested in phase 1

- A worker node, and traffic between a control plane pod and a worker.
- An upgrade of Kubernetes through NVKE, a certificate renewal, a node replace or a remediation through NVKE, and a scale of the control plane.
- A real network volume and its fencing.
- A real load balancer with its own health check in front of the API servers, and a DNS name as the endpoint.
- The throughput and the CPU cost of the datapath under load.
- Two host nodes down at one time with NVKE, and a cold start of the whole host cluster with NVKE in it.
- Design B on the workstation, and design B with no nested virtualization.
- The userspace datapath together with a fixed address.
- IPv6.

## 8. What phase 2 must decide and build

1. The address design (section 4).
2. A provider for pods in place of the provider for hosts that exist. It makes the pod and its volumes, gives the bootstrap data at pod start, has a delete path, and can replace a pod.
3. What NVKE does when a host node is lost: who sets the trigger, and what fences the volume.
4. The NVKE changes that the chosen design needs. For design A: the etcd arguments in the renderer and a datapath choice for a node kind. For design B: the node image unit for a built in datapath, and the guest kernel as a release part.
5. The `controlPlaneEndpoint` change as a pull request, with nvkectl and an e2e test.
6. A check in NVKE for the pod network between nodes before "provisioned" (finding 4).

## 9. Where the material is

- Lab folder on the fork: https://github.com/dims/dsx-nvke/tree/test/kata-control-plane-lab/hack/kata-control-plane-lab
- The NVKE change: https://github.com/dims/dsx-nvke/tree/feat/control-plane-endpoint
- The Kata fix of phase 0: https://github.com/dims/kata-containers/tree/lab/agent-kill-child-cgroups
- Work files: `/scratch/kata-cp/work/`. Logs: `/scratch/kata-cp/logs/`. Secrets stay there, in folders with mode 700.
