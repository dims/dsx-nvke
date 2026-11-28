# Branches to share: NVKE control plane nodes as Kata pods

Last update: 2026-11-27, 23:05 local time.

This page lists the only branches that the larger team needs. Each one is meant to become one pull request. No pull request is open yet. Every other branch on the two forks is lab material and is not for sharing.

- NVKE branches are on the fork `dims/dsx-nvke` and go to `dsx-ai-factory/nvke`. All sit on the main commit `d625fcfa`.
- The Kata branch is on the fork `dims/kata-containers` and goes to `kata-containers/kata-containers`.

## State

| # | Branch | Commits | Lines changed | State |
|---|---|---|---|---|
| 1 | `fix/agent-upload-certs-config` | 1 | 371 added, 36 removed | Ready |
| 2 | `fix/agent-encryption-join-config` | 1 | 562 added, 25 removed | Ready |
| 3 | `fix/nico-sim-wait-for-systemd` | 1 | 195 added, 6 removed | Ready |
| 4 | `docs/adr-control-plane-nodes-as-kata-pods` | 1 | 64 added | Ready |
| 5 | `feat/control-plane-endpoint` | 8 | 1,512 added, 519 removed | Split into small commits with the same content. A second pass makes it smaller |
| 6 | `feat/agent-endpoint-health-gate` | 4 | 1,116 added, 3 removed | Ready. Reworked on 2026-11-27: four small commits, about a third smaller, the same behavior |
| 7 | `feat/capi-failure-domain-unavailable` | 1 | 306 added, 6 removed | Ready |
| 8 | `feat/cluster-api-provider-podvm` | 16 | 9,044 added, 9 removed | Ready. Reworked on 2026-11-27: a series of small commits, the same code |
| 9 | `feat/podvm-node-image` | 3, on top of branch 8 | 893 added, 2 removed | New on 2026-11-27. The image builds. It has not run in a pod yet |
| 10 | `fix/agent-kill-child-cgroups` (Kata) | 1 | 161 added, 6 removed | Ready |

"Ready" means that the commits are final in content. Each branch still needs a rebase on the current upstream main and the signature of Davanum before a pull request. After the rework, all branches are built together again and the lab tests run again. This page gets the result.

## The order

1. Branches 1, 2 and 3 are bug fixes for faults that are on main today. Each stands alone and helps NVKE with or without the rest. They can go first, in any order.
2. Branch 4 is the decision record. It goes early, so reviewers of the rest have the reason.
3. Branches 5, 6 and 7 are small, general changes in the controller API, the node agent and a controller client.
   - Branch 6 and branch 1 each add a field at the end of the same struct of the agent. The second one to merge needs a small rebase.
   - Branch 7 acts for these clusters only together with branch 5.
4. Branch 8 is the provider. It needs branch 5 to be useful, and branch 9 for its node image.
5. Branch 9 stacks on branch 8.
6. Branch 10 is for another project and has no order with the rest.

## What each branch does

### 1. `fix/agent-upload-certs-config`

https://github.com/dims/dsx-nvke/tree/fix/agent-upload-certs-config

- `f240606c` fix(agent): build the upload-certs config on every control plane node
  - The fault: the agent gave `kubeadm init phase upload-certs` a config only on the node that ran `kubeadm init`. Since kubeadm 1.33.12, 1.34.8, 1.35.5 and 1.36.1 that step talks to the local API endpoint, and with no config kubeadm takes the address of the default route interface. When the node address is on another interface, no new control plane node can join after the first node is gone or was started again.
  - The change: on each control plane node the agent builds the config from the annotation of the API server manifest and from the `kubeadm-config` ConfigMap.
  - Proof: unit tests, a check with kubeadm 1.36.4, and the lab. A replace of the first node and a rollout of three nodes pass, and all 10 join workflows completed at the first attempt.

### 2. `fix/agent-encryption-join-config`

https://github.com/dims/dsx-nvke/tree/fix/agent-encryption-join-config

