# Branches to share: NVKE control plane nodes as Kata pods

Last update: 2026-11-28, 08:10 local time. Each tip in the state table was the tip of its branch on the fork at that time (fetched at 08:10).

This page lists the only branches that the larger team needs. Each of the ten is meant to become one pull request. No pull request is open yet. One more branch, `integration/control-plane-kata-pods`, holds the commits of branches 1 to 9 together, for a person who wants to try the feature. It is not for a pull request. Every other branch on the two forks is lab material and is not for sharing.

- NVKE branches are on the fork `dims/dsx-nvke` and go to `dsx-ai-factory/nvke`. All sit on the main commit `d625fcfa`.
- The Kata branch is on the fork `dims/kata-containers` and goes to `kata-containers/kata-containers`.

## State

| # | Branch | Tip | Commits | Lines changed | State |
|---|---|---|---|---|---|
| 1 | `fix/agent-upload-certs-config` | `23d61df4` | 1 | 330 added, 66 removed | Ready. Made smaller after a fresh review, which found no bug. The smaller form is on the fork since 2026-11-28 |
| 2 | `fix/agent-encryption-join-config` | `df409c97` | 1 | 49 added, 59 removed | Ready in a new, small form: a delete in the agent, where the first form added 562 lines. Davanum chose it on 2026-11-28. The lab has not run this form yet |
| 3 | `fix/nico-sim-wait-for-systemd` | `7bf172e6` | 1 | 195 added, 6 removed | Ready. One sentence of the commit message was corrected on 2026-11-28, the code is the same |
| 4 | `docs/adr-control-plane-nodes-as-kata-pods` | `26828722` | 1 | 66 added | Ready. Corrected on 2026-11-27 after a fresh read of the docs |
| 5 | `feat/control-plane-endpoint` | `120b0ff2` | 8 | 1,289 added, 475 removed | Ready. The must fix of the fresh review is in since 2026-11-28: the API reference names both fields. The lab has not run this form yet |
| 6 | `feat/agent-endpoint-health-gate` | `edddaff0` | 4 | 1,107 added, 3 removed | Ready. A fresh review found no bug, and its small changes are in since 2026-11-28 |
| 7 | `feat/capi-failure-domain-unavailable` | `23c1ed00` | 1 | 306 added, 6 removed | A fresh review found no bug. Small changes are in work: neutral names in the test data, fewer tests, and a paragraph in the docs |
| 8 | `feat/cluster-api-provider-podvm` | `0e3453ef` | 21 | 10,494 added, 9 removed | Five new commits, on the fork since 2026-11-28: the provider makes the Service of the control plane endpoint, the controller chart grants the rights, samples, and an install text that works. A fresh review found no must fix. Its smaller points are in work |
| 9 | `feat/podvm-node-image` | `9164f2f0` | 3, on top of branch 8 | 893 added, 2 removed | Not ready. The image builds, and it has not run in a pod. A fresh review found one fault in the entry point (it formats a volume when the check of the volume fails for another cause) and one in the bootstrap program (a file mode with no quotes is read wrong), and the README holds numbers that only the lab has. In work |
| 10 | `fix/agent-kill-child-cgroups` (Kata) | `e0f5597` | 1 | 161 added, 6 removed | Ready |

"Ready" means that the commits are final in content. After the rework, all branches are built together again and the lab tests run again. This page gets the result.

In work on 2026-11-28: branches 7, 8 and 9 get the points of the fresh reviews, so these three tips change again. Branch 5 got its points at 08:05. One more branch is in work and is not on the fork yet: `feat/podvm-deploy-path`, a deploy path of the repository with the pod provider.

Before a pull request, each branch still needs these things. They are rules of the repository (`CONTRIBUTING.md`, `docs/pull-request-triage.md`):

- A rebase on the current upstream main, and the signature of Davanum on the commits.
- An issue that the pull request links. For a bug fix the issue can be opened with the pull request. For a new feature or a change in behavior the issue must be agreed before the work starts. That applies to branches 5 to 9. No issue exists yet.
- A note in the pull request that an AI tool wrote a large part of the change. The author writes that note himself.
- The repository merges by squash. Each pull request becomes one commit on main, and only the title of the pull request is checked. The split into commits helps the reviewer only.

