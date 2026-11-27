# Phase 2 results: a provider that runs NVKE control plane nodes as Kata pods

State on 2026-11-26 at 23:25: all steps of phase 2 are done. All six pass rules are met, and one worker joins a cluster of the provider. Phase 2 is complete.

Design: `phase2-design.md`. Log: `runlog.md`. All tests ran on the second test machine, where Kata runs with nested virtualization, so times do not compare with the workstation. "Deduction" marks what is not tested.

## Answer

Yes. One request to NVKE makes a cluster whose three control plane nodes are Kata pods, with no pod, no volume claim and no helper made by hand. The new provider `cluster-api-provider-podvm` makes them. NVKE can delete the cluster, replace a node and roll the control plane to a new image through its API, with no operator step.

Two of the six pass rules need a fix in the NVKE node agent. Without it no new control plane node can join after the first node of a cluster is gone or was started again.

## 1. Pass rules

| Pass rule | Result | Evidence |
|---|---|---|
| 1. One request makes the cluster: provisioned, 3 Ready control plane nodes | Met, in each of 5 cluster creates with the provider | `lab/phase2-provider-run/result.md`, `lab/phase2-agentfix-run/result.md` |
| 2. Pod traffic between the control plane nodes, the OVN pod Ready on each node | Met in each run (6 of 6 directions) | The same |
| 3. A delete through the API leaves no object and no volume claim, with no operator step | Met, 4 times. The cluster row is gone about 35 s after the DELETE | The same |
| 4. A delete of one control plane pod heals with no operator step, and the API stays reachable | Met, for a joined node and for the first node. The shared address answered each call | `lab/phase2-provider-run/result.md` |
| 5. NVKE replaces one control plane node after a node delete through the API | Met for a joined node and for the first node. The first node needs the fix of the NVKE agent | `lab/phase2-replace-run/result.md`, `lab/phase2-agentfix-run/result.md` |
| 6. A change of the machine template replaces the three nodes one after the other | Met with the fix of the NVKE agent: 489 s for three nodes, 0 failed joins | `lab/phase2-agentfix-run/result.md` |

## 1a. The worker test (step 8)

Not a pass rule, and all five tests pass (`lab/phase2-worker-run/result.md`):

| Test | Result |
|---|---|
| W1. One worker through a node pool of the NVKE API | Pass. The provider makes the pod in the worker form, NVKE joins it, and the Node is Ready 78 s after the request |
| W2. Traffic with the worker | Pass. Pod traffic in each direction between the worker and each control plane node (16 of 16 lines), name lookups from the worker, tunnels on the fixed addresses. The API server reaches a pod on the worker through each of the three API servers: logs, exec, the Service proxy and the pod proxy |
| W3. The reboot of the worker through NVKE | Pass, after 31 minutes. The provider deletes the pod one time and makes it again, and the Node has a new boot ID. 30 minutes are the wait of NVKE after its soft reboot (finding 10) |
| W4. A lost worker pod | Pass. The new pod comes 21.8 s after the delete, and the kubelet reports again after 71.6 s |
| W5. The removal of the worker | Pass for a delete of the node (18.3 s) and for a delete of the pool (30 s). A lower count of the pool removes no node (finding 11) |

The worker flow of NVKE on this path, from the source and the runs:

- A node pool request carries its own machine template. The only check is the API group.
- NVKE makes one Machine, one infra machine and one bootstrap Secret for each node. It makes no template object and no MachineDeployment.
- A worker joins inside its own provisioning workflow, with the worker join string of a joined control plane node. `KubeadmJoin` takes 10.9 s, against 30 to 51 s for a control plane node.
- A worker Machine has no failure domain, so the scheduler of the host cluster places its pod.
- The default `systemReservedMemory` of a pool is 16Gi. A pod of 6Gi needs a smaller value in the request.
- The node image for pods needs nothing different for a worker.

## 2. What phase 2 made

Three branches on `dims/dsx-nvke`, each on top of main, with no pull request:

| Branch | Content | Report |
|---|---|---|
| `feat/cluster-api-provider-podvm` | The provider module: three kinds, a cluster controller, a machine controller, 74 test functions. Five commits | `results/phase2-provider-report.md` |
| `fix/agent-upload-certs-config` | The fix of the NVKE node agent for the kubeadm upload step. One commit | `results/phase2-agent-fix.md` |
| `feat/control-plane-endpoint` | The request field `controlPlaneEndpoint`, from phase 1. Three commits | `results/phase1-endpoint-change.md` |

And in the lab folder (`lab/phase2-node-image/`): the node image for pods, as a Dockerfile on top of the container node image of NVKE.

What the provider does for each Machine:

- It takes a free address of a range in its cluster object, and derives a hardware address from it.
- It copies the bootstrap Secret of NVKE into the pod namespace and makes two block volume claims and one pod. The pod has the Kata runtime class, a second interface with the fixed address, a startup probe on the port of the node agent, and a readiness probe on the API server.
- It reports the address to NVKE only when the node agent answers. So the preflight step of NVKE passes at its first attempt.
- It makes a lost pod again with the same name, claims and address.
- It publishes one failure domain for each zone or host node, and puts each pod on the host node of the failure domain that NVKE chose.
- At a delete it removes the pod, the claims and the Secret copy, and then its finalizer.

What the node image for pods adds to the container node image:

- An entry point that mounts the two volumes and starts systemd, with no wrapper script from outside.
- A small program with two units that applies the bootstrap data of NVKE: the files before the SPIRE agent, the commands when the system is up.
- An Open vSwitch unit that accepts a datapath that is built into the kernel.
- A correct machine ID, and the CNI images in the containerd store at build time.

## 3. Times on the second machine

Seconds after the cluster request, three nodes at one time.

| Run | Pods made by | Provisioned | Three Ready nodes | Preflight step of NVKE |
|---|---|---|---|---|
| Phase 1, block D | A script, before the request | 176.9 | 281.9 | 30.1, 2 attempts |
| Step 3, test T4 | A script, after NVKE names the node | 239.5 | 378.6 | 100 to 222, 3 or 4 attempts |
| Step 4, the provider, first node image | The provider | 252.4 to 253.7 | 358.6 to 375.0 | 0.1, 1 attempt |
| Step 6, the provider, node image with the CNI images at build time | The provider | 208.4 | 348.8 | 0.1, 1 attempt |

- With a provider the start time of a node is inside the time of NVKE, because the pod can start only after NVKE names the node. That is the difference to block D.
- The startup probe moved that wait from the preflight step (retry after 30, 60 and 120 s) to the step that polls each 10 s at most.
- One node replace takes about 180 to 190 s from the DELETE to a good node. A rollout of three nodes takes 489 s.
- A lost pod is back with its API server ready after 50 to 52 s with the second node image (85 to 91 s with the first).

## 4. Findings for NVKE

New in phase 2. The findings of phase 1 are in `results/phase1-results.md`, section 5.

1. **No new control plane node can join after the first node is gone or was started again**, when the node address is not on the default route interface. The node agent ran the kubeadm upload step with a config only on the first node. Since kubeadm 1.33.12, 1.34.8, 1.35.5 and 1.36.1 that step talks to the local API endpoint, and with no config kubeadm takes the address of the default route interface. Corrected on the branch `fix/agent-upload-certs-config`, and proven in four cases in a cluster.
2. **NVKE refuses the delete of a control plane node when only two joined nodes would remain.** It is by design. A replace of a node in a cluster with three nodes needs the desired count 4 first.
3. **NVKE refuses a reboot request for a control plane node.** It is by design. The reboot answer of the provider can be tested only with a worker.
4. **The controller keeps the join strings of a cluster for 5 minutes.** A test of a join must wait for that time, or it proves nothing about the node that NVKE asks.
5. **Each node of the container node image has the same machine ID.** The image carries a D-Bus machine ID file. The node image for pods corrects it.
6. **One unit of the container node image installs a 330 MB package and imports its images at each start**, before both agent units. It cost 34 to 57 s of each node start.
7. **During the planned shutdown of a control plane node its API server answers 500 on `/readyz` while its pod is still behind the shared address**, for up to 6 s. 2 to 6 calls of several hundred got that answer in each replace. A provider that takes the pod out of the Service at the start of the delete would remove it.
8. **After a new pod, NVKE shows `nodeAgentReady` as not True for 140 to 180 s**, while the agent answers after about 80 s. The wait is on the side of the controller (deduction).
9. **A rollout puts two control plane pods of one cluster on one host node** for about 2.5 minutes for each node, because the surge node takes the failure domain of the node it replaces.
10. **A reboot request costs 30 minutes and two node restarts with the default settings.** NVKE tries a soft reboot first. In a pod with a VM that is a restart of the container in place: the VM and its kernel stay, so the boot ID does not change. NVKE waits its limit of 30 minutes and then asks the provider. NVKE has a setting for such a backend: `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` (`controller/internal/config/config.go:232-237`). A deployment with this provider needs it. Not tested with the setting.
11. **A lower count of a node pool removes no node.** The PATCH gives 200 and NVKE tears nothing down, by design (`controller/internal/controllers/nodeset/controller.go:148-158`). The caller deletes the node or the pool.
12. **A new pod gives a node a new Open vSwitch system ID**, because the ID file is in `/etc` and not on the volume. The node then has a new OVN chassis ID, and the old chassis row stays in its own database for some minutes. Traffic passed in that time. The node image can keep the file on the volume.
13. **The journal of the guest is in memory.** After a restart in place or a new pod the earlier lines of the agent are gone.

