# Branches to share: NVKE control plane nodes as Kata pods

Last update: 2026-11-28, 08:47 local time. Each tip in the state table was the tip of its branch on the fork at that time (fetched at 08:47).

This page lists the only branches that the larger team needs. Each of the eleven is meant to become one pull request. No pull request is open yet. One more branch, `integration/control-plane-kata-pods`, holds the commits of the ten NVKE branches together, for a person who wants to try the feature. It is not for a pull request. Every other branch on the two forks is lab material and is not for sharing.

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
| 7 | `feat/capi-failure-domain-unavailable` | `cdc69b8d` | 1 | 252 added, 21 removed | Ready. The small changes of the fresh review are in since 2026-11-28, 08:28: neutral names in the tests, fewer tests, and a paragraph in the docs. The rule itself is the code that the lab ran |
| 8 | `feat/cluster-api-provider-podvm` | `08379976` | 22 | 10,943 added, 9 removed | The points of the fresh review are in since 2026-11-28, 08:28. Six commits are newer than the lab run: the provider makes the Service of the control plane endpoint, the controller chart grants the rights, samples, and docs. They have not run in a cluster |
| 9 | `feat/podvm-node-image` | `27806a56` | 3, on top of branch 8 | 1,253 added, 2 removed | The points of the fresh review are in since 2026-11-28: a volume is formatted only when two checks agree that it is empty, a file mode is read as cloud-init reads it, and the README has no lab number and has the full kernel build command. The image builds. It has not run in a pod yet, and that run is the open point |
| 10 | `fix/agent-kill-child-cgroups` (Kata) | `e0f5597` | 1 | 161 added, 6 removed | Ready |
| 11 | `feat/podvm-deploy-path` | `b4bbfa94` | 12, on top of branch 9 | 1,846 added, 2 removed | New on 2026-11-28. Nothing of it ran on a cluster yet: every check so far is a static check. The first run from an empty machine is the open point |

"Ready" means that the commits are final in content. After the rework, all branches are built together again and the lab tests run again. This page gets the result.

State on 2026-11-28: each branch has the points of its fresh review. No agent rewrites a branch now. Still open for all: the first run of the final forms on a cluster, from an empty machine, with the deploy path of branch 11.

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
7. Branch 11 stacks on branch 9 and goes last. Its last commit also needs branch 5 below it.

## The integration branch

https://github.com/dims/dsx-nvke/tree/integration/control-plane-kata-pods

- What it is: the commits of branches 1 to 7 and of branch 11 (which brings branches 8 and 9), picked in the order above onto the main commit `d625fcfa`. It has no code of its own. Tip `bba3c232`, 54 commits.
- What it is for: one tree to build the agent, the controller, the simulator, the provider and the node image from, with the deploy path and the kind host cluster scripts, for a person who wants to try the feature. It is not for a pull request and not for review.
- One place differs from the branches: branch 1 and branch 6 each add a field at the end of the same struct in `agent/internal/agent/agent.go`. The integration branch has both fields. The README of the simulator has the lines of branch 3 and of branch 11, and the docs page on infrastructure providers has the lines of branch 7 and of branch 11. Each other file that a branch changes is the same as in that branch.
- It is built again after each change of a branch, so its history is rewritten. Do not base work on it.
- The guide for a first run is `try-it.md`, next to this page. It is written for a person outside the team who has only the two public forks. Nothing of it ran from start to end yet, and each step has a mark for what ran.
- Check at 08:30 on 2026-11-28: `make build` passes for all modules. The tests of the agent module and of the provider module pass, and so do the controller tests of the four packages that branches 5 and 7 change. The CLI test decodes both example requests of branch 11. The deploy list check, the docs check and the workspace check pass.
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
- Known, for the text of the pull request: no end to end test creates a cluster with the field, NVKE does not check that the endpoint works, the SQL of the migration has no test in the repository (the same migration file ran on PostgreSQL in the lab), and the site bootstrap of nvkectl and the `NVKECluster` resource cannot set the field yet (a request file through `nvkectl create cluster -f` passes it). When the endpoint must work is stated from how kubeadm uses it, and no test of the repository proves it.

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