## The order

1. Branches 1, 2 and 3 are bug fixes for faults that are on main today. Each stands alone and helps NVKE with or without the rest. They can go first, in any order.
2. Branch 4 is the decision record. It goes early, so reviewers of the rest have the reason.
3. Branches 5, 6 and 7 are general changes in the controller API, the node agent and a controller client. Branch 5 has 185 lines of hand-written code, in a diff of 1,289 added lines in 30 files.
   - Branch 6 and branch 1 each add a field at the end of the same struct of the agent. The second one to merge needs a small rebase.
   - Branch 7 acts for these clusters only together with branch 5.
4. Branch 8 is the provider. It needs branch 5 to be useful, and branch 9 for its node image.
5. Branch 9 stacks on branch 8.
6. Branch 10 is for another project and has no order with the rest.

## The integration branch

https://github.com/dims/dsx-nvke/tree/integration/control-plane-kata-pods

- What it is: the commits of branches 1 to 7 and of branch 9 (which brings branch 8), picked in the order above onto the main commit `d625fcfa`. It has no code of its own. Tip `e62ddab5`, 41 commits.
- What it is for: one tree to build the agent, the controller, the simulator, the provider and the node image from, for a person who wants to try the feature. It is not for a pull request and not for review.
- One place differs from the branches: branch 1 and branch 6 each add a field at the end of the same struct in `agent/internal/agent/agent.go`. The integration branch has both fields. Each other file that a branch changes is the same as in that branch.
- It is built again after each change of a branch, so its history is rewritten. Do not base work on it.
- Check at 08:05 on 2026-11-28: `make build` passes for all modules, and the tests of the agent module, of the provider module and of the two controller packages that the endpoint branch changes most pass.
- Kata Containers has its own integration branch, because the guest needs two changes of the Kata agent: https://github.com/dims/kata-containers/tree/integration/control-plane-kata-pods (tip `96a8d905b`). It is Kata 4.4.0 plus the commit of branch 10 and a backport of the open upstream pull request 13627 of another author, which lets an exec work after systemd starts in the container.

## What each branch does

### 1. `fix/agent-upload-certs-config`

https://github.com/dims/dsx-nvke/tree/fix/agent-upload-certs-config

