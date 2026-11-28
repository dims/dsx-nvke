# Phase 3 results: a control plane in pods with workers on the mock NICo

State on 2026-11-27 at 22:06: pass rules 1 to 7 of `phase3-design.md` have a result in the lab, and 1 to 6 pass. The fix of the simulator passes its lab run with 8 of 8 worker starts. The Konnectivity prototype in the lab passes its four pass rules, and the decision of pass rule 7 is in section 4.

Design: `phase3-design.md`. Lab result with the numbers and the evidence: `lab/phase3-run/result.md` and `lab/phase3-run/result-AB.md`. Source readings: `results/phase3-source-reading-nvke.md` and `results/phase3-source-reading-nico-sim.md`. All tests ran on the second machine with nested virtualization. "Deduction" marks what no test has shown.

## Answer

Yes, in the lab and with the mock. One request to NVKE makes a cluster whose three control plane nodes are Kata pods and whose workers are machines that the NICo provider for Cluster API makes through the mock NICo. NVKE needed no new code for it. Pod traffic passes between the two kinds of node, each API server reaches each worker with no proxy, NVKE adds, removes and reboots a worker, the control plane flows of phase 2 pass with the workers present, and a delete leaves nothing.

The mock stands in for bare metal GPU machines. Section 8 says what it cannot show. The request form of the lab is the `infra` path, which is not the product path for a NICo pool (section 7).

## 1. Pass rules

| Pass rule | Result | Evidence |
|---|---|---|
| 1. One request makes the cluster: provisioned, three Ready control plane nodes as pods, two Ready workers from the mock | Pass. Five good nodes 5 min 22 s after the POST | `lab/phase3-run/result-AB.md` |
| 2. Pod traffic in each direction, and name lookup | Pass. 20 of 20 lines, name lookup on 5 of 5 nodes | The same |
| 3. Each of the three API servers reaches each worker: logs, exec, port forward | Pass. 18 of 18 checks | The same |
| 4. NVKE adds a worker and removes a worker, and the container of a removed worker is gone | Pass. A new worker is a good node after 57 s. After a node delete nothing of the worker is left, two times. With the pool count unchanged NVKE refills by itself in 68 s | `lab/phase3-run/result.md` |
| 5. With the workers present, a rollout of the control plane and a forced certificate renewal pass | Pass. Rollout: 695 s, 701 of 701 calls with 200. Renewal: 10 min 16 s, 627 of 627. No worker left Ready, and the kubelets of the workers had no lease error | The same |
| 6. A delete of the cluster leaves nothing | Pass. The row is gone after 57.8 s. No pod, claim, Machine, object of either provider, instance of the mock, worker container or SPIRE entry | The same |
| 7. The Konnectivity decision is written | Done. Not needed for the design of phase 3, and not enough by itself for workers that the control plane cannot reach. A lab prototype shows what it repairs and what stays broken | Section 4, `lab/phase3-konn/result.md` |

The reboot of a worker through NVKE, which the design named as a try:

- With the controller as it is, NVKE runs its soft reboot. The agent reboots inside the container, and Docker starts the container again. The mock keeps one boot ID for the life of a container, so NVKE waits for a new boot ID and makes no call to the provider. The same wait is finding 10 of phase 2 for a pod.
- With `NODE_REBOOT_SOFT_REBOOT_ENABLED=false`, NVKE sets the reboot annotation on the Machine, the NICo provider calls the mock, and the mock restarts the container with a new boot ID. The workflow completes in 60.6 s, and the node keeps its address.

## 2. The form that the lab tested

One request on the `infra` path:

| Part of the request | Value |
|---|---|
| The infrastructure cluster | A `PodVMCluster` |
| The control plane template | A `PodVMMachineTemplate` |
| The worker pool template | A `NicoMachineTemplate` with `spec.template.spec.siteID` and the IDs of the catalog of the mock |
| The endpoint | `controlPlaneEndpoint`, the shared address of phase 2 |

What each part did:

- NVKE accepted the request with HTTP 201 in each run. It makes the Machine and the `NicoMachine` of a worker directly. It makes no `MachineDeployment`, no `NicoMachineTemplate` object and no `NicoCluster`, and no step asks for one.
- The NICo provider (v0.3.0-rc.1, the version that NVKE deploys, public image) makes the instance for a `NicoMachine` with `siteID` under a `PodVMCluster` 4 to 6 s after the POST. It sets the provider ID of the Node by itself. The NICo controllers of NVKE stay off.
- The mock (`controller/nico-sim`, container form) runs as one container with the Docker socket of the machine. It starts a worker as a privileged Docker container beside the kind nodes, 7 s after the POST.
- A worker has two networks: the node network of the pods for its node address and the Geneve tunnels, and the network of the kind nodes for the shared API address and SPIRE. A small lab program for the Docker command of the mock adds the second network, gives each worker fixed addresses outside the range of the pod provider, and gives the interfaces fixed names. The mock itself has no change for it.
- Both kinds of node get their identity with a join token.
- The lab build of NVKE is the one of phase 2: the controller with `controlPlaneEndpoint` and the capacity signal, and the agent with the two fixes and the health gate.

## 3. Times on the second machine

| What | Time |
|---|---|
| Five good nodes after the POST (three pods, two mock workers) | 5 min 22 s |
| Four good nodes after the POST (three pods, one mock worker, one network) | 5 min 9 s |
| One more worker, from the PATCH to a good node | 57 s |
| Refill after a node delete | 68 s to six good nodes |
| Node delete with no refill | 14 s |
| Control plane rollout with two workers | 695 s |
| Forced certificate renewal with two workers | 10 min 16 s |
| Reboot of a worker with the soft reboot off | 60.6 s |
| Delete of the cluster | 46 to 58 s |

The last cluster of the run took 17 min 6 s, because the disk of the machine was slow for about half an hour (finding 13). That number says nothing about the design.

## 4. Facts for the Konnectivity decision

The lab cluster has no Konnectivity. Each connection is direct:

| From | To | What the lab saw |
|---|---|---|
| An API server in a pod | The kubelet of a worker, port 10250 | From the node address of the control plane node to the node address of the worker. No address is replaced |
| An API server in a pod | A pod on a worker (pod proxy, Service proxy) | Through the Geneve tunnel between the two node addresses. 12 of 12 calls |
| The kubelet and OVN of a worker | The API servers | From the second address of the worker to the shared address |
| The NVKE controller | The node agent of each node, port 15005 | It works. The lab did not record the source address |

- With two networks the kubelet of a worker sees the real node address of the control plane node as the caller. With one network it sees the address of a kind host node, so the call still arrives, through the host.
- NVKE has no code, no setting and no doc for Konnectivity.
- So a routed network with no address translation between the node addresses of the control plane pods and of the workers needs no Konnectivity. This is now a lab fact for logs, exec, port forward, pod proxy and Service proxy.
- A worker that the control plane pods cannot reach on its node address is the case for Konnectivity. Davanum chose a prototype for it in the lab alone, with no NVKE code (`phase3-konnectivity-design.md`).

### The prototype

The form: the request carries the API server flag `--egress-selector-config-file` and the config file, the proxy server runs on each control plane node, an agent runs on the nodes, and the lab Service of the shared address has one more port. The images are the upstream ones at v0.34.0, the version that Kubernetes 1.36.4 names. A NetworkPolicy in the host cluster makes the workers unreachable from the control plane pods (0 of 6 connections with it, 6 of 6 without it), and the NVKE controller keeps its path to the node agents.

| Pass rule of the prototype | Result |
|---|---|
| 1. With the policy and no proxy, logs, exec and port forward to a pod on a worker fail | Pass. 18 of 18 calls fail through the three API servers, with a timeout on the kubelet port. NVKE still shows five good nodes |
| 2. With the proxy, the same calls pass through each API server | Pass. 18 of 18. The kubelet of each worker sees only its own node address as the caller. Each worker agent has three tunnels through the one shared address |
| 3. A control plane node that NVKE replaces uses the proxy | Pass, with a fourth node and with a replaced first node. 24 of 24 calls. The two nodes that stayed had 119 of 119 good calls each |
| 4. The list of what still fails | 27 lines, each as the design expects. Pod traffic between a worker and the control plane nodes fails in both directions, the API Service and name lookup fail from a pod on a worker, and NVKE shows five good nodes |

What the prototype found:

- **A static pod from the request does not stay.** The NVKE controller runs `kubeadm reset` before each control plane join (`cleanBeforeControlPlaneRejoin`, `controller/internal/temporal/workflows/provision_node.go`), and the reset empties the manifest folder. Only the first node kept its proxy server, and 12 of 18 calls failed through the two joined nodes with a missing socket. The request has no command hook after the join. The lab then ran the proxy server as a DaemonSet on the control plane nodes, which it applied after the cluster was up.
- **An API server with the flag and no proxy server reports ready.** `/readyz` is 200, so the shared address sends calls to it. A new control plane node was in that state for 38 to 50 s, and a `logs` call through it failed in that time.
- **The agents find a new proxy server by themselves**, and the shared address spreads their tunnels over the proxy servers.
- **A call to a pod address goes to any agent.** With agents on each node, a call of an API server to a pod on a worker passed 14 of 48 times, because an agent on a control plane node cannot reach that pod. With agents on the workers only, those calls passed 72 of 72 times, and each call for a control plane node failed.

### The decision

- **Phase 3 needs no Konnectivity.** In the tested form each control plane pod is a full node of the cluster, so the pod network already needs a routed path with no address translation between the control plane nodes and the workers. With that path the API server reaches the workers directly.
- **Konnectivity is not enough for workers that the control plane cannot reach.** It carries the calls of the API server to a kubelet. The pod network, the API Service for pods and name lookup stay broken, and a call to a pod works only as far as the pod network of the agent's node reaches.
- **It becomes a real need in phase 4**, where the pod has no kubelet and the control plane is not a node of the cluster. For that, NVKE has to install the proxy server after the join or as a pod of the cluster, has to hold a new API server out of the shared address until its proxy server has agents, and has to keep the flag in the `kubeadm-config` ConfigMap through each flow that rewrites it.

## 5. Findings

For NVKE, the NICo provider and the mock:

1. **NVKE accepts one cluster with machines of two infrastructure kinds on the `infra` path, with no new code.** The check on that path is only the API group of each template.
2. **The NICo provider needs no `NicoCluster` for a machine with `siteID`,** and it sets the provider ID of the Node by itself. The NICo controllers of NVKE are not needed for a machine with a join token.
3. **The mock loses a race with systemd at the start of a container machine.** It runs the simulated cloud-init commands right after `docker start`. NVKE adds a `systemctl restart` as the last command, and it fails when systemd has no control socket yet. The status then stays `error`, and `NodePreflight` of NVKE fails with no end. The lab lost the race in 3 of 4 worker starts at first, and saw the socket absent at the first look in 3 of 7 later starts. CI has the same race by the source, and why it passes there was not measured. The lab went past it with a wait in its own request. The fix is on the branch `fix/nico-sim-wait-for-systemd` (`results/phase3-nico-sim-race-fix.md`). It passes its lab run: with the fixed simulator and with no wait in the request, 8 of 8 worker starts joined at the first attempt with the status `done`. In 2 of the 8 starts systemd made its socket after the simulator was ready to run the commands, and the simulator waited 165 ms. With the old simulator those two starts had the conditions of the fault.
4. **A container node can touch the devices of the Docker host through the node agent.** With no flag the agent runs a script at each start that removes each Mellanox PCI device through `/sys` and scans the PCI bus. The bootstrap data of NVKE replaces the agent arguments of the image, so a flag in the image arguments does not stay. The lab image forces `--disable-mlx5-rescan` with a drop-in, and the entry point of the image makes `/sys` read only. The lab machine has no Mellanox device.
5. **NVKE shows a worker as good when its pod network is broken.** With one network no tunnel packet passed between the worker and the control plane nodes, and the Node stayed Ready. It is finding 2 of phase 1 again.
6. **A reboot through NVKE needs `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` for such a node.** With the default NVKE waits for a new boot ID that a container never gives. The e2e settings of NVKE for container nodes use the same value. With it the provider first calls a power route for the machine, gets 404 from the mock, and then reboots the instance.
7. **The pool rules are those of phase 2.** A lower pool count removes no node. A node delete with the same count gives a refill.
8. **The control plane flows do not touch the workers.** The health gate of phase 2 works with workers that are not pods. No surge node met a full failure domain, because a worker of the mock holds no volume place.

From the source readings, not tested (deductions for a product):

9. **A pool on the `infra` path has none of the functions of the `nico` request object:** no release, no config profile hooks, no Teleport, no placement retries.
10. **The SPIRE attestation method is one value for a deployment.** A product needs it for each pool, because a NICo machine uses its TPM and a pod has none.
11. **The OVN gateway settings are the same for each node of a cluster.** A worker on real hardware has another bridge layout than a container node and may fail with the settings of a control plane in pods. The container form of the mock hides this.

For the lab and its machine:

12. **Docker connects two networks of a container in a random order at each start.** The lab program now names the interfaces and adds a hosts line, so the node address of a worker stays through a restart.
13. **The disk of the second machine was slow from about 00:14 to 00:56 UTC** (I/O pressure 19 to 37 percent, 47 to 126 ms for a write on a lab volume). One call to the shared address failed in that time, outside each flow, and the cluster that was made in that time took three times as long. The lab did not write more than before: the worst time had fewer requests and less data than the making of the first mixed cluster, and each request took six times as long. The storage loop, the journal, cron and a single heavy process are ruled out. Not ruled out: the virtual disk below the machine. No cause is found.
14. **A container worker makes the kernel of the Docker host load modules.** Loaded by hand, with the word of Davanum: `openvswitch`, and with it `psample`, `nf_conncount`, `nsh`. Loaded by the kernel itself: `geneve`, `nfnetlink_cttimeout`, `tls`, and nine nftables and socket match modules. None is permanent.

Side points for the repository, with no effect on a result:

15. `make license` in `controller/nico-sim` fails on main as written, and `make license` in `controller` adds a header to an unrelated test file.
16. The simulator lanes of CI build the NICo provider v0.1.0 from source, and a comment in `controller/deploy/capnico-e2e/nvke-deploy.yaml` says that its image is private. One pull with no login passed.
17. In two of five cluster creates one `JoinNode` workflow of a control plane node failed at once and passed in the run that NVKE started by itself ("failed to get etcd mirror Pod for node ... not found" in one, a failed `kubeadm join` in the other). It is the join of a control plane pod, not the worker path. The cause is not looked for.

## 6. Done after the first form of this note

- The lab run with the fixed simulator and with no wait in the request (finding 3). The mixed cluster of that run had 5 good nodes after 5 min 36 s, and each of six refills gave a good node 68 s after the node delete.
- The Konnectivity prototype in the lab and the decision (section 4).

## 7. What the lab does in the place of a product part

- **The request.** The lab uses the `infra` path with a `NicoMachineTemplate`. For a product the ways are: a provider for each node pool, a `nico` cluster whose control plane comes from the `infra` path, or the direction of the proposed record `docs/adrs/20261105-capi-architecture.md`. `phase3-design.md`, section 10, has the table.
- **The network.** Two Docker networks on one machine, and a lab program that puts a worker on both. A site needs a routed path with no address translation between the secondary network of the pods and the network of the bare metal workers, or Konnectivity.
- **The mock.** One container with the Docker socket of the machine, and workers as privileged containers on the kernel of the machine.
- **Identity.** A join token for each node.
- The lab parts of phase 2 stay: the storage, the shared endpoint, the guest kernel, the node image, the stack by hand.

## 8. Not tested

- A real NICo, real GPU machines, DPUs, a real network with BGP, the boot time of a machine, and a TPM identity. The mock has none of them.
- The virtual machine form of the mock.
- Konnectivity as a part of NVKE. The prototype is lab manifests and a request. Not tested with it: webhooks and metrics through the proxy, a guarded operation, an upgrade, and the proxy after a certificate renewal.
- An upgrade of the Kubernetes version with workers of two kinds, etcd encryption with mock workers, and a worker pool with more than three nodes.
- The reboot with the default setting to its end after 30 minutes.
- The NICo controllers of NVKE turned on, and Teleport.
- More than one run of most tests.
- arm64, CI, a QA site.

## 9. What changed on the second machine

Davanum allowed each point on 2026-11-27. `lab/phase3-run/result.md` has the removal steps.

- The kernel module `openvswitch`, loaded by hand, and the modules of finding 14 that the kernel loaded by itself. Removal: `modprobe -r`, or a restart of the machine.
- The NICo provider for Cluster API in the lab cluster.
- The simulator container with the Docker socket, and the worker containers, which have the restart policy `always`.
- The lab controller at Helm revision 3 with the soft reboot off.
- Eight old pod image archives of phase 2 are removed (15.5 GB).
- No firewall change, no change of the Docker configuration, no package.

## 10. What comes next

1. Phase 3 of the lab is done with this note. Phase 4 of the plan (a pod with no kubelet) is optional by the plan and has no word of Davanum.
3. For Davanum: the new branch `fix/nico-sim-wait-for-systemd` joins the list of pull requests that he can open. It stands alone.
4. For a product: the decision between the request forms of section 7, the attestation method for each pool, and a test with real hardware for the OVN settings.
