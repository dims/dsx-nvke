# Summary of the lab that ran NVKE control plane nodes as Kata pods

The summary has the date 2026-11-27. The state of the branches in it is of 2026-11-28 at 08:10.

## Conclusion

NVKE can run each control plane node of a tenant cluster as one Kata pod on a second Kubernetes cluster, the host cluster. NVKE is the NVIDIA Kubernetes Engine, a management plane that makes GPU Kubernetes clusters on bare metal. A Kata pod is a pod whose container runs in a small virtual machine with its own kernel.

In the lab, one request to the NVKE API made a cluster with three control plane nodes as Kata pods. NVKE then ran its lifecycle flows on such a cluster, from a node replace to a Kubernetes upgrade, with the same node agent and the same workflows as on bare metal.

The lab ran on two amd64 machines. The tests of phase 2 and phase 3 ran on a machine with nested virtualization, where each Kata virtual machine runs inside another virtual machine. The tests found two gaps and two defects of NVKE. All four have a change on a branch, and the form of each change that the lab ran passed its test. The branches were reworked after the tests, and the lab has not run the final forms (section "What exists as code").

Phase 3 added workers of a second kind to the same cluster. With the NICo simulator of the repository in the place of bare metal machines, one request made a cluster with the control plane in pods and the workers from NICo, with no new NVKE code.

## What the lab tested and how it works

On bare metal, the NVKE node agent, a service on each node, runs kubeadm, and kubeadm starts the API server and etcd as static pods of the kubelet. In the tested form, the node is a Kata pod that runs systemd, containerd, the kubelet and the node agent, so kubeadm and NVKE work as on a machine.

A new provider, `cluster-api-provider-podvm`, makes the pods. It is a Cluster API infrastructure provider, which is the kind of controller that makes machines for NVKE. For each node the provider makes the following parts:

- One pod with the Kata runtime class, on the node of the host cluster that NVKE chose.
- Two raw block volumes, one for `/var` and one for the etcd data.
- A fixed node address on a second network interface, with no address translation between the nodes.
- A copy of the bootstrap data of NVKE.

The API servers of a cluster share one endpoint address. A LoadBalancer Service of the host cluster holds the address and forwards only to pods with a ready API server. The caller gives the address to NVKE in a new request field, `controlPlaneEndpoint`. In the lab a person made that Service before the request. The provider branch now has code that makes the Service by itself, and that code has not run in a cluster.

## Results

Phase 0 tested one node in a virtual machine of Kata Containers 4.4.0. In phase 1, a script made three pods, and NVKE joined them through its existing `infra` path, which accepts Cluster API manifests from the caller. In phase 2, the provider made the pods. In phase 3, the workers came from the NICo simulator, which starts each machine as a container. The times of phase 2 come from the machine with nested virtualization, so they do not compare with other machines. The sources are files in the lab notes.

The Source column of the tables names files of the lab notes. Some of them are also on the public fork, in the folder `hack/kata-control-plane-lab/` of the branch `test/kata-control-plane-lab`, as a snapshot of 2026-11-27. The task list, the run log and the review reports are not public.