- `06ffc498` fix(agent): merge API encryption into the kubeadm-config ConfigMap
  - The fault: when etcd encryption is turned on for a cluster that exists, the agent rewrites the `kubeadm-config` ConfigMap and replaces the whole API server section. A type check on the parsed YAML always fails, so the code starts from an empty section. In the lab 16 flags and 3 volumes were lost, and the one volume that the agent wrote names a file that no code makes. After that no new control plane node can join.
  - The change: the agent merges the two encryption flags and one volume into the section and keeps the rest.
  - Proof: unit tests, a check with kubeadm 1.36.4, and the lab. With the fix the section stays whole, a rollout of three nodes passes, and a new Secret is stored encrypted.
  - Not covered: a cluster that already lost its settings needs a repair that this commit does not do. A cluster with encryption from its creation does not have the fault.

### 3. `fix/nico-sim-wait-for-systemd`

https://github.com/dims/dsx-nvke/tree/fix/nico-sim-wait-for-systemd

- `a8cd8402` fix(nico-sim): wait for systemd before simulated cloud-init commands
  - The fault: in its container form the NICo simulator runs the start commands of a machine right after the container starts, before systemd can take commands. A `systemctl` command then fails, the start status stays at error, and the node never joins. In the lab that happened in three of four worker starts.
  - The change: the simulator waits until systemd has its control socket, with a limit of 60 s.
  - Proof: unit tests, and 8 of 8 worker starts in the lab with no wait in the request.

### 4. `docs/adr-control-plane-nodes-as-kata-pods`

https://github.com/dims/dsx-nvke/tree/docs/adr-control-plane-nodes-as-kata-pods

- `271052ce` docs(adr): propose control plane nodes as Kata pods
  - One proposed architecture decision record, `docs/adrs/20261127-control-plane-nodes-as-kata-pods.md`, with its row in `docs/README.md`.
  - It records the decision (each control plane node as one Kata pod, through a new provider), the parts that the lab settled, the consequences with the limits of the lab, and the options that lost.

### 5. `feat/control-plane-endpoint`

https://github.com/dims/dsx-nvke/tree/feat/control-plane-endpoint

The branch adds one optional field to the cluster create request, `controlPlaneEndpoint`. A cluster with the field uses that address as its API endpoint and gets no kube-vip. The address belongs to a load balancer outside the cluster.

The eight commits below have the same content as the three commits that the lab ran. A second pass is in work that takes out rewording and repeated tests, so the list can still get shorter.

- `92867b3e` refactor(controller): ask one cluster method at each control-plane endpoint gate (30 lines of code, 30 of tests)
  - No change of behavior. Each place that asks "does this cluster have a stable API address" now calls one method.
- `4cada826` feat(controller): add controlPlaneEndpoint to the cluster API schema (60 lines of spec, the rest is regenerated code)
  - The OpenAPI spec with the new field, and the two generated files. A reviewer reads the spec and skips the generated files.
- `52565ba0` feat(controller): store controlPlaneEndpoint in the clusters table (38 lines of code, 53 of tests)
  - The database column, its migration and the model.
- `8ebd4bef` feat(controller): count controlPlaneEndpoint as a stable endpoint at each gate (16 lines of code, 148 of tests)
  - The one method of the first commit now also says yes for a cluster with the field.
- `6db39fbc` feat(controller): check controlPlaneEndpoint on cluster create (86 lines of code, 93 of tests)
  - The request checks: the form of the address, no IPv6, no overlap with the cluster networks, and not together with the VIP field.
- `b2cfb5bb` feat(controller): accept controlPlaneEndpoint on cluster create (9 lines of code, 277 of tests)
  - The create request stores the value and returns it.
- `35c66283` feat(controller): use controlPlaneEndpoint for kubeadm init and skip kube-vip (22 lines of code, 199 of tests)
  - `kubeadm init` gets the address as its control plane endpoint, and the kube-vip step is skipped.
- `d659ab72` docs: describe controlPlaneEndpoint for workload clusters (20 lines)
- Proof: each commit builds and passes the tests of the controller. The API check finds 14 additive changes and no breaking one. Each lab cluster since phase 1 used the field.

### 6. `feat/agent-endpoint-health-gate`

https://github.com/dims/dsx-nvke/tree/feat/agent-endpoint-health-gate