- `cdc69b8d` feat(controller): re-place a pending control-plane node of a template-backed provider (52 lines of code, 196 of tests, 4 of docs)
  - The need: NVKE moves a control plane node that waits 15 minutes in a failure domain with no room. A provider that comes through a machine template had no way to say that a domain is full, so such a node waited with no end.
  - The change: the controller reads the reason `FailureDomainUnavailable` from the `Ready` condition of the machine of such a provider. The rule itself has no change. The branch has only the reading side: no provider in the repository sets the reason today, and the provider of branch 8 does. The docs page on infrastructure providers has the contract in one paragraph.
  - Proof: unit tests, one for each part of the rule, and the lab. A rollout with a full host node ended by itself. The lab ran the same rule. The tests were made smaller after it.

### 8. `feat/cluster-api-provider-podvm`

https://github.com/dims/dsx-nvke/tree/feat/cluster-api-provider-podvm

The branch adds a new Cluster API infrastructure provider module beside `cluster-api-provider-provisioned`, with the kinds `PodVMCluster`, `PodVMMachine` and `PodVMMachineTemplate`. For each machine it makes one Kata pod, two raw block volumes and a copy of the bootstrap data.

Of the 10,943 lines, about 3,350 are hand-written code, 4,650 are tests, 1,550 are generated, and the rest is manifests, samples and docs. Each commit builds, passes the tests of the module, and has a tidy `go.mod`. The first 15 commits hold the Go code that the lab ran, with the changes of a fresh review of 2026-11-28 in five of them. The six commits after them (16 to 21) are newer than the lab run and have not run in a cluster.

- `53c115fd` feat(podvm): add the module of the pod VM Cluster API provider (59 lines of code, the rest is module files)
  - The Go module, its Makefile, and its entry in the workspace, the coverage registry and the docs.
- `2d6a4bdc` feat(podvm): add the PodVMCluster API type (197 lines of code, 485 generated)
  - The cluster object: the namespace for the pods, the address range for the node addresses, and the failure domains in its status.
- `8115baca` feat(podvm): add the PodVMMachine API type and its template (335 lines of code, 45 of tests, 789 generated)
  - The machine object and its template: the node image, the runtime class, the sizes of the pod and of its two volumes, and the provider ID form. The image, the sizes and the volumes of a machine cannot change after it exists. A template can change, and the change reaches only new machines.
- `971fef12` feat(podvm): add the address range arithmetic (147 lines of code, 283 of tests)
  - How the provider picks a free address from the range, and how it derives a fixed hardware address from it.
- `41b5b325` feat(podvm): add the cluster controller (428 lines of code, 463 of tests)
  - It checks the cluster object, publishes one failure domain for each host node, and reports ready.
- `2e69aca0` feat(podvm): add the machine controller up to the address (311 lines of code, 369 of tests)
  - It waits for the Machine, the cluster and the bootstrap data, then gives the machine a fixed address that it keeps for its whole life. One worker does this work, and a comment says what a second one would break.
- `b2911c0f` feat(podvm): build the pod and the volume claims of a machine (318 lines of code, 195 of tests)
  - The pod specification, which is the contract with the node image: one privileged container, two raw block devices, the bootstrap data as a file, the address on a second interface, and the probes.
- `d78c3265` feat(podvm): make the pod and report the machine (389 lines of code, 625 of tests)
  - It makes the claims, the copy of the bootstrap data and the pod, and reports the address only when the node agent in the pod answers. A pod that is gone is made again with the same name, volumes and address. A create call that the API server rejects (a missing RuntimeClass, a pod security rule, a quota) shows as its own reason `CreateRejected` with the answer of the API server.
- `8345646f` feat(podvm): delete the objects of a machine (127 lines of code, 287 of tests)
  - The delete with a finalizer: the pod, the claims and the copy of the bootstrap data go.
