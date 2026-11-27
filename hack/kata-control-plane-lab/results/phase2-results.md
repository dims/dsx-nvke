# Phase 2 results: a provider that runs NVKE control plane nodes as Kata pods

State on 2026-11-27 at 15:29: all steps of phase 2 are done, and the flows of the plan's exit gate that the lab can run all pass. Two gaps of the design came out of them (findings 14 and 15). Both now have code on branches, and their seven pass rules pass in the lab (section 1c). The tests of the gaps found one more defect of NVKE (finding 17). Its fix is on a branch and passes its lab test (section 1d).

Design: `phase2-design.md`. Log: `runlog.md`. All tests ran on the second test machine, where Kata runs with nested virtualization, so times do not compare with the workstation. "Deduction" marks what is not tested.

## Scope of "complete"

Phase 2 is complete by the six pass rules of `phase2-design.md`, which Davanum accepted. The plan (`nvke-control-planes-as-kata-pods.md`) names a larger exit gate for this phase: "Rollout, repair, renewal, key rotation and upgrade pass in CI with Kata, then in DS9 QA". The lab tested all five flows on the second machine (section 1b). They did not run in CI and not on a QA site. The NVKE controller and the node agent have no etcd backup and restore at this commit (section 1b), so that part of the plan's phase 2 work is not started.

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

## 1b. The flows of the plan's exit gate

"Rollout, repair, renewal, key rotation and upgrade", each on a cluster of the provider with three control plane nodes and one worker (`lab/phase2-gate-run/result.md`). All 36 workflows of these tests completed.

| Flow | Result | How it starts in NVKE |
|---|---|---|
| Rollout | Pass (pass rule 6): 489 s for three nodes | A PATCH of the machine template |
| Repair | Pass (pass rule 5): about 190 s for one node | A DELETE of the node. It needs the desired count 4 first in a cluster with three nodes |
| etcd encryption | Pass: 5 min 40 s. An old Secret is readable, a new one is stored encrypted | A PATCH with `enableEtcdEncryption: true` |
| Key rotation | Pass: 5 min 38 s, no static pod restart, 357 of 357 calls to the shared address with 200 | An operator workflow in Temporal, with the command of the docs page. No API request |
| Certificate renewal (forced) | Pass by its pass rules: 9 min 49 s, each certificate has a later end date. One finding (14) | An operator workflow in Temporal, with the command of the docs page. The schedule of NVKE renews only a certificate in its last 30 days |
| Upgrade 1.35.5 to 1.36.4 | Pass at the end, with one stop (finding 15): each control plane node runs v1.36.4, the add-on step completes in 1 min 54 s. About 630 s without the stop | A PATCH with the version and the machine template in one request |

- The kube-vip guard of NVKE runs in the encryption, the rotation and the renewal. The agent answers that kube-vip is not configured, and skips.
- The provider sees no change of its pods in the encryption, the rotation and the renewal, and logs 0 error lines.
- A node with v1.36.4 joined the cluster with v1.35.5 with no problem, and the workers with v1.35.5 stayed Ready during the upgrade.
- The control plane upgrade does not touch a worker pool. A PATCH of the pool with the version, the template, `recycleBudget` 1 and `maxSurge` 1 makes one new worker. NVKE does not remove the old worker by itself.
- The second node image for the upgrade is the pod image with the Kubernetes programs and images of the kind node image `v1.35.5`. It was built in 20 s. A full build of the base node image was not necessary.
- etcd backup and restore: the NVKE controller and the node agent have no API request, no workflow and no code for it at this commit. `docs/overview/preview-status.md:26` says "No backup or restore procedure" for the management cluster.
  - Correction of 2026-11-27, 10:45: the earlier text said only "NVKE has no API request and no code". It left out a bundle. `docs/concepts.md:108` names `etcd-manager` "for compaction and snapshots", and the sample bundle index of the agent lists a bundle with that name (`agent/samples/index.json`, `agent/samples/collection-example.json`). The source of the bundle is not in the repository. The lab did not install it and did not test it. So the lab cannot say what that bundle does for a backup.

## 1c. The two gaps: a health gate and a capacity signal

Davanum chose on 2026-11-27 to build the two gaps of findings 14 and 15. The design is `phase2-gaps-design.md`. The tests ran on 2026-11-27 on clusters of the provider with three control plane nodes and one worker, with a call to the shared address each second (`lab/phase2-gaps-run/`).

What was built:

- **The health gate in the NVKE agent** (branch `feat/agent-endpoint-health-gate`, `results/phase2-gaps-agent-gate.md`). Before an operation the agent writes a gate file. The readiness probe of the pod reads the file, so the pod leaves the shared Service. After a settle time the agent closes the open connections of remote clients with `ss -K` and checks that no new connection arrives. After the operation it removes the file. The controller, the guard and the gRPC API have no change.
- **The readiness probe as a program of the node image** (provider commit `b4f8837d`). The program passes when the gate file does not exist and `/readyz` of the local API server answers 200.
- **The capacity signal** (provider commit `d2880014`, NVKE branch `feat/capi-failure-domain-unavailable`, `results/phase2-gaps-capacity.md`). The provider sets the reason `FailureDomainUnavailable` when the scheduler cannot place the pod of a Machine with a failure domain. NVKE reads the reason, and its existing rule moves the node to another domain after 15 minutes.

| Pass rule | Result | Before, with no gate and no signal |
|---|---|---|
| 1. Forced certificate renewal: no other Node goes NotReady, each call gets 200 | Pass. 510 of 510 calls with 200. The worker stayed Ready, with 0 lease errors of its kubelet. The workflow took 8 min 9 s | 587 of 593. The worker was NotReady two times. 9 min 49 s |
| 2. Encryption on, the same rule | Pass. 356 of 356 calls with 200. No Node lost Ready. 5 min 32 s | 353 of 357. 5 min 40 s |
| 3. Rollout of three nodes: each call gets 200 | Pass in two rollouts: 968 of 968 and 1630 of 1630. No Node that was Ready lost Ready | 6 of 519 calls with 500 |
| 4. A gate that the probe does not read: the operation does not start | Pass. The check for new connections failed, the agent opened the gate again 20 s after it closed it, and NVKE ended the renewal in 31.5 s with the text of the check. No certificate and no static pod changed. 106 of 106 calls with 200 | Not applicable |
| 5. A surge node in a full failure domain: NVKE shows the message of the provider | Pass in two rollouts. The reason was on the `PodVMMachine` and on the Machine (`InfrastructureReady`), and the message was on the node in the NVKE API | No reason and no message |
| 6. After 15 minutes NVKE places the node in another domain, with no operator step | Pass. The controller recorded the delete of the stuck node 15 minutes after the node was made, and made a new node in another domain 65 s later. The rollout ended by itself after 1637 s | The upgrade waited 1006 s until an operator moved the worker |
| 7. A place gets free before the 15 minutes: the pod starts and the reason goes away | Pass. The place was freed through the NVKE API after 183 s, the pod got its node, and the reason was gone 305 s after the provider set it | Not applicable |

How the gate worked on a node, from the logs of the agents:

- The pod was not ready and out of the EndpointSlice of the shared Service 4.2 to 6.1 s after the gate closed.
- The agent closed 2 to 10 sockets for each operation.
- The withdrawal took about 46 s (a settle time of 15 s in the lab image, then the check for new connections).
- After an operation the pod was in the EndpointSlice again about 72 s after the gate closed (encryption on).
- The teardown of a control plane node uses the same withdrawal. So a rollout, an upgrade and a delete have the guard too. The 500 answers of finding 7 did not come back.

What the changes cost and what stays:

- The guard before an operation takes about 50 s for each node, where it took 10 s. The two guarded workflows were not slower as a whole.
- Key rotation has no guard in NVKE, so no gate closed there. It passed as before (203 of 203 calls with 200).
- After the move of pass rule 6, two control plane nodes are on one host node. NVKE marks the full domain for 3 hours and has no step that moves a node back. The rule does the same for NICo.
- The gate needs three more kernel options in the guest (finding 18).
- On `main` the rule of pass rule 6 does not act for a cluster with no `controlPlaneVIP`. The lab build has the commits of `feat/control-plane-endpoint`, with which it acts for a cluster with `controlPlaneEndpoint`.

Not tested for the gaps: a kube-vip node with a gate, the etcd defrag with a gate, IPv6, OIDC enablement, a load balancer other than the Service of the host cluster, more than one worker, and a pod with no failure domain that the scheduler cannot place.

## 1d. The fix for a join after encryption is turned on

The first rollout of section 1c ran on a cluster that had encryption turned on, and it stopped at the first node (finding 17). Davanum chose on 2026-11-27 to fix it on a branch and to test it. The fix is the commit `06ffc498` on the branch `fix/agent-encryption-join-config` (`results/phase2-encryption-join-fix.md`). The test ran on a new cluster with the fixed agent in each control plane node (`lab/phase2-gaps-run/result.md`, section 7).