The need: before an operation that stops etcd or the API server on a node, the agent takes the node out of kube-vip. A node behind a load balancer that it does not run had nothing like that, so clients stayed connected to it.

- `782352f7` feat(agent): add a control plane endpoint health gate (259 lines of code, 498 of tests)
  - The gate itself. Before the operation the agent writes a gate file, which the health check of the load balancer reads. It waits a settle time, closes the open connections of remote clients, and checks that no new one arrives. After the operation it removes the file. The gate file names the flow that closed it.
- `6997c25a` feat(agent): open or hand off a gate that an etcd defrag left closed (35 lines of code, 174 of tests)
  - The etcd defrag withdraws the node by itself. If it stops halfway, the agent opens the gate at its next start, or hands the gate to the caller when the node must stay out of service.
- `55f1ad7b` feat(agent): add the control plane endpoint gate flags (49 lines of code, 55 of tests)
  - Three agent flags: the gate file, the interface on which the connections of the load balancer arrive, and the settle time. With no flag the agent behaves as today.
- `c348713c` docs(agent): describe the control plane endpoint gate (46 lines)
  - The three pages that would be wrong without it.
- The controller and the gRPC API have no change.
- Proof: 57 table cases in the unit tests, and the lab. A forced certificate renewal had 510 of 510 calls answered and no worker disturbed. Without the gate it was 587 of 593, and a worker was not ready two times. The lab ran the commit before the rework. The test with the reworked commits is still to come.

### 7. `feat/capi-failure-domain-unavailable`

https://github.com/dims/dsx-nvke/tree/feat/capi-failure-domain-unavailable

- `23c1ed00` feat(controller): re-place a pending control-plane node of a template-backed provider
  - The need: NVKE moves a control plane node that waits 15 minutes in a failure domain with no room. A provider that comes through a machine template had no way to say that a domain is full, so such a node waited with no end.
  - The change: the provider sets the reason `FailureDomainUnavailable` on its machine, and the controller reads it. The rule itself has no change.
  - Proof: unit tests and the lab. A rollout with a full host node ended by itself.

### 8. `feat/cluster-api-provider-podvm`

https://github.com/dims/dsx-nvke/tree/feat/cluster-api-provider-podvm

The branch adds a new Cluster API infrastructure provider module beside `cluster-api-provider-provisioned`, with the kinds `PodVMCluster`, `PodVMMachine` and `PodVMMachineTemplate`. For each machine it makes one Kata pod, two raw block volumes and a copy of the bootstrap data.

Of the 9,044 lines, about 2,900 are hand-written code, 3,700 are tests, 1,500 are generated, and the rest is manifests and docs. Each of the first 15 commits builds and passes the tests of the module. No Go code differs from the commits that the lab ran. Only comments changed.

- `aebec5dc` feat(podvm): add the module of the pod VM Cluster API provider (11 lines of code, the rest is module files)
  - The Go module, its Makefile, and its entry in the workspace, the coverage registry and the docs.
- `8583351b` feat(podvm): add the PodVMCluster API type (245 lines of code, 437 generated)
  - The cluster object: the namespace for the pods, the address range for the node addresses, and the failure domains in its status.
- `1bad7ee4` feat(podvm): add the PodVMMachine API type and its template (323 lines of code, 45 of tests, 778 generated)
  - The machine object and its template: the node image, the runtime class, the sizes of the pod and of its two volumes, and the provider ID form.
- `855441fb` feat(podvm): add the address range arithmetic (147 lines of code, 282 of tests)
  - How the provider picks a free address from the range, and how it derives a fixed hardware address from it.
- `f8a01116` feat(podvm): add the cluster controller (428 lines of code, 463 of tests)
  - It checks the cluster object, publishes one failure domain for each host node, and reports ready.
- `707df0c0` feat(podvm): add the machine controller up to the address (308 lines of code, 326 of tests)
  - It waits for the Machine, the cluster and the bootstrap data, then gives the machine a fixed address that it keeps for its whole life.