## 5. What the lab still does in the place of a product part

- **Storage.** The lab has a storage class with local block volumes that a script makes again after each delete. A site needs a storage driver that gives a new block volume to each new claim.
- **The shared endpoint.** The caller makes the LoadBalancer Service and the pod namespace before the request.
- **The network.** A second Docker network and a Linux bridge in each host node, with Multus and a static address plugin. A site needs a secondary network on the node network, with the address and the hardware address from the pod spec.
- **The guest kernel.** A Kata kernel with 8 added options, built by hand and installed as its own handler.
- **The node image.** Built in the lab folder, on top of an image under `controller/hack/`. The repository has no place for it yet.
- **The NVKE stack.** Installed by hand with the rights for the three kinds in a manifest outside the chart. NVKE uses the provider through the `infra` path, which the docs do not name as a product path.

## 6. Not tested

- A cluster with its workers on bare metal. A worker as a pod of the provider is tested.
- The reboot with the soft reboot of NVKE turned off.
- A control plane rollout while a worker holds the second volume place of a host node, and more than two workers.
- A worker with no etcd volume. The provider and the image both need the volume today.
- The loss of a host node with the provider, and a move of a pod to another host node with a real network volume.
- A Kubernetes version change. Only the image changed in the rollout.
- Two clusters of the provider at one time, and the rule against overlapping address ranges in a cluster.
- A pod that cannot be scheduled, a startup probe that does not pass in 20 minutes, a restart of the provider during a flow, a delete during provisioning.
- The workstation, and a machine with no nested virtualization.
- arm64. The arm machine of the lab has no KVM, so Kata cannot run there. Davanum decided on 2026-11-26: no arm64 now.
- A real site: a production CNI for the secondary network, a real load balancer, a storage driver.

## 7. What comes after phase 2

For Davanum:

1. Sign the commits and open the pull requests: the fix of the NVKE agent (it stands alone and corrects a fault of NVKE with recent kubeadm), the `controlPlaneEndpoint` field, and the provider. The Kata fix of phase 0 is its own pull request upstream.
2. The six points for the review of the agent fix (`results/phase2-agent-fix.md`, section 3).

For a product form of the provider (not planned and not estimated yet):

1. The first class integration into NVKE: a request object, a provider client, the chart rules, docs. `results/phase2-provider-report.md`, section 8, lists what a pull request for the module itself needs.
2. A place in the repository for the node image for pods, and the guest kernel as a release part.
3. What reacts to the loss of a host node, together with the volume kind.
4. Workers on bare metal in the same cluster: one cluster has exactly one provider today.
5. The smaller provider points from the tests: take the pod out of the shared Service at the start of a delete, a shorter time limit for the look at the Node of the new cluster, tolerations and a node selector, an etcd volume only for control plane machines (the provider API and the entry point of the image both need it today).
6. The smaller image points: the Open vSwitch system ID on the volume, and a place for the journal that stays through a new pod.
7. The setting `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` in a deployment with this provider.