- `23d61df4` fix(agent): build the upload-certs config on every control plane node
  - The fault: the agent gave `kubeadm init phase upload-certs` a config only on the node that ran `kubeadm init`, and only while a file in `/tmp` from that run existed. Since kubeadm 1.33.12, 1.34.8, 1.35.5 and 1.36.1 (kubernetes/kubernetes#138449) that step talks to the local API endpoint, and with no config kubeadm takes the address of the default route interface. When the node address is on another interface, no new control plane node can join after the first node is gone or was started again.
  - The change: on each control plane node the agent builds the config from the annotation of the API server manifest and from the `kubeadm-config` ConfigMap. The code that deleted the old file in `/tmp` is gone, because nothing reads that file any more.
  - Also new: the call now fails with `FailedPrecondition` before kubeadm runs when the agent cannot read the API server manifest or the ConfigMap, and the agent runs one such call at a time on a node. The step no longer takes a `certificateKey` from an init config of the caller.
  - Proof: unit tests, a check with kubeadm 1.36.4, and the lab. A replace of the first node and a rollout of three nodes pass, and all 10 join workflows completed at the first attempt. The lab ran the form before the small changes of 2026-11-28.

### 2. `fix/agent-encryption-join-config`

https://github.com/dims/dsx-nvke/tree/fix/agent-encryption-join-config

- `df409c97` fix(agent): stop writing kubeadm-config when encryption is turned on
  - The fault: when etcd encryption is turned on for a cluster that exists, the agent rewrites the `kubeadm-config` ConfigMap and replaces the whole API server section. A type check on the parsed YAML always fails, so the code starts from an empty section. In the lab 16 flags and 3 volumes were lost, and the one volume that the agent wrote names a file that no code makes. After that no new control plane node can join. Only the node that ran `kubeadm init` writes the ConfigMap, so the fault needs that node in the cluster at that time.
  - The change: the agent no longer writes the ConfigMap in this call. The controller already merges the two encryption flags and one volume into the section at the end of the same workflow (`MergeEncryptionIntoClusterConfiguration`), and it keeps the rest. So one writer stays, and the fix is a delete.
  - Proof: a unit test that the call does not touch the ConfigMap. The controller merge alone, run on the document that kubeadm 1.36.4 stores, gives byte for byte the document of the first form of the fix. The lab ran the first form (a merge in the agent, 562 added lines), not this one. The lab test on the final branches covers it.
  - Limit: if the workflow fails before its last step, the ConfigMap has no encryption settings until the workflow runs again. A control plane node that joins in that time gets an API server with no encryption settings. Today that join fails. A cluster whose first node was replaced already behaves this way. It is a gap in the controller, for a separate issue.
  - Not covered: a cluster that already lost its settings needs a repair that this commit does not do. A cluster with encryption from its creation does not have the fault.
  - Davanum chose this form over the first one on 2026-11-28. The first form is kept as a patch file in the notes.

### 3. `fix/nico-sim-wait-for-systemd`

https://github.com/dims/dsx-nvke/tree/fix/nico-sim-wait-for-systemd

- `7bf172e6` fix(nico-sim): wait for systemd before simulated cloud-init commands
  - The fault: in its container form the NICo simulator runs the start commands of a machine right after the container starts, before systemd can take commands. A `systemctl` command then fails, the start status stays at error, and the node never joins. In the lab one worker never joined for this cause. In three of the first four worker starts systemd was not ready when the commands started.
  - The change: the simulator waits until systemd has its control socket, with a limit of 60 s.
  - Proof: unit tests, and 8 of 8 worker starts in the lab with no wait in the request.

### 4. `docs/adr-control-plane-nodes-as-kata-pods`

https://github.com/dims/dsx-nvke/tree/docs/adr-control-plane-nodes-as-kata-pods

- `26828722` docs(adr): propose control plane nodes as Kata pods
  - One proposed architecture decision record, `docs/adrs/20261127-control-plane-nodes-as-kata-pods.md`, with its row in `docs/README.md`.
  - It records the decision (each control plane node as one Kata pod, through a new provider), the parts that the lab settled, the consequences with the limits of the lab, and the options that lost.
  - Corrected at 23:35 on 2026-11-27: the lab had two machines and its scripts are not in the repository, the node image is built in the provider module, and two more consequences are named (the node identity comes from a join token, and a reboot needs one controller setting).

### 5. `feat/control-plane-endpoint`

https://github.com/dims/dsx-nvke/tree/feat/control-plane-endpoint

The branch adds one optional field to the cluster create request, `controlPlaneEndpoint`. A cluster with the field uses that address as its API endpoint and gets no kube-vip. The address belongs to a load balancer outside the cluster.

The eight commits below hold the behavior of the three commits that the lab ran, in a smaller form. Two passes on 2026-11-27 and 2026-11-28 took out rewording and repeated tests and put in the points of a fresh review. The lab has not run this form yet.

- `92867b3e` refactor(controller): ask one cluster method at each control-plane endpoint gate (30 lines of code, 30 of tests)
  - No change of behavior. Each place that asks "does this cluster have a stable API address" now calls one method.
- `256d400b` feat(controller): add controlPlaneEndpoint to the cluster API schema (50 lines of spec, the rest is regenerated code)
  - The OpenAPI spec with the new field, and the two generated files. Seven sentences that said an operation requires the VIP field now name both fields, and the list of reject reasons of the create request has the two new ones. A reviewer reads the spec and skips the generated files.
- `5ce68089` feat(controller): store controlPlaneEndpoint in the clusters table (38 lines of code, 53 of tests)
  - The database column, its migration and the model.
- `67cdfc99` feat(controller): count controlPlaneEndpoint as a stable endpoint at each gate (7 lines of code, 105 of tests)
  - The one method of the first commit now also says yes for a cluster with the field.
- `67133016` feat(controller): check controlPlaneEndpoint on cluster create (86 lines of code, 93 of tests)
  - The request checks: the form of the address, no IPv6, an IPv4 host outside the pod and service networks (a DNS name is not checked), and not together with the VIP field.
- `463544f1` feat(controller): use controlPlaneEndpoint for kubeadm init (15 lines of code, 145 of tests)
  - `kubeadm init` gets the address as its control plane endpoint. The branch has no kube-vip code of its own: a cluster with the field cannot have a VIP, and the kube-vip step that exists does nothing for a cluster with no VIP. One test holds that rule.
- `8c3f6f37` feat(controller): accept controlPlaneEndpoint on cluster create (9 lines of code, 183 of tests)
  - The create request stores the value and returns it.
- `120b0ff2` docs: describe controlPlaneEndpoint for workload clusters (23 lines)
  - The guide pages say what the endpoint must do: it exists before the request, it forwards TCP to port 6443 of each control plane node whose API server is ready, each node and the NVKE controller can reach it, and NVKE does not take a node out of it before a restart of the API server or etcd there.
- Proof: each commit builds and passes all controller tests with no test cache (76 packages), and `make generate` and `make lint` are clean at each commit. The API check against `controller/api/v0.0.71` finds 14 additive changes and no breaking one.
- Known, for the text of the pull request: no end to end test creates a cluster with the field, NVKE does not check that the endpoint works, the SQL of the migration has no test, and the site bootstrap of nvkectl and the `NVKECluster` resource cannot set the field yet (a request file through `nvkectl create cluster -f` passes it). When the endpoint must work is stated from how kubeadm uses it, and no test of the repository proves it.

### 6. `feat/agent-endpoint-health-gate`

https://github.com/dims/dsx-nvke/tree/feat/agent-endpoint-health-gate

The need: before an operation that stops etcd or the API server on a node, the agent takes the node out of kube-vip. A node behind a load balancer that it does not run had nothing like that, so clients stayed connected to it.

- `b401e09d` feat(agent): add a control plane endpoint health gate (255 lines of code, 489 of tests)
  - The gate itself. Before the operation the agent writes a gate file, which the health check of the load balancer reads. It waits a settle time, closes the open connections of remote clients, and checks that no new one arrives. It removes the file when the caller asks for the restore, or at the end of a defragmentation. The gate file names the flow that closed it.
- `90f7efd5` feat(agent): open or hand off a gate that an etcd defrag left closed (35 lines of code, 174 of tests)
  - The etcd defrag withdraws the node by itself. If it stops halfway, the agent opens the gate at its next start, or hands the gate to the caller when the node must stay out of service.
- `8ba04781` feat(agent): add the control plane endpoint gate flags (49 lines of code, 55 of tests)
  - Three agent flags: the gate file, the interface on which the connections of the load balancer arrive, and the settle time. With no flag the agent takes the same steps as today. One detail differs: an error of the restore is wrapped in another type, with the same text.
- `edddaff0` docs(agent): describe the control plane endpoint gate (50 lines)
  - Two pages that would be wrong without it, and the new flags in the README of the agent. The README names the three kernel options that the socket close needs (`INET_DIAG`, `INET_TCP_DIAG`, `INET_DIAG_DESTROY`): without them the close does nothing and reports no error.
- The controller and the gRPC API have no change.
- Proof: 55 table cases in the unit tests, and the lab. A forced certificate renewal had 510 of 510 calls answered and no worker disturbed. Without the gate it was 587 of 593, and a worker was not ready two times. The lab ran the commit before the rework. The test with the reworked commits is still to come.
- Known, for the text of the pull request: no test covers the one line that passes the three flags to the server (the same gap exists on main for another flag), the settle time has no upper limit, and on a node with no kube-vip two log lines and one error still say "VIP".

### 7. `feat/capi-failure-domain-unavailable`

https://github.com/dims/dsx-nvke/tree/feat/capi-failure-domain-unavailable

- `23c1ed00` feat(controller): re-place a pending control-plane node of a template-backed provider
  - The need: NVKE moves a control plane node that waits 15 minutes in a failure domain with no room. A provider that comes through a machine template had no way to say that a domain is full, so such a node waited with no end.
  - The change: the controller reads the reason `FailureDomainUnavailable` from the machine of such a provider. The rule itself has no change. The branch has only the reading side. The provider of branch 8 sets the reason.
  - Proof: unit tests and the lab. A rollout with a full host node ended by itself.

### 8. `feat/cluster-api-provider-podvm`

https://github.com/dims/dsx-nvke/tree/feat/cluster-api-provider-podvm

The branch adds a new Cluster API infrastructure provider module beside `cluster-api-provider-provisioned`, with the kinds `PodVMCluster`, `PodVMMachine` and `PodVMMachineTemplate`. For each machine it makes one Kata pod, two raw block volumes and a copy of the bootstrap data.

Of the 10,494 lines, about 3,300 are hand-written code, 4,400 are tests, 1,600 are generated, and the rest is manifests, samples and docs. Each commit builds and passes the tests of the module. The first 15 commits have the Go code that the lab ran: only comments and the name of one test case differ. The five commits after them are new, on the fork since 2026-11-28, and have not run in a cluster.

- `aebec5dc` feat(podvm): add the module of the pod VM Cluster API provider (11 lines of code, the rest is module files)
  - The Go module, its Makefile, and its entry in the workspace, the coverage registry and the docs.
- `8583351b` feat(podvm): add the PodVMCluster API type (245 lines of code, 437 generated)
  - The cluster object: the namespace for the pods, the address range for the node addresses, and the failure domains in its status.
- `1bad7ee4` feat(podvm): add the PodVMMachine API type and its template (323 lines of code, 45 of tests, 778 generated)
  - The machine object and its template: the node image, the runtime class, the sizes of the pod and of its two volumes, and the provider ID form.
- `855441fb` feat(podvm): add the address range arithmetic (147 lines of code, 283 of tests)
  - How the provider picks a free address from the range, and how it derives a fixed hardware address from it.
- `f8a01116` feat(podvm): add the cluster controller (428 lines of code, 463 of tests)
  - It checks the cluster object, publishes one failure domain for each host node, and reports ready.
- `707df0c0` feat(podvm): add the machine controller up to the address (308 lines of code, 326 of tests)
  - It waits for the Machine, the cluster and the bootstrap data, then gives the machine a fixed address that it keeps for its whole life.
- `f613f5b4` feat(podvm): build the pod and the volume claims of a machine (316 lines of code, 195 of tests)
  - The pod specification, which is the contract with the node image: one privileged container, two raw block devices, the bootstrap data as a file, the address on a second interface, and the probes.
- `4be181b2` feat(podvm): make the pod and report the machine (369 lines of code, 501 of tests)
  - It makes the claims, the copy of the bootstrap data and the pod, and reports the address only when the node agent in the pod answers. A pod that is gone is made again with the same name, volumes and address.
- `ba441faf` feat(podvm): delete the objects of a machine (127 lines of code, 287 of tests)
  - The delete with a finalizer: the pod, the claims and the copy of the bootstrap data go.
- `39a7b8b4` feat(podvm): replace a pod that ended and answer a reboot request (86 lines of code, 327 of tests)
  - A pod that ended is deleted and made again the same way. A reboot request of NVKE is answered one time.
- `255be6ac` feat(podvm): set the provider ID on the Node of the workload cluster (267 lines of code, 524 of tests)
  - The provider writes the provider ID on the Node of the new cluster, and waits when that cluster does not answer yet.
- `e6802ac3` feat(podvm): end a run with no error when the object is gone (105 lines of code, 459 of tests)
  - A machine that is deleted in the middle of a run gives no error line.
- `235f93f5` feat(podvm): report a pod that the scheduler cannot place (79 lines of code, 323 of tests)
  - The reason `FailureDomainUnavailable` that branch 7 reads, and `PodUnschedulable` for a machine with no failure domain.
- `3e798248` feat(podvm): add the manager program and its manifests (105 lines of code, 252 of manifests)
- `7fc4d539` docs(podvm): add the README of the pod VM provider (376 lines)
- `72d61a36` feat(podvm): add the controlPlaneService field to PodVMCluster (43 lines of code, 75 generated)
  - One optional field, `spec.controlPlaneService`, with the annotations, the load balancer class and the traffic policy of the Service. It cannot be added, removed or changed after the object exists. With no field the provider behaves as before.
- `f9054f2b` feat(podvm): make the Service of the control plane endpoint (338 lines of code, 422 of tests)
  - With the field, the provider makes one LoadBalancer Service `<cluster-name>-control-plane` in the pod namespace, which selects the control plane pods of the cluster on port 6443. The cluster reports ready only when the load balancer gave an address. The provider removes the Service with the cluster. A Service of that name that the provider did not make is a conflict and stays untouched. Before this commit a person made that Service by hand for each cluster.
- `038a4397` feat(chart): grant the NVKE controller rights for the pod VM kinds (84 lines)
  - A new chart value `capi.rbac.podvm`, off by default, with the template, the check of the chart assertions and a section in the docs page on infrastructure providers.
- `4a0ba731` feat(podvm): add sample objects and a sample cluster request (168 lines of samples, 256 of tests)
  - Four files under `config/samples/`: the cluster object, the machine template, the network attachment and an NVKE cluster request. A test checks each object against the schema of the generated CRD.
- `981d5117` docs(podvm): say what an install and the NVKE controller need (69 lines)
  - An Install section that builds and pushes an image that a cluster can pull, one list of what the host cluster needs, and what the NVKE controller needs (three chart values, and three behaviors that are separate changes).
- `0e3453ef` ci: add the podvm provider module to the module checks (50 lines in 8 files)
  - The lint, generate check and build workflows, the labeler, a comment in the Dependabot file, the pull request template, the regenerate skill and the tables of `AGENTS.md`. It is apart, so it can be dropped.
- Proof: 92 test functions with 184 subtests. Each lab test of phase 2 and phase 3 ran the code of the first 15 commits. The author broke 14 rules of the Service code one at a time, and a test failed each time.
- Not in the branch: the wiring of a new provider into the image and release workflows, the code owners and nvkectl. That needs decisions of the maintainers. No workflow publishes an image of the provider.
- Size: the branch is one pull request of about 10,500 lines, and the repository merges by squash. A fresh review proposes a cut into five pull requests along the commits. That is open, for Davanum.
- Known: three checks pass at the tip and fail at commits in the middle of the series. Two are checks of the repository root (the coverage registry at the first two commits, and `go mod tidy` before the manager commit). The third is `make generate-check` of the module at the first commit, where no API package exists yet.

### 9. `feat/podvm-node-image`

https://github.com/dims/dsx-nvke/tree/feat/podvm-node-image

The branch adds the node image for the pods, inside the provider module at `cluster-api-provider-podvm/node-image/`. The provider of branch 8 cannot be used without it. The branch sits on top of branch 8, and the three commits below are its own.

- `83101bbf` feat(podvm): add the bootstrap program of the node image (248 lines of code, 149 of tests, two units)
  - A small program that applies the bootstrap data of NVKE in the pod: it writes the files and runs the commands that a machine would get from cloud-init. Two systemd units run it, one early and one after the network is up.
- `3e30c0f2` feat(podvm): add the node image for pod machines (276 lines in 9 files)
  - The Dockerfile on top of the container node image of the repository, the entry point of the pod, the readiness program that the provider's probe runs, the agent flags of branch 6, and a check that Open vSwitch uses the datapath of the guest kernel. Also the build script `build-image.sh`, the link for the machine ID, the step that installs the CNI image package at build time with its helper `build-ctr`, and one exempt line in `hack/base-image-check.sh`, which is outside the module.
- `9164f2f0` docs(podvm): describe the node image and its guest kernel options (180 lines)
  - The README with the contract between the provider and the image, what Kata and the host cluster must give, and the two fragment files with the 11 options that the guest kernel needs.
- Proof so far: the image builds with no network on top of the base image, and the checks of the module and of the repository root pass.
- Open: this image is a shorter form of the image that the lab ran, and it differs in small points of behavior. It has not run in a pod yet. The lab test on the final branches covers it.

### 10. `fix/agent-kill-child-cgroups` (Kata Containers)

https://github.com/dims/kata-containers/tree/fix/agent-kill-child-cgroups

- `e0f5597` agent: kill the init process and child cgroups of a container
  - The need: a container that runs systemd keeps processes in child cgroups. The Kata agent did not end them when the container was killed.
  - The change: the agent kills the init process and the child cgroups of the container.
  - The lab ran each test with it. A second change of the lab, for exec in such a container, belongs to an upstream pull request of another author and is not on this branch.