- `e42e9594` feat(podvm): replace a pod that ended and answer a reboot request (86 lines of code, 356 of tests)
  - A pod that ended is deleted and made again the same way. A reboot request of NVKE is answered one time.
- `ec68acff` feat(podvm): set the provider ID on the Node of the workload cluster (281 lines of code, 571 of tests)
  - The provider writes the provider ID on the Node of the new cluster, and waits when that cluster does not answer yet. It no longer looks at that cluster once the Machine has its node reference, and one look has a limit of 5 seconds, so one cluster that does not answer cannot hold up the others for long.
- `aecf5029` feat(podvm): end a run with no error when the object is gone (105 lines of code, 459 of tests)
  - A machine that is deleted in the middle of a run gives no error line.
- `9c0a1b58` feat(podvm): report a pod that the scheduler cannot place (79 lines of code, 323 of tests)
  - The reason `FailureDomainUnavailable` that branch 7 reads, and `PodUnschedulable` for a machine with no failure domain.
- `6284c968` feat(podvm): add the manager program and its manifests (105 lines of code, 253 of manifests)
- `0f12634f` docs(podvm): add the README of the pod VM provider (390 lines)
- `b0df4373` feat(podvm): add the controlPlaneService field to PodVMCluster (43 lines of code, 75 generated)
  - One optional field, `spec.controlPlaneService`, with the annotations, the load balancer class and the traffic policy of the Service. It cannot be added, removed or changed after the object exists. With no field the provider behaves as before.
- `6669684c` feat(podvm): make the Service of the control plane endpoint (338 lines of code, 422 of tests)
  - With the field, the provider makes one LoadBalancer Service `<cluster-name>-control-plane` in the pod namespace, which selects the control plane pods of the cluster on port 6443. The cluster reports ready only when the load balancer gave an address. The provider removes the Service with the cluster. A Service of that name that the provider did not make is a conflict and stays untouched. Before this commit a person made that Service by hand for each cluster.
- `07bf5fd1` feat(chart): grant the NVKE controller rights for the pod VM kinds (84 lines)
  - A new chart value `capi.rbac.podvm`, off by default, with the template, the check of the chart assertions and a section in the docs page on infrastructure providers.
- `a233b56e` feat(podvm): add sample objects and a sample cluster request (188 lines of samples, 266 of tests)
  - Five files under `config/samples/`: the cluster object, the machine template, the network attachment, a storage class and an NVKE cluster request. A test checks each object against the schema of the generated CRD and that the files name each other.
- `ff01a195` docs(podvm): say what an install and the NVKE controller need (132 lines)
  - An Install section that builds and pushes an image that a cluster can pull, one list of what the host cluster needs (with the changed Kata agent for the exec probe), sections on the node network and on the block volumes, and what the NVKE controller needs (three chart values, and three behaviors that are separate changes).
- `69cca519` docs(podvm): show how to roll the control plane to a new image (37 lines)
  - The PATCH request that rolls the control plane nodes to a new machine template.
- `08379976` ci: add the podvm provider module to the module checks (50 lines in 8 files)
  - The lint, generate check and build workflows, the labeler, a comment in the Dependabot file, the pull request template, the regenerate skill and the tables of `AGENTS.md`. It is apart, so it can be dropped.
- Proof: 97 test functions with 188 subtests. Each lab test of phase 2 and phase 3 ran the code of the first 15 commits in its form before the review. The author broke 14 rules of the Service code and 8 rules of the review changes one at a time, and a test failed each time.
- Not in the branch: the wiring of a new provider into the image and release workflows, the code owners and nvkectl. That needs decisions of the maintainers. No workflow publishes an image of the provider.
- Size: the branch is one pull request of about 10,900 lines, and the repository merges by squash. A fresh review proposes a cut into five pull requests along the commits. That is open, for Davanum.
- Known: `make coverage-check` of the repository root fails at the first two commits, because the first test comes with the third. Each other check passes at each commit. `make lint-chart` did not run as one target, because the workstation has no kubeconform. Its other steps pass by hand. The rules that make three fields of a machine immutable have no test in the branch. Before the Machine has its node reference, one cluster that does not answer still holds the one worker for up to 5 seconds in each 35.