| Step | With the old agent | With the fix |
|---|---|---|
| The `apiServer` part of the `kubeadm-config` ConfigMap after encryption is turned on | 2 flags, the volume `enc`, and a volume for a file that no code makes. 16 flags and 3 volumes are lost | All 16 flags and 3 volumes from before, plus the two encryption flags and the volume `enc`. No volume for the file |
| Encryption on | Pass, 356 of 356 calls with 200 | Pass, 428 of 428 calls with 200, 6 min 51 s |
| Rollout of the three control plane nodes | Stopped at the first node. The API server of the new node had no container, and `JoinNode` failed two times with a timeout | Pass in 997 s, 1002 of 1002 calls with 200. Each of the three `JoinNode` workflows completed with one `KubeadmJoin` attempt |
| The API server of a new node | Not started | It runs with `--encryption-provider-config`, and its other 43 flags and values match the old nodes |
| A new Secret after the rollout | Not reached | Stored in etcd as `k8s:enc:secretbox:v1:...`, and readable through the API |

- In the whole test of the fix the shared address answered 1569 of 1569 calls with 200, and no Node that was Ready lost Ready.
- Not tested: the repair of a cluster where the old agent already turned encryption on, an upgrade or a node replace with encryption on, and a cluster with encryption from its creation.

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
14. **A cluster with a shared LoadBalancer address has nothing in the place of the kube-vip guard.** In the certificate renewal each control plane node has no etcd for about 80 s. In the stock design the guard takes the VIP away from that node first, so that the kubelets of the workers move to another API server. Here the agent finds no kube-vip and skips, and nothing moves the connections. Seen: the worker Node was NotReady two times (one time for about a minute), 6 of 593 calls to the shared address failed, and the provider logged three timeouts of 30 s. No pod was moved off the worker. The plan lists a "rollout guard with no kube-vip" as phase 2 work. Built on 2026-11-27 as a health gate in the agent, on the branch `feat/agent-endpoint-health-gate`, and proven in the lab (section 1c).
15. **A pending surge node of a rollout waits with no end on this path.** NVKE gives the surge Machine the failure domain of the node it replaces. When that domain has no room, NVKE has a rule that places the node again after 15 minutes, but it asks the provider client if the domain is out of capacity, and the client for a provider with a template always says no (`controller/internal/clients/capi/rotation.go:28-31`). In the lab the worker held the second volume place of that host node, and the upgrade waited 1006 s until the worker was moved through the API. A worker Machine has no failure domain, so the scheduler can put it on any host node. Corrected on 2026-11-27 with a reason that the provider sets and NVKE reads (branch `feat/capi-failure-domain-unavailable` and provider commit `d2880014`), and proven in the lab (section 1c).
16. **Two flows of the exit gate have no API request**: the forced certificate renewal and the key rotation are operator workflows in Temporal.
17. **After etcd encryption is turned on for a cluster that exists, no new control plane node can join.** The agent on the node that ran `kubeadm init` rewrites the `kubeadm-config` ConfigMap at the end of the flow (`agent/internal/agent/etcd_encryption_at_rest.go`, `updateEncryptionEntryForKubeadmConfigMap`). It parses the document with a YAML library that gives a nested map another type, so its type check on the `apiServer` section fails every time and it starts from an empty section. The section then has one volume for the file `/etc/kubernetes/encryption-config.yaml`, which no code makes, and the 16 flags and 3 volumes of the lab version are gone (audit, admission plugins, the authentication config, the TLS ciphers and others). `kubeadm join` and `kubeadm upgrade` build the API server of a node from that section. Seen in the lab: the surge node of a rollout never joined, with "hostPath type check failed". The defect is not specific to pods. A cluster with encryption from its creation does not have it (from the source and from real kubeadm, not from a cluster). Corrected on the branch `fix/agent-encryption-join-config` (`results/phase2-encryption-join-fix.md`), and proven in the lab: with the fix the section stays whole and a rollout of the three nodes passes (section 1d). The fix does not repair a cluster that already has the wrong ConfigMap.
18. **The Kata guest kernel of the lab could not close a socket from outside.** It had no `INET_DIAG` at all. `ss -K` printed the socket, ended with code 0 and closed nothing, so the agent would count a socket as closed that is still open. Only the agent's check for new connections would find it. The guest kernel needs `INET_DIAG`, `INET_TCP_DIAG` and `INET_DIAG_DESTROY` for the withdrawal of a node, with kube-vip or with the gate.
19. **The agent writes no log line for a failed check for new connections.** The text is only in the status of the operation, and it says "after kube-vip exit" also on a node with no kube-vip.
20. **The teardown of a node that never got a host node waits 60 s for `KubeadmReset`**, which fails together with `LabelNode`, and then goes on.
21. **The cluster record in the NVKE API does not show a failure domain that the controller marked as full.** The mark shows only through its effect.