- `f613f5b4` feat(podvm): build the pod and the volume claims of a machine (316 lines of code, 195 of tests)
  - The pod specification, which is the contract with the node image: one privileged container, two raw block devices, the bootstrap data as a file, the address on a second interface, and the probes.
- `4be181b2` feat(podvm): make the pod and report the machine (369 lines of code, 501 of tests)
  - It makes the claims, the copy of the bootstrap data and the pod, and reports the address only when the node agent in the pod answers.
- `ba441faf` feat(podvm): delete the objects of a machine (127 lines of code, 287 of tests)
  - The delete with a finalizer: the pod, the claims and the copy of the bootstrap data go.
- `39a7b8b4` feat(podvm): replace a pod that ended and answer a reboot request (86 lines of code, 327 of tests)
  - A lost pod comes back with the same name, volumes and address. A reboot request of NVKE is answered one time.
- `255be6ac` feat(podvm): set the provider ID on the Node of the workload cluster (267 lines of code, 524 of tests)
  - The provider writes the provider ID on the Node of the new cluster, and waits when that cluster does not answer yet.
- `e6802ac3` feat(podvm): end a run with no error when the object is gone (105 lines of code, 459 of tests)
  - A machine that is deleted in the middle of a run gives no error line.
- `235f93f5` feat(podvm): report a pod that the scheduler cannot place (79 lines of code, 323 of tests)
  - The reason `FailureDomainUnavailable` that branch 7 reads, and `PodUnschedulable` for a machine with no failure domain.
- `3e798248` feat(podvm): add the manager program and its manifests (105 lines of code, 252 of manifests)
- `7fc4d539` docs(podvm): add the README of the pod VM provider (376 lines)
- `6896e4aa` ci: add the podvm provider module to the module checks (50 lines in 8 files)
  - The lint, generate check and build workflows, the labeler, the pull request template and the tables of `AGENTS.md`. It is apart, so it can be dropped.
- Proof: 81 test functions with 161 subtests, and each lab test of the control plane in pods ran this code.
- Not in the branch: the wiring of a new provider into the image and release workflows, the code owners, nvkectl and the controller chart. That needs decisions of the maintainers.
- Known: two checks of the repository root pass at the tip and fail at commits in the middle of the series (the coverage registry at the first two commits, and `go mod tidy` before the manager commit).

### 9. `feat/podvm-node-image`

https://github.com/dims/dsx-nvke/tree/feat/podvm-node-image

The branch adds the node image for the pods, inside the provider module at `cluster-api-provider-podvm/node-image/`. The provider of branch 8 cannot be used without it. The branch sits on top of branch 8, and the three commits below are its own.

- `9f3a9a5d` feat(podvm): add the bootstrap program of the node image (248 lines of code, 149 of tests, two units)
  - A small program that applies the bootstrap data of NVKE in the pod: it writes the files and runs the commands that a machine would get from cloud-init. Two systemd units run it, one early and one after the network is up.
- `1e205589` feat(podvm): add the node image for pod machines (276 lines in 9 files)
  - The Dockerfile on top of the container node image of the repository, the entry point of the pod, the readiness program that the provider's probe runs, the agent flags of branch 6, and a check that Open vSwitch uses the datapath of the guest kernel.
- `9010fe85` docs(podvm): describe the node image and its guest kernel options (180 lines)
  - The README with the contract between the provider and the image, what Kata and the host cluster must give, and the two fragment files with the 11 options that the guest kernel needs.
- Proof so far: the image builds with no network on top of the base image, and the checks of the module and of the repository root pass.
- Open: this image is a shorter form of the image that the lab ran, and it differs in small points of behavior. It has not run in a pod yet. The lab test on the final branches covers it.

### 10. `fix/agent-kill-child-cgroups` (Kata Containers)

https://github.com/dims/kata-containers/tree/fix/agent-kill-child-cgroups

- `e0f5597` agent: kill the init process and child cgroups of a container
  - The need: a container that runs systemd keeps processes in child cgroups. The Kata agent did not end them when the container was killed.
  - The change: the agent kills the init process and the child cgroups of the container.
  - The lab ran each test with it. A second change of the lab, for exec in such a container, belongs to an upstream pull request of another author and is not on this branch.