### 9. `feat/podvm-node-image`

https://github.com/dims/dsx-nvke/tree/feat/podvm-node-image

The branch adds the node image for the pods, inside the provider module at `cluster-api-provider-podvm/node-image/`. The provider of branch 8 cannot be used without it. The branch sits on top of branch 8, and the three commits below are its own.

- `1c921a41` feat(podvm): add the bootstrap program of the node image (286 lines of code, 237 of tests, two units)
  - A small program that applies the bootstrap data of NVKE in the pod: it writes the files and runs the commands that a machine would get from cloud-init. Two systemd units run it, one early and one after the network is up. It reads a file mode as cloud-init does and refuses a mode above 0777. On a later start it writes each file again that is not on the `/var` volume, so a file that the image also carries does not go back to the image content after a new pod.
- `e5a55f74` feat(podvm): add the node image for pod machines (388 lines in 11 files)
  - The Dockerfile on top of the container node image of the repository, the build script, the entry point of the pod, the readiness program that the provider's probe runs, the agent flags of branch 6 (they do nothing with a node agent that has no gate), and a check that Open vSwitch uses the datapath of the guest kernel.
  - `format-if-empty`: the entry point makes a filesystem on a volume only when `blkid` finds none and a read of the place of the ext4 superblock succeeds and finds none. Each other answer stops the start. The reason: `blkid` gives the same exit code for "nothing found" and for a read that fails, so its answer alone could erase `/var` or the etcd data after a passing fault.
- `27806a56` docs(podvm): describe the node image and its guest kernel options (302 lines)
  - The README with the contract between the provider and the image, the two commands that build the base image with their inputs, the full command that builds the guest kernel with the two fragment files (11 options), how the kernel reaches a host node and how a custom runtime of the `kata-deploy` chart and a RuntimeClass point at it, the two changes of the Kata agent that are in no release, and the chart value for the join token.
- Proof so far: the tests of the module pass, with tests for each point of the review, and the author broke the code in nine more ways and a test failed each time. The image builds with no network on top of the base image. The kernel build command of the README ran on the workstation and gave a kernel with the 11 options. That kernel did not boot in a test.
- Open: the image has not run in a pod. It is a shorter form of the image that the lab ran. The first run must show a cluster create, a replace of the first node and of a joined node on the same volumes, a worker, and a restart in place. The base image commands and the Kata chart values of the README are written and did not run.

### 10. `fix/agent-kill-child-cgroups` (Kata Containers)

https://github.com/dims/kata-containers/tree/fix/agent-kill-child-cgroups

- `e0f5597` agent: kill the init process and child cgroups of a container
  - The need: a container that runs systemd keeps processes in child cgroups. The Kata agent did not end them when the container was killed.
  - The change: the agent kills the init process and the child cgroups of the container.
  - The first lab runs used the stock agent and showed the fault. Each lab test after the fix ran with it. A second change of the lab, for exec in such a container, belongs to an upstream pull request of another author and is not on this branch.
  - Before a pull request: the contribution rules of Kata Containers ask the author to write the commit message and the summary of the pull request himself, and to disclose the help of an AI tool with a trailer in the commit message (`Assisted-By:` or `Generated-By:`). The commit has no such trailer, and an agent wrote its message. Davanum must do both himself.

### 11. `feat/podvm-deploy-path`

https://github.com/dims/dsx-nvke/tree/feat/podvm-deploy-path

The branch adds what a person needs, beyond the provider and its node image, to get a cluster with control plane nodes as Kata pods on a kind host cluster, in the forms that the repository already uses. Davanum chose the form on 2026-11-28: a deploy path like the one of the end to end tests. The branch sits on top of branch 9, and the twelve commits below are its own.