## 5. What the lab still does in the place of a product part

- **Storage.** The lab has a storage class with local block volumes that a script makes again after each delete. A site needs a storage driver that gives a new block volume to each new claim.
- **The shared endpoint.** The caller makes the LoadBalancer Service and the pod namespace before the request.
- **The network.** A second Docker network and a Linux bridge in each host node, with Multus and a static address plugin. A site needs a secondary network on the node network, with the address and the hardware address from the pod spec.
- **The guest kernel.** A Kata kernel with 11 added options (8 for Open vSwitch and Geneve, 3 for the socket close of the agent, finding 18), built by hand and installed as its own handler.
- **The node image.** Built in the lab folder, on top of an image under `controller/hack/`. The repository has no place for it yet.
- **The NVKE stack.** Installed by hand with the rights for the three kinds in a manifest outside the chart. NVKE uses the provider through the `infra` path, which the docs do not name as a product path.

## 6. Not tested

- A cluster with its workers on bare metal. A worker as a pod of the provider is tested.
- The reboot with the soft reboot of NVKE turned off.
- More than two workers. A control plane rollout while a worker holds the second volume place of a host node is tested now (section 1c).
- A worker with no etcd volume. The provider and the image both need the volume today.
- The loss of a host node with the provider, and a move of a pod to another host node with a real network volume.
- An upgrade with enough volume places from the start, an upgrade of a cluster with encryption on, and a scheduled renewal cycle. A rollout of a cluster with encryption on is tested now (section 1d).
- A failed renewal or rotation and its recovery, and OIDC enablement, which uses the same guard.
- Two clusters of the provider at one time, and the rule against overlapping address ranges in a cluster.
- A startup probe that does not pass in 20 minutes, and a restart of the provider during a flow. A pod that cannot be scheduled is tested now for a Machine with a failure domain (section 1c).
- The workstation, and a machine with no nested virtualization.
- arm64. The arm machine of the lab has no KVM, so Kata cannot run there. Davanum decided on 2026-11-26: no arm64 now.
- A real site: a production CNI for the secondary network, a real load balancer, a storage driver.

## 7. What comes after phase 2

For Davanum:

1. Sign the commits and open the pull requests: the fix of the NVKE agent (it stands alone and corrects a fault of NVKE with recent kubeadm), the `controlPlaneEndpoint` field, and the provider. The Kata fix of phase 0 is its own pull request upstream.
   - New on 2026-11-27: the fix for a join after encryption is turned on (`fix/agent-encryption-join-config`, it stands alone too), the health gate in the agent (`feat/agent-endpoint-health-gate`), the capacity signal in the controller (`feat/capi-failure-domain-unavailable`), and the ADR (`docs/adr-control-plane-nodes-as-kata-pods`).
   - The upload-certs fix and the health gate each add a field at the end of one struct of the agent. The second one that goes to main gets a small merge conflict.
   - A cluster that turned encryption on before the fix has lost the `apiServer` settings in its `kubeadm-config` ConfigMap. It needs a repair by hand or a repair step in the controller. Neither is written.
2. The six points for the review of the agent fix (`results/phase2-agent-fix.md`, section 3).

For a product form of the provider (not planned and not estimated yet):

1. The first class integration into NVKE: a request object, a provider client, the chart rules, docs. `results/phase2-provider-report.md`, section 8, lists what a pull request for the module itself needs.
2. A place in the repository for the node image for pods, and the guest kernel as a release part.
3. What reacts to the loss of a host node, together with the volume kind.
4. Workers on bare metal in the same cluster: one cluster has exactly one provider today.
5. A guard for the shared address in the place of the kube-vip guard (finding 14), and a capacity answer of the provider for a pending surge node (finding 15). Both are built on branches and proven in the lab on 2026-11-27 (section 1c). Open for a product: an HTTP health port in the agent for a load balancer that cannot run a program on the node, and a step that moves a control plane node back after a move to another failure domain.
6. etcd backup and restore, which the plan lists for this phase. The controller and the agent have no request and no code for it. The bundle `etcd-manager`, which the docs name for snapshots, is not in the repository and not tested in the lab (section 1b).
7. The smaller provider points from the tests: take the pod out of the shared Service at the start of a delete, a shorter time limit for the look at the Node of the new cluster, tolerations and a node selector, an etcd volume only for control plane machines (the provider API and the entry point of the image both need it today).
8. The smaller image points: the Open vSwitch system ID on the volume, and a place for the journal that stays through a new pod.
9. The setting `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` in a deployment with this provider.