| Phase | Test | Result | Source |
|---|---|---|---|
| 0 | `kubeadm init` through the node agent in a Kata pod | The test passed in 3 of 3 runs. | `tasks/todo.md` |
| 0 | Sync time of the etcd log on a raw block volume, 99th percentile | One Kata node needed 7.8 ms with 756 simulated nodes, below the limit of 10 ms. Three replicas on one shared lab disk needed 10.7 to 11.7 ms. | `tasks/todo.md`, `runlog.md` |
| 0 | Restarts of containerd, the kubelet and Kata on the host | The restarts caused 0 failed calls in 9,354. | `tasks/todo.md` |
| 1 | NVKE makes a cluster on three pods from a script | The test passed in 3 of 3 runs, with "provisioned" about 156 s after the request in a clean run. | `results/phase1-results.md` |
| 1 | Pod traffic between the control plane nodes | Traffic passed in 0 of 6 directions with a LoadBalancer address for each pod. It passed in 6 of 6 with a fixed address and a Kata kernel that has Open vSwitch, the virtual switch of the pod network. | `results/phase1-results.md` |
| 1 | Shared endpoint during a replace of the first node pod | The endpoint answered 364 of 364 calls. | `results/phase1-results.md` |
| 2 | Create and delete of a cluster through the API | One request made the cluster in 5 of 5 creates, with "provisioned" after 208 to 254 s. A delete left no object about 35 s after the request, 4 times. | `results/phase2-results.md` |
| 2 | Loss of one pod, and replace of one node | A lost pod was back after 50 to 52 s with no operator step. A replace through the API took about 180 to 190 s. | `results/phase2-results.md` |
| 2 | Rollout of three nodes to a new image | The rollout took 489 s with 0 failed joins. It needs the first agent fix. | `results/phase2-results.md` |
| 2 | etcd encryption, key rotation and forced certificate renewal | The flows took 5 min 40 s, 5 min 38 s and 9 min 49 s. In the renewal, 6 of 593 calls to the endpoint failed, and the worker node was NotReady two times (first gap). | `results/phase2-results.md` |
| 2 | Upgrade from Kubernetes 1.35.5 to 1.36.4 | The upgrade passed with one stop of 1006 s (second gap). It takes about 630 s without the stop. | `results/phase2-results.md` |
| 2 | One worker node as a pod | The node was Ready after 78 s, and five tests passed. A reboot took 31 minutes, and the lab did not test the NVKE setting that removes the wait. | `results/phase2-results.md` |
| 2 | The same flows with the change for the first gap | In the forced renewal the endpoint answered 510 of 510 calls, and the worker stayed Ready. It answered 356 of 356 calls while encryption was turned on, and 968 of 968 and 1630 of 1630 in two rollouts. | `results/phase2-results.md`, section 1c |
| 2 | A rollout with no room on one node of the host cluster, with the change for the second gap | NVKE moved the waiting node to another node of the host cluster 15 minutes after it made the node, and the rollout ended with no operator step after 1637 s. | `results/phase2-results.md`, section 1c |
| 2 | A rollout after encryption was turned on | With the agent as it is, the first new node never joined. With the first form of the second agent fix, the three nodes joined at the first attempt, and a new Secret was stored encrypted. | `results/phase2-results.md`, section 1d |
| 3 | One request makes a cluster with the control plane in pods and two workers from the NICo simulator | The cluster had five good nodes 5 min 22 s after the request. NVKE needed no new code. | `results/phase3-results.md` |
| 3 | Traffic between the two kinds of node | Pod traffic passed on 20 of 20 lines. Each of the three API servers reached each worker for logs, exec and port forward, with no proxy. | `results/phase3-results.md` |
| 3 | Workers through NVKE | NVKE added a worker in 57 s and refilled a deleted worker in 68 s. A reboot of a worker took 61 s with one NVKE setting. A delete of the cluster left nothing. | `results/phase3-results.md` |
| 3 | Control plane flows with the workers present | A rollout and a forced certificate renewal passed with 701 of 701 and 627 of 627 calls answered, and no worker was disturbed. | `results/phase3-results.md` |
| 3 | A Konnectivity prototype, for workers that the control plane cannot reach | Konnectivity is the upstream proxy for the calls of the API server to the nodes. With it, logs, exec and port forward passed on 18 of 18 calls. The pod network between the workers and the control plane stayed broken. So this design needs a routed network between the two, and then it needs no Konnectivity. | `results/phase3-results.md`, section 4 |

## Findings in NVKE that apply with or without Kata pods