- `e2556b16` chore(deploy): copy the capnico-e2e deploy path as podvm-e2e (1,026 lines in 20 files)
  - A plain copy of the deploy path `controller/deploy/capnico-e2e/`, with no change. It is apart so that the next commit shows only what differs.
- `e2b703c0` feat(deploy): set the podvm-e2e deploy path for the pod VM provider (40 added, 17 removed)
  - The controller settings of the path: the provider list has `infra`, the NICo controllers are off, the chart grants the rights for the pod VM kinds, the node identity comes from a join token, a reboot goes straight to the provider, and OIDC is off. One condition of `controller/hack/ci/deploy-stack.sh` changes, so that the script installs this path.
- `f5483be1` feat(hack): add a kind host cluster for the pod VM provider (220 lines)
  - `controller/hack/podvm-kind/` with `up.sh`, `down.sh` and a kind config for four nodes. `up.sh` makes the node network and gives each kind node what Kata needs.
- `7b3c3096` feat(hack): install Kata with the podvm runtime class on the kind host cluster (65 lines)
  - The upstream chart `kata-deploy` with one custom runtime, `kata-podvm`. `up.sh` copies the guest kernel and the guest image into each kind node.
- `006838bd` feat(hack): install MetalLB on the node network of the kind host cluster (46 lines)
  - The load balancer for the Service that the provider makes, with its address pool on the node network.
- `d256a04a` feat(hack): give the kind host cluster block storage (74 lines)
  - The local static provisioner of the Kubernetes storage group in block mode, over loop devices, with a fixed number of volumes on each host node. A released volume is cleaned.
- `2567975d` feat(hack): start the NICo simulator with its workers on the node network (54 lines)
  - `up.sh sim` starts the simulator. A worker has one network, the node network.
- `36091f28` docs(hack): describe the run on the kind host cluster (184 lines)
  - The README of `controller/hack/podvm-kind/` with the whole run in six steps: build the guest kernel and the guest image, build the images, bring the host cluster up, install Cluster API and the provider, install the management plane, create a cluster. Then workers from the simulator, the clean up, and what is not covered.
- `4516f4f7` docs(operate): say how a provider outside the closed set is used (2 lines)
- `71f52bdd` docs(nico-sim): describe the attestation method and the reboot setting (6 lines)
- `56e3be69` docs(cli): add an example node pool of nico-mock workers for a pod VM cluster (48 lines)
- `b4bbfa94` docs(cli): add an example cluster with control plane nodes as pods (109 lines)
  - `cli/examples/podvm-cluster.yaml`. It uses the request field of branch 5. So the test that decodes the examples fails for this file on this branch alone and passes with branch 5 below it, as in the integration branch. The pull request of this branch comes after branch 5.
- Proof so far, static checks only: the repository checks pass at the tip (deploy lists, license headers, names, internal config, docs, shell lint, workflows), the controller chart renders with the settings of the path and differs from the render of `capnico-e2e` only in the four intended points, the deploy executor walks the ten items of the path in a dry run, and the Kata chart of 4.4.0 renders the custom runtime. The charts of MetalLB and of the storage provisioner were not rendered.
- Open: nothing of it ran on a cluster. These things run for the first time in the first run: the guest image build from the make target of Kata, the custom runtime of the Kata chart, MetalLB on the bridge, the provisioner on loop devices, the simulator as a process on the machine, `deploy-stack.sh` outside its test runner, the Service that the provider makes, a worker with one network, a new node that pulls its own images, and `nvkectl`.
- Open, for the product: with OIDC on, the provider needs the SPIFFE program and socket in its pod to reach a cluster, as the Cluster API controllers get them from `controller/deploy/k8s/capi-spiffe-exec-auth`. The path turns OIDC off, as the lab did. The provider is not an item of the path: it installs with `kubectl apply -k` before it, because no image of the provider is published. No CI lane uses the path yet.