- The node agent has a defect in the kubeadm step that uploads the certificates. The agent gives kubeadm a config for the step only on the first control plane node. Since kubeadm 1.33.12, 1.34.8, 1.35.5 and 1.36.1, kubeadm with no config takes the address of the default route interface. When the node address is on another interface, no new control plane node can join after the first node is gone (`results/phase2-results.md`).
- The node agent has a second defect, in the flow that turns etcd encryption on for a cluster that exists. The agent rewrites the stored kubeadm configuration and replaces its whole API server section. In the lab 16 flags and 3 volumes were lost, and the one volume that the agent wrote names a file that no code makes. After that no new control plane node can join. A cluster with encryption from its creation does not have the defect, by the source and by a check with kubeadm (`results/phase2-encryption-join-fix.md`).
- NVKE reports a cluster as provisioned when the pod network between its nodes does not work, because no step checks it (`results/phase1-results.md`). Phase 3 saw the same for a worker.
- The NICo simulator loses a race at the start of a container machine: it runs the start commands of a machine before systemd is ready. In the lab one worker then never joined, and systemd was not ready at the start of the commands in three of the first four worker starts. A fix is on a branch and passed 8 of 8 worker starts (`results/phase3-nico-sim-race-fix.md`).
- A node that runs as a container can touch the devices of its host through the node agent. Without one flag the agent runs a device rescan at each start, and NVKE replaces the agent arguments of the image. The lab image forces the flag (`results/phase3-results.md`).
- NVKE cannot delete a cluster through its API alone when the cluster uses `cluster-api-provider-provisioned`, the provider for hosts that exist before the request (`results/phase1-results.md`).
- The forced certificate renewal and the key rotation have no API request. The controller and the agent have no etcd backup or restore. The docs name a bundle `etcd-manager` for snapshots, its source is not in the repository, and the lab did not test it (`results/phase2-results.md`).

## The two gaps and their changes

- A guard for the shared endpoint. On bare metal, NVKE takes the address of the API servers away from a node before it stops etcd or the API server there, and a pod had no such guard. The change adds a health gate to the node agent. The agent writes a file, the readiness probe of the pod reads the file, and the pod leaves the Service. The agent then closes the open connections and checks that no new one arrives. With a probe that does not read the file, the check fails and the operation does not start.
- A capacity signal. A rollout adds its extra node on the same node of the host cluster as the node that it replaces, and the extra node waited with no end when no room was left there. With the change, the provider reports the cause, and an existing rule of NVKE moves the node. After such a move two control plane nodes are on one node of the host cluster, and nothing moves a node back.

## What exists as code

The branches are on a public fork of the NVKE repository, `github.com/dims/dsx-nvke`, on top of the main branch. None has a pull request.

State on 2026-11-28 at 08:10: the branches were reworked for pull requests after the last lab test, and three fresh reviews read them. Each code branch has other commits than the lab ran, apart from the capacity signal and the code of the simulator fix. The lab ran the forms before the rework, which stay on the fork under `lab/` names. `branches-to-share.md` lists each branch with its tip and its commits. The request field got the points of its review at 08:05. Three branches are still in work today (the capacity signal, the provider and the node image), so their commits change again.

| Branch | Content | Source |
|---|---|---|
| `feat/cluster-api-provider-podvm` | The provider as a new module, with 92 test functions, in 21 commits. The first 15 commits have the Go code that the lab ran. Five commits are new: the provider makes the Service of the shared endpoint by itself, the controller chart can grant NVKE the rights for the kinds of the provider, and the module has samples and an install text. The new commits have not run in a cluster | `results/phase2-results.md`, `results/phase2-gaps-capacity.md`, `results/review-provider-branches.md` |
| `feat/podvm-node-image` | The node image for the pods, inside the provider module, in three commits on top of the provider branch. The image builds, and it has not run in a pod. A fresh review found two faults. Both are corrected on the fork since 2026-11-28, 08:13: a volume is formatted only when two checks agree that it is empty, and a file mode is read right | `results/phase2-node-image-branch.md`, `results/review-provider-branches.md` |
| `feat/podvm-deploy-path` | A deploy path with the pod provider and the scripts for a kind host cluster, in 12 commits on top of the node image branch. Static checks only, no run on a cluster yet | `deploy-path-design.md` |
| `fix/agent-upload-certs-config` | The first fix of the node agent, in one commit that needs no other branch. It is smaller than the form that the lab ran | `results/phase2-agent-fix.md`, `results/review-agent-branches.md` |
| `fix/agent-encryption-join-config` | The second fix of the node agent, in one commit that needs no other branch. It has a new, small form: the agent no longer writes the stored kubeadm configuration in this flow, because the controller already merges the encryption settings at the end of the same workflow. The lab ran the first form, a merge in the agent | `results/phase2-encryption-join-fix.md`, `results/review-agent-branches.md` |
| `feat/control-plane-endpoint` | The request field `controlPlaneEndpoint`, in eight commits, in a smaller form than the lab ran. A fresh review found one must fix: nine sentences of the API reference named only the older VIP field. It is corrected on the fork since 2026-11-28, 08:05, with a test for the rule that such a cluster gets no kube-vip | `results/phase1-results.md`, `results/review-controller-branches.md` |
| `feat/agent-endpoint-health-gate` | The health gate in the node agent, in four commits, with less code than the lab ran and the same behavior by its tests | `results/phase2-gaps-agent-gate.md`, `results/review-agent-branches.md` |
| `feat/capi-failure-domain-unavailable` | The capacity signal on the side of NVKE. Small changes from a fresh review are in work | `results/phase2-gaps-capacity.md`, `results/review-controller-branches.md` |
| `fix/nico-sim-wait-for-systemd` | The fix of the NICo simulator, in one commit that needs no other branch | `results/phase3-nico-sim-race-fix.md` |
| `docs/adr-control-plane-nodes-as-kata-pods` | A proposed architecture decision record for the repository | `tasks/todo.md` |
| `test/kata-control-plane-lab` | The lab scripts, the results and the node image that the lab ran | `tasks/todo.md` |

A fix of the Kata agent from phase 0 is on the branch `fix/agent-kill-child-cgroups` of `github.com/dims/kata-containers`, in one commit. The branch `lab/agent-kill-child-cgroups` there has that commit and a second change for exec, which the lab also ran (`tasks/todo.md`).

Two branches are for a person who wants to try the feature, and not for a pull request. Both have the name `integration/control-plane-kata-pods`. The one on `github.com/dims/dsx-nvke` has the commits of the nine NVKE branches for pull requests in one tree, 41 commits on the main commit. It is built again after each change of a branch. The one on `github.com/dims/kata-containers` is Kata Containers 4.4.0 with the two changes of the Kata agent.

## What is open and what the lab cannot show

The following parts do not exist yet (`results/phase2-results.md`):

- The provider as a product path of NVKE. The lab used the `infra` path, which the NVKE docs do not name as a product path.
- A release process for the node image and for the Kata kernel. The stock Kata kernel has no Open vSwitch and cannot close a connection from outside, so the lab built a kernel with 11 added options by hand.
- A production storage driver, network and load balancer in the place of the lab parts.
- A reaction to the loss of a node of the host cluster. The control plane fails with its host cluster.
- Workers on real bare metal in the same cluster. Phase 3 showed the form with the NICo simulator only. It used the `infra` path, where a worker pool has none of the functions of a NICo pool in NVKE, such as releases and placement retries. NVKE needs a decision on the request form for a product.
- A repair for a cluster that already lost its API server settings when encryption was turned on. The second agent fix stops the loss and does not bring the settings back.
- A run of the final branches (state on 2026-11-28 at 08:10). The lab ran the forms before the rework. The new form of the second agent fix, the Service that the provider makes, and the node image of the new branch have not run in a cluster.
- The points of the three fresh reviews on two branches, which are in work: smaller points in the provider and in the capacity signal. The one must fix, in the API reference text of the request field, is corrected since 2026-11-28, 08:05, and the two faults of the node image since 08:13.
- A run of the deploy path. The branch `feat/podvm-deploy-path` is on the fork since 2026-11-28, 08:24: a deploy path of the repository with the pod provider, as the repository has one for its container nodes in the end to end tests, the scripts for a kind host cluster (Kata with a custom runtime, the node network, a load balancer, block storage), example requests and a README with the whole run. Nothing of it ran on a cluster yet. Until that run passes from an empty machine, a person outside the team cannot bring up the feature from the public repositories alone (`results/try-it-public-gaps.md`, `deploy-path-design.md`).
- An issue for each pull request. The repository asks for one, and for a new feature the issue must be agreed before the work. No issue exists.

The lab cannot show the behavior on a production site, in CI, on arm64, or without nested virtualization for the final design. It also cannot show etcd under a production load, or failure cases such as the loss of a node of the host cluster. Most tests of the changes ran one time.
