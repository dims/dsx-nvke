# Branches to share: NVKE control plane nodes as Kata pods

Last update: 2026-11-28, 15:55 local time. Each tip in the state table was the tip of its branch on the fork at that time (fetched at 15:55).

This page lists the only branches that the larger team needs. Each of the eleven is meant to become one pull request. No pull request is open yet. A twelfth branch, `feat/podvm-arm64`, held the fixes for arm64 while the first run on an arm64 machine went on. Its commits are in branches 9 and 11 since 2026-11-28, and the branch itself is an old copy. One more branch, `integration/control-plane-kata-pods`, holds the commits of the ten NVKE branches together, for a person who wants to try the feature. It is not for a pull request. Every other branch on the two forks is lab material and is not for sharing.

- NVKE branches are on the fork `dims/dsx-nvke` and go to `dsx-ai-factory/nvke`. All sit on the main commit `d625fcfa`. The fork has one version tag, `v0.24.0-beta.18`, since 2026-11-28. A build of the node agent takes its version from the nearest such tag, and the controller checks that version.
- The Kata branch is on the fork `dims/kata-containers` and goes to `kata-containers/kata-containers`.

## State

| # | Branch | Tip | Commits | Lines changed | State |
|---|---|---|---|---|---|
| 1 | `fix/agent-upload-certs-config` | `23d61df4` | 1 | 330 added, 66 removed | Ready. Made smaller after a fresh review, which found no bug. The smaller form is on the fork since 2026-11-28 |
| 2 | `fix/agent-encryption-join-config` | `df409c97` | 1 | 49 added, 59 removed | Ready in a new, small form: a delete in the agent, where the first form added 562 lines. Davanum chose it on 2026-11-28. It passed its first run in a cluster on 2026-11-28, in the encryption scenario of the try-out guide: encryption went on in a cluster with three control plane nodes, the stored kubeadm configuration kept each other setting, and three new control plane nodes then joined at the first attempt with the encryption settings. The scenario needed a second try for another cause: the fork had no version tag, so the controller refused the version of the node agent. The fork has the tag since 11:40 |
| 3 | `fix/nico-sim-wait-for-systemd` | `7bf172e6` | 1 | 195 added, 6 removed | Ready. One sentence of the commit message was corrected on 2026-11-28, the code is the same |
| 4 | `docs/adr-control-plane-nodes-as-kata-pods` | `26828722` | 1 | 66 added | Ready. Corrected on 2026-11-27 after a fresh read of the docs |
| 5 | `feat/control-plane-endpoint` | `120b0ff2` | 8 | 1,289 added, 475 removed | Ready. The must fix of the fresh review is in since 2026-11-28: the API reference names both fields. The lab has not run this form yet |
| 6 | `feat/agent-endpoint-health-gate` | `543bd409` | 6 | 1,420 added, 6 removed | Ready. In the first run the gate took each node out first in the replace, the rollouts and the encryption change, and no API call failed. The last step of a Kubernetes upgrade (`kubeadm upgrade apply` on one node) had no gate, and 2 of 742 calls failed there. Two new commits of 2026-11-28 close the gate around that step. With them a second run of the upgrade had each call answered on both architectures: 768 of 768 on amd64 and 732 of 732 on arm64 |
| 7 | `feat/capi-failure-domain-unavailable` | `cdc69b8d` | 1 | 252 added, 21 removed | Ready. The small changes of the fresh review are in since 2026-11-28, 08:28. The rule ran in the first run of the try-out guide on 2026-11-28: two times a control plane node waited in a domain with no room, and each time NVKE made a new node in another domain after about 16 minutes |
| 8 | `feat/cluster-api-provider-podvm` | `416010dc` | 26 | 11,445 added, 9 removed | Ran on two machines on 2026-11-28, in each scenario of the try-out guide: it made the Service, placed the pods, reported a full failure domain and cleaned up at each delete. No fault showed. One finding of the run is in since 15:19: three more fields of a `PodVMCluster` cannot change now, so no field of its spec can. The CRD rules have their first test |
| 9 | `feat/podvm-node-image` | `86da7dbd` | 9, on top of branch 8 | 1,307 added, 2 removed | The image ran as control plane pods on two machines on 2026-11-28, on amd64 with Cloud Hypervisor and on arm64 with QEMU: a first start, a second start on the volumes with no format, rollouts, encryption, an upgrade, and the gate in action. No fault showed. Six commits of 15:23 bring in the notes of those runs: the README for both architectures, each tool of the kernel build, where the agent version comes from, and the rescan of the node agent turned off in a pod. No pod has run an image of this tip yet: the last run on arm64 does that |
| 10 | `fix/agent-kill-child-cgroups` (Kata) | `e0f5597` | 1 | 161 added, 6 removed | Ready |
| 11 | `feat/podvm-deploy-path` | `266d8159` | 23, on top of branch 9 | 1,936 added, 2 removed | Ran on two machines on 2026-11-28. On amd64 all 13 set up steps and each of the ten scenarios passed, three set up steps after a small fix of this branch. A second pass then ran steps 7 to 13 in one go from the public tip with no fix, in 549 seconds. On arm64 the 13 steps passed at the first try. The README of the kind host cluster has the memory and disk numbers that the runs measured. The four commits that arm64 needs are in this branch since 15:23 (QEMU for the runtime class on arm64, a larger `/dev/shm` for a kind node there, and the README for both architectures) |
| 12 | `feat/podvm-arm64` | `56043234` | 6, on top of the old form of branch 11 | 70 added, 15 removed | No branch for a pull request. It was the holding place for what arm64 needs while the first run on arm64 went on. Since 15:23 on 2026-11-28 its six commits are in branch 9 (two) and in branch 11 (four), with one text corrected: the pages say now that they are tested on both architectures. The branch on the fork holds the old copies and can go when Davanum says so |

"Ready" means that the commits are final in content. After the rework, all branches are built together again and the lab tests run again. This page gets the result.

State on 2026-11-28: each branch has the points of its fresh review. Two first runs of the guide `try-it.md` are in work, each from the two public integration branches.

On the second lab machine (amd64): all 13 set up steps passed, and then each of the ten scenarios, not yet in one go. They are the first cluster from one request (three control plane nodes as Kata pods and one worker of the simulator, each Ready after 5 minutes and 37 seconds, with no step by hand), pod traffic between the nodes, a lost pod that comes back on its volumes, the replace of a control plane node, a rollout of the control plane to a new image, a rollout with a full failure domain, the delete of the cluster (no pod, no claim and no Service left after 96 seconds, and each volume free again after 121 seconds with no step by hand), etcd encryption turned on with a rollout after it, an upgrade of the Kubernetes version from 1.36.4 to 1.37.0, and workers from the simulator. In the replace and in the two rollouts the API answered each call through the shared address (445, 620 and 2,419 calls, one each second), and the health gate of branch 6 took each old node out of the Service first. With a full failure domain the provider of branch 8 reported the cause, and NVKE moved the node after about 16 minutes, through the client of branch 7. That was the first run in a cluster of the final forms of branches 6, 7, 8, 9 and 11. The run found four faults of the product so far, each in the README or a values file of branch 11, and each fix is on the fork. No fault of another branch showed. The encryption scenario did not pass at its first try, because the fork had no version tag. With the tag `v0.24.0-beta.18` on the fork and a cluster that was made again, it passed at 13:16. Encryption was on after 418 seconds, and the stored kubeadm configuration differed only by the two encryption flags and one volume. A rollout then replaced the three control plane nodes in 626 seconds: each new node joined at its first attempt, its API server had both encryption flags and the same 45 other flags as an old node, and a new Secret was stored encrypted. The API answered each call in both parts (414 and 615 calls). That was the first run in a cluster of the final form of branch 2. The upgrade passed at 13:30: NVKE replaced the three control plane nodes one after the other in 12 minutes and 44 seconds, each node has v1.37.0, and the cluster kept its encryption. In it the run found one gap in branch 6: the last step, `kubeadm upgrade apply` on one node, starts the API server of that node again with no gate file, and 2 of 742 API calls failed in the 8 seconds before the readiness probe took the pod out. A fix for the gate branch is in work. The worker scenario passed at 13:33 in 142 seconds: a new pool with two workers, the delete of a worker that NVKE replaced alone, and a reboot of a worker by a label. So each scenario of the guide has passed one time on amd64. The last four scenarios then ran one time in the order of the guide on one cluster (the upgrade, the workers, the full failure domain, the delete). The full failure domain scenario passed a second time at 14:02, in 26 minutes with one wait and 1,522 API calls with no failure, and the delete after it took 59 seconds. The clean up of the guide passed at 14:03: `down.sh` took 10 seconds and left no kind cluster, no container of the run, no loop device and no volume file. The run measured its needs: 36 GB of memory at the highest (25 GB above the idle machine) and about 110 GB of disk for the path of the guide at its fullest. A second pass from the public tip with the gate fix (`8c957317`) runs since 14:05. Its first part passed at 14:20: steps 7 to 13 of the set up in one go, in 549 seconds, from a clean clone with new node images. So each of the three steps that needed a fix in the first pass (7, 11 and 12) has one clean pass from a public tip. The first cluster of that pass passed at 14:26, with four nodes Ready after 6 minutes and 7 seconds and the node agent of the new tip in each node. It is the third cluster of the run, and the three took 5 to 6 minutes each. The upgrade of that pass passed at 14:42 with the gate fix: the gate file came before `kubeadm upgrade apply`, and 768 of 768 API calls were answered (740 of 742 without the fix). The delete and the clean up passed again after it. So the first run on amd64 is at its end, at 14:44: each of the 13 set up steps and each of the 10 scenarios passed, some at a second try, and no kind cluster and no loop device is left on the machine. Not run there: the whole path in one pass from one tip, because the tips moved as the fixes came in.

On an arm64 machine: the fixes that a reading showed were on branch 12 during the run, and they are in branches 9 and 11 now. All 13 set up steps of the guide passed there, each as written and at the first try, from the public tip, with no patch on the machine, no firewall rule of ours and no way around: the builds, the kind host cluster with `up.sh` in one go, a Kata check pod on QEMU with the Rust runtime, the provider, CAPNICo and the simulator, the management plane through the deploy path, and `nvkectl` against the API. It took 41 minutes from the first clone to the management plane. No commit beyond the six of the reading was necessary. The first cluster passed there too, at 13:14: one request gave three control plane nodes as Kata pods on QEMU and one worker of the simulator. The status was `Provisioned` after 2 minutes and 26 seconds, and each of the four nodes was Ready after 3 minutes and 47 seconds (5 minutes and 12 seconds on the amd64 machine, which is a virtual machine). The four points that nobody knew under QEMU hold: systemd runs in the guest with no failed unit, the two block volumes have direct I/O and etcd syncs in 3 to 4 milliseconds on average, the readiness probe each 2 seconds costs under 3% of one CPU, and a node takes 3.5 to 3.8 GB of `/dev/shm`. Scenarios 2 and 3 passed too: pod traffic between each pair of nodes, and a lost pod that came back on its volumes in 55 seconds with no format. Scenario 4 passed at 13:26: NVKE replaced a control plane node on the kind worker of the old node with no step by hand, and the API answered each of 311 calls while two control plane nodes left. Scenario 5 passed at 13:39: a rollout of the three control plane nodes to a new image in 526 seconds (630 seconds on amd64), with 484 API calls and no failure. So scenarios 1 to 5 passed on arm64, each at the first try, with no fault of the product and no commit beyond the six of the reading. Scenario 6 passed at 13:58: encryption was on after 414 seconds, a rollout then replaced the three control plane nodes in 463 seconds, and each check of the encryption fix gives on arm64 what it gave on amd64. Scenarios 8, 9 and 10 passed too, at 14:14, 14:17 and 14:21: the Kubernetes upgrade to 1.37.0 in 516 seconds (764 on amd64), workers from the simulator, and the delete in 61 seconds. So nine of the ten scenarios passed on arm64, each at the first try. The upgrade ran on the tip without the gate fix and gave the second measurement of that gap: 1 of 481 API calls failed, when the etcd of one node stopped in `kubeadm upgrade apply` while the node was still behind the shared address. The proof of the gate fix passed there at 14:55. With new node images from the tip with the fix, the first cluster passed again, and in the upgrade 732 of 732 API calls were answered. The gate file came after the plan, the endpoint left the Service 6.5 seconds later, and `kubeadm upgrade apply` started 38.6 seconds after that. The worker, which was not Ready for at least 14 seconds in the step without the fix, stayed Ready. The full failure domain scenario passed at 15:49, in 40 minutes with two waits: each time the provider gave the reason, the controller gave up on the node after 14 minutes and 59 seconds, and a new node was on another kind worker about 16 minutes after the reason first showed. The API answered each of 2,200 calls. The delete after it took 58 seconds, and the clean up left no loop device and no volume file of the run. So the first run on arm64 is at its end, at 15:53: each of the 13 set up steps and each of the 10 scenarios passed, each at the first try. As on amd64, it was not one pass from one tip: the scenarios ran over two clusters, and the second cluster had the node agent of a newer tip. One run of the whole guide in one pass, from the tip of now, follows on this machine.

The run reports are in the private notes of the lab.

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
8. Branch 12 is no part of the order any more. Its commits are in branches 9 and 11.

## The integration branch

https://github.com/dims/dsx-nvke/tree/integration/control-plane-kata-pods

- What it is: the commits of branches 1 to 7 and of branch 11 (which brings branches 8 and 9), picked in the order above onto the main commit `d625fcfa`. It has no code of its own. Tip `0ac93949`, 77 commits, built again at 15:23 on 2026-11-28 from the new tips of branches 8, 9 and 11. Against the tree that both machines tested (the tip `98c84fac` before it) it differs in 12 files, by the same lines as the branches do: the three new rules of the provider with their test, the node image changes, and two text lines of the kind host cluster README. No machine has run this tip yet. The last run on arm64 does that, as one pass of the whole guide.
- What it is for: one tree to build the agent, the controller, the simulator, the provider and the node image from, with the deploy path and the kind host cluster scripts, for a person who wants to try the feature. It is not for a pull request and not for review.
- One place differs from the branches: branch 1 and branch 6 each add a field at the end of the same struct in `agent/internal/agent/agent.go`. The integration branch has both fields. The README of the simulator has the lines of branch 3 and of branch 11, and the docs page on infrastructure providers has the lines of branch 7 and of branch 11. Each other file that a branch changes is the same as in that branch.
- It is built again after each change of a branch, so its history is rewritten. Do not base work on it.
- The guide for a first run is `try-it.md`, next to this page. It is written for a person outside the team who has only the two public forks. Each of its steps and scenarios passed on amd64 on 2026-11-28, and nine of ten scenarios on arm64, but not in one pass from one tip. Each step has a mark for how it ran.
- Check at 12:14 on 2026-11-28: `make build` passes for all modules, the CLI test decodes both example requests of branch 11, and the deploy list, docs, shell lint, license header and name checks pass. The first run of the guide on amd64 cloned this branch with no credentials, built each part from it, and made its first cluster from the tip `e6ff4e4b`. Against that tip the tree of now differs in five files, each for arm64 or for a text.
- Kata Containers has its own integration branch, because the guest needs two changes of the Kata agent: https://github.com/dims/kata-containers/tree/integration/control-plane-kata-pods (tip `96a8d905b`). It is Kata 4.4.0 plus the commit of branch 10 and a backport of the upstream pull request 13627 of another author (still open on 2026-11-28, as is the upstream issue 14062 for the fault of branch 10), which lets an exec work after systemd starts in the container.

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
  - Proof: a unit test that the call does not touch the ConfigMap. The controller merge alone, run on the document that kubeadm 1.36.4 stores, gives byte for byte the document of the first form of the fix. The lab ran the first form (a merge in the agent, 562 added lines), not this one.
  - Proof in a cluster, 2026-11-28, in the first run of the try-out guide on amd64 (`results/first-run.md`, scenario 6, second try). Encryption went on in 418 seconds for a cluster with three control plane nodes. The `ClusterConfiguration` before and after differs only by the two encryption flags and one volume. A Secret from before the change and a new Secret are both stored encrypted, and the API returns their values. Then a rollout replaced the three control plane nodes in 626 seconds. Each new node joined at its first attempt, its API server manifest has both flags and the same 45 other flags as an old node, and no join wrote the `ClusterConfiguration`.
  - The same proof on arm64, 2026-11-28 (`results/first-run-arm64.md`, scenario 6, first try): the change in 414 seconds, the rollout after it in 463 seconds, and each check gives the same result as on amd64. The `ClusterConfiguration` after the three joins is the same as right after the change, byte for byte.
  - Seen in that run, and not a fault: the volume has the name `enc` in the `ClusterConfiguration` (the controller writes it) and the name `encryption-config` in the manifest of a node that was there at the change (the agent writes it in place). The path is the same. A node that joins later has `enc`.
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
- `376e57a2` feat(agent): close the control plane endpoint gate around kubeadm upgrade apply (53 lines of code, 193 of tests)
  - The gap that the first run found. `KubeadmUpgradeApply` now takes the node out through the gate after `kubeadm upgrade plan` and before `kubeadm upgrade apply`, with the same helper as the graceful shutdown, and opens the gate when kubeadm returns, also on a failure. A node that cannot leave the load balancer does not start the apply.
  - The gate file names the call as its owner. So the repair at the start of the agent opens a gate that an interrupted call left closed, as it does for the etcd defragmentation.
  - On a cluster with one control plane node the gate stays open, because kubeadm reaches the cluster through the load balancer. The agent reads that as one voting member of etcd.
  - With no gate configured the call runs the same two commands as before. kube-vip is not withdrawn by this call, so a cluster with kube-vip keeps the behavior of main.
- `543bd409` docs(agent): describe the gate of kubeadm upgrade apply (22 lines)
  - The gate sections of the agent README and of the agent design page.
- The controller and the gRPC API have no change.
- Proof: 55 table cases in the unit tests, and the lab. A forced certificate renewal had 510 of 510 calls answered and no worker disturbed. Without the gate it was 587 of 593, and a worker was not ready two times. The lab ran the commit before the rework. The test with the reworked commits is still to come.
- First run in a cluster of the reworked commits, 2026-11-28 (`results/first-run.md`). In scenarios 4, 5, 6 and 7 the gate file came first each time, the pod was not ready 4 seconds later, and no API call through the shared address failed (445, 620, 414, 615 and 2,419 calls).
- A gap that the same run found, in scenario 8: the RPC `KubeadmUpgradeApply` has no gate. `kubeadm upgrade apply` starts etcd and the API server of one node again. The readiness probe took the pod out about 8 seconds after the first failed call, and 2 of 742 calls failed. Main has no protection for this step either, so it is no regression. The run on arm64 measured the same gap on the tip without the fix: 1 of 481 calls failed, in the seconds after the etcd of the node stopped. The fix is the two commits `376e57a2` and `543bd409`, on the fork since 14:02. Its unit tests are 11 new table cases, of which 10 failed before the fix, and the six checks of `agent/` pass. The run of the upgrade scenario with the new node image is the next bullet.
- Proof of the fix in a cluster, 2026-11-28, on amd64, in the second pass of the first run (`results/first-run.md`, `logs/p2-sc8-proof.log`). On the node that got the call: `kubeadm upgrade plan` ran with the gate open. Then the agent closed the gate, and the file held `kubeadm-upgrade-apply`. The pod was not ready and its endpoint had left the Service 6 seconds later. `kubeadm upgrade apply` started 40 seconds after the endpoint left, and the etcd of the node started again in it. The agent opened the gate when kubeadm returned, and one second later the endpoint was ready. The loop on the API had 768 answers and no failure. The upgrade took 785 seconds, 21 more than without the gate.
- The same proof on arm64, 2026-11-28, with the pods on QEMU (`results/first-run-arm64.md`). The gate file with `kubeadm-upgrade-apply` came 16 seconds after the plan started. The endpoint left the Service 6.5 seconds later. `kubeadm upgrade apply` started 38.6 seconds after that, and the etcd of the node began to stop 7 seconds into it. The gate file went in the same millisecond as the end of the call, and the endpoint was back 2.5 seconds later. 732 of 732 calls were answered (480 of 481 without the fix). The step took 140 seconds in the place of 95.
- What else the two runs on arm64 showed:
  - The worker was not Ready for at least 14 seconds in the step without the fix, and it stayed Ready with the fix. Its kubelet calls the shared address.
  - The Node of the step is not Ready for about 17 seconds in both runs. The kubelet of a control plane node calls the API server of its own node, so the gate cannot change that. No pod left the node.
  - On arm64 the API server container of the node does not stop in this step at all. Only the etcd of the node stops and starts.
  - The step ran on the first of the three new nodes in one run and on the newest in the other.
- A choice in that fix, for the reviewer: the agent closes the gate inside the call. Another way is that the controller wraps the upgrade step with the drain and restore calls, as it does for the certificate renewal. That way would also cover a cluster with kube-vip, which has the same gap on main, and it is a change of the controller on main. It is not done here.
- Notes from the reading of the gate code, not fixed: a stat error on a parked manifest at the start of the agent returns before the gate is opened. And the encryption and OIDC rollouts drain a node with no rule for a cluster with one control plane node, where the drain would take the only node out of the load balancer (not checked in a cluster).
- Known, for the text of the pull request: no test covers the one line that passes the three flags to the server (the same gap exists on main for another flag), the settle time has no upper limit, and on a node with no kube-vip two log lines and one error still say "VIP".

### 7. `feat/capi-failure-domain-unavailable`

https://github.com/dims/dsx-nvke/tree/feat/capi-failure-domain-unavailable

- `cdc69b8d` feat(controller): re-place a pending control-plane node of a template-backed provider (52 lines of code, 196 of tests, 4 of docs)
  - The need: NVKE moves a control plane node that waits 15 minutes in a failure domain with no room. A provider that comes through a machine template had no way to say that a domain is full, so such a node waited with no end.
  - The change: the controller reads the reason `FailureDomainUnavailable` from the `Ready` condition of the machine of such a provider. The rule itself has no change. The branch has only the reading side: no provider in the repository sets the reason today, and the provider of branch 8 does. The docs page on infrastructure providers has the contract in one paragraph.
  - Proof: unit tests, one for each part of the rule, and the lab. A rollout with a full host node ended by itself. The lab ran the same rule. The tests were made smaller after it.
  - Proof in the first run of the try-out guide, 2026-11-28: in a rollout with one full host node, the machine of the surge node had the reason `FailureDomainUnavailable` and its pod stayed Pending. NVKE deleted that node after 16 minutes and 13 seconds and made a new one on another host node. The same happened a second time in that rollout, and it ended with three new nodes after 42 minutes. The API answered 2,419 of 2,419 calls.
  - Seen in that run, for the controller and not for this branch: the node that NVKE makes after the wait can go to a host node that still runs an old control plane node and is full then, so one rollout can wait two times. At the end the control plane was uneven (two nodes on one host node, none on another), and the next rollout began with a wait again. The cause of that second wait is a rule of the controller on main: a domain that was full stays marked for 3 hours, also when its room is back, and a rollout then waits with no message when each other domain is marked or full.
- Proof in a cluster, 2026-11-28, both runs of the try-out guide (scenario 7, a full failure domain). The provider of branch 8 set the reason on its machine, and the controller read it through the client of this branch. It ran three times on amd64 and arm64, with one or two waits each. Each time the controller recorded the delete of the stuck node 14 min 59 s to 15 min 7 s after the reason first showed, and a new node was on another kind worker about 16 minutes after it. The API answered each call in each run (2,419, 1,522 and 2,200 calls).
- Seen in those runs, for the controller on main and not for this branch: after it gives up on nodes in two failure domains, a later rollout can wait up to 3 hours (issue draft C in the texts page, on hold by the word of Davanum).

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
- Proof: 103 test functions with 206 subtests at the tip (97 and 188 before the four commits of 15:19). Each lab test of phase 2 and phase 3 ran the code of the first 15 commits in its form before the review. The author broke 14 rules of the Service code and 8 rules of the review changes one at a time, and a test failed each time.
- Proof in a cluster, 2026-11-28, the first run of the try-out guide (still in work): the provider, installed from the source tree, made the first cluster. It made the Service 7 seconds after the request, waited for the address of the load balancer, and then reported the cluster as provisioned. Each machine became ready. Its log has no warning and no error. A server dry run shows that the API refuses a change of the pod namespace, of the address range and of the Service field, and for a machine a change of the image, the sizes and the volumes.
- Four commits of 2026-11-28, from a finding of the first run: a server dry run let three fields of a `PodVMCluster` with machines change.
  - `e5740dc7` test(podvm): run the rules of the CRDs about a change (396 lines)
    - The CEL rules of the two CRDs had no test. The new test runs the validators of the API server on each generated CRD: it fills in the defaults and runs the rules on an old and a new object. It has a case for each rule that existed. It costs three direct requirements of the module that only the test uses (`k8s.io/apiextensions-apiserver`, `k8s.io/apiserver`, `sigs.k8s.io/yaml`) and 24 indirect ones, at the versions that the controller modules use. `controller/k8s-apis` has the same kind of test with the same requirements.
  - `00743a0f` fix(podvm): refuse a change of runtimeClassName of a PodVMCluster
  - `6b030710` fix(podvm): refuse a change of networkAttachment of a PodVMCluster
  - `416010dc` fix(podvm): refuse a change of failureDomainLabelKey of a PodVMCluster
    - The reason is the same for the three. The provider makes the pod of a machine again after a lost pod and after a reboot request, from the cluster as it is then. So a changed field would reach the machines that exist one at a time, in no order, each on the volumes of its old pod: another runtime, another network, or a failure domain that no host node has. NVKE has no request that changes these fields, so a change could only be a direct edit.
    - The README has a new section "Fields that cannot change". For each new rule the author put the CRD of the commit before back, and the new cases failed.
    - Not proven: the three rules ran in the validators of the API server inside a Go test, not in a cluster. The last run of the guide on arm64 has a dry run for them.
- Not in the branch: the wiring of a new provider into the image and release workflows, the code owners and nvkectl. That needs decisions of the maintainers. No workflow publishes an image of the provider.
- Size: the branch is one pull request of about 10,900 lines, and the repository merges by squash. A fresh review proposes a cut into five pull requests along the commits. That is open, for Davanum.
- Known: `make coverage-check` of the repository root fails at the first two commits, because the first test comes with the third. Each other check passes at each commit. `make lint-chart` did not run as one target, because the workstation has no kubeconform. Its other steps pass by hand. The rules that make three fields of a machine immutable have a test since `e5740dc7`. Before the Machine has its node reference, one cluster that does not answer still holds the one worker for up to 5 seconds in each 35.

### 9. `feat/podvm-node-image`

https://github.com/dims/dsx-nvke/tree/feat/podvm-node-image

The branch adds the node image for the pods, inside the provider module at `cluster-api-provider-podvm/node-image/`. The provider of branch 8 cannot be used without it. The branch sits on top of branch 8, and the three commits below are its own.

- `53975ca3` feat(podvm): add the bootstrap program of the node image (286 lines of code, 237 of tests, two units)
  - A small program that applies the bootstrap data of NVKE in the pod: it writes the files and runs the commands that a machine would get from cloud-init. Two systemd units run it, one early and one after the network is up. It reads a file mode as cloud-init does and refuses a mode above 0777. On a later start it writes each file again that is not on the `/var` volume, so a file that the image also carries does not go back to the image content after a new pod.
- `f788d1e6` feat(podvm): add the node image for pod machines (388 lines in 11 files)
  - The Dockerfile on top of the container node image of the repository, the build script, the entry point of the pod, the readiness program that the provider's probe runs, the agent flags of branch 6 (they do nothing with a node agent that has no gate), and a check that Open vSwitch uses the datapath of the guest kernel.
  - `format-if-empty`: the entry point makes a filesystem on a volume only when `blkid` finds none and a read of the place of the ext4 superblock succeeds and finds none. Each other answer stops the start. The reason: `blkid` gives the same exit code for "nothing found" and for a read that fails, so its answer alone could erase `/var` or the etcd data after a passing fault.
- `f5ecf114` docs(podvm): describe the node image and its guest kernel options (302 lines)
  - The README with the contract between the provider and the image, the two commands that build the base image with their inputs, the full command that builds the guest kernel with the two fragment files (11 options), how the kernel reaches a host node and how a custom runtime of the `kata-deploy` chart and a RuntimeClass point at it, the two changes of the Kata agent that are in no release, and the chart value for the join token.
- Six commits of 2026-11-28, from the notes of the two runs:
  - `7f9d9331` docs(podvm): take the architecture of the machine in the node image builds
    - The README named `x86_64` for the kernel build and `amd64` for a bundle and two packages. It came from the old holding branch for arm64.
  - `844d0020` docs(podvm): say on which architecture the node image is tested
    - Kata 4.4.0 has `clh-runtime-rs` for amd64 only, and its Rust runtime has QEMU on arm64. The README says so, and that the image is tested on amd64 with `clh-runtime-rs` and on arm64 with `qemu-runtime-rs`, and the kernel build on x86_64 and on aarch64. It came from the old holding branch too, with the text on arm64 brought to the tested state.
  - `ef818e80` docs(podvm): name each tool of the guest kernel build
    - A C compiler, `make` and `patch` were missing in the list. Step 3 of the guide needed all three on both machines.
  - `77e33a9a` docs(podvm): say where the base image takes the agent version from
    - The build names the node agent with `git describe` and the `v*` tags. A clone with no tag gives a bare commit ID, and the etcd encryption change of the controller refuses such a version. The README gives `git fetch --tags` and the command that prints the version of the agent in the image. That was the cause of the first try of scenario 6 that did not pass.
  - `cacc84c8` feat(podvm): turn the mlx5 rescan of the node agent off in the node image
    - At its start the node agent can remove the PCI devices of a DPU and scan the bus again, for a machine whose DPU was not up in time. In a pod it logged seven error lines at each start, because `/sys` is read only there. A pod has its interfaces from the CNI before the agent starts and has no PCI device of a DPU, nothing reads the result of the rescan, and the repository already turns it off for its container nodes. So the image passes `--disable-mlx5-rescan`.
    - The drop-in of the agent flags has a new name, `units/zz-podvm-agent-flags.conf`, because it holds more than the gate flags now. The build keeps it in each case. It takes the three gate flags out when the node agent of the base image has no gate, and it stops at any other flag that the agent does not know.
  - `86da7dbd` docs(podvm): bring the node image README to the state of the first runs
    - Three lines said that no test runs the image in a pod, that no test installs Kata, and that arm64 is not tested. The runs made each of them wrong.
  - Checks at the tip: the tests, `make generate-check` and `make lint` of the module, the repository checks, an image build with no network, the flag step with two real node agents (one with a gate, one without), and `systemd-analyze verify` on the agent unit with the drop-in.
  - Not proven: the new drop-in in a pod. The check is the line "mlx5 rescan is disabled" in the journal of the node agent and no error line of the rescan. The last run on arm64 has it.
- Proof so far: the tests of the module pass, with tests for each point of the review, and the author broke the code in nine more ways and a test failed each time. The image builds with no network on top of the base image. The kernel build command of the README ran on the workstation and gave a kernel with the 11 options. That kernel did not boot in a test.
- Proof in a cluster, 2026-11-28, the first run of the try-out guide (still in work): the image ran as three control plane pods of the first cluster. Both volumes got their filesystem from `format-if-empty`, the two units ran (3 of 3 files written, the status `done`), systemd was up after 5 seconds with no failed unit, `kubeadm init` and two joins passed, the node agent runs with the three gate flags, and the exec readiness probe passes each 2 seconds. No fault showed.
- Open, in the same run: a second start of a pod on its volumes (no format, the same machine ID), a replace of the first node and of a joined node, a restart in place, and the gate in action. Not run at all: the Kata chart values of the README in the README's own words (the run used the values file of branch 11), a base image with no CNI image package, arm64.
- A note from that run: the node agent tried a rescan of network devices two times at its start and logged seven error lines, because `/sys` is read only in the pod. The commit `cacc84c8` turns the rescan off in the image.
- Proof in a cluster, 2026-11-28, both runs as a whole: the image ran on amd64 with Cloud Hypervisor and on arm64 with QEMU. A second start of a pod on its volumes showed no format, the same machine ID and `firstStart=false` on both. The replace of a node, the rollouts, etcd encryption and the Kubernetes upgrade passed with it, and the gate file took each node out of the Service first. On arm64 systemd in the guest is `running` with no failed unit, and etcd syncs in 3 to 4 milliseconds on the block volume with direct I/O.

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

- `a17dbd66` chore(deploy): copy the capnico-e2e deploy path as podvm-e2e (1,026 lines in 20 files)
  - A plain copy of the deploy path `controller/deploy/capnico-e2e/`, with no change. It is apart so that the next commit shows only what differs.
- `5aeda1f5` feat(deploy): set the podvm-e2e deploy path for the pod VM provider (40 added, 17 removed)
  - The controller settings of the path: the provider list has `infra`, the NICo controllers are off, the chart grants the rights for the pod VM kinds, the node identity comes from a join token, a reboot goes straight to the provider, and OIDC is off. One condition of `controller/hack/ci/deploy-stack.sh` changes, so that the script installs this path.
- `5fe9be5a` feat(hack): add a kind host cluster for the pod VM provider (220 lines)
  - `controller/hack/podvm-kind/` with `up.sh`, `down.sh` and a kind config for four nodes. `up.sh` makes the node network and gives each kind node what Kata needs.
- `faf2e9a7` feat(hack): install Kata with the podvm runtime class on the kind host cluster (65 lines)
  - The upstream chart `kata-deploy` with one custom runtime, `kata-podvm`. `up.sh` copies the guest kernel and the guest image into each kind node.
- `b0efd480` feat(hack): install MetalLB on the node network of the kind host cluster (46 lines)
  - The load balancer for the Service that the provider makes, with its address pool on the node network.
- `cace77c5` feat(hack): give the kind host cluster block storage (74 lines)
  - The local static provisioner of the Kubernetes storage group in block mode, over loop devices, with a fixed number of volumes on each host node. A released volume is cleaned.
- `147695be` feat(hack): start the NICo simulator with its workers on the node network (54 lines)
  - `up.sh sim` starts the simulator. A worker has one network, the node network.
- `ccb25fae` docs(hack): describe the run on the kind host cluster (205 lines)
  - The README of `controller/hack/podvm-kind/` with the whole run in seven steps, in the order in which a reader runs them: build the guest kernel and the guest image, build the images and `nvkectl`, bring the host cluster up, install Cluster API and the provider, install CAPNICo and start the simulator, install the management plane, create a cluster. Then the clean up and what is not covered. The try-out guide `try-it.md` follows it step by step. Writing that guide showed four gaps in this README, which are closed since 2026-11-28, 08:54.
- `19147e28` docs(operate): say how a provider outside the closed set is used (2 lines)
- `97874376` docs(nico-sim): describe the attestation method and the reboot setting (6 lines)
- `d219f6f2` docs(cli): add an example node pool of nico-mock workers for a pod VM cluster (48 lines)
- `da96f187` docs(cli): add an example cluster with control plane nodes as pods (109 lines)
  - `cli/examples/podvm-cluster.yaml`. It uses the request field of branch 5. So the test that decodes the examples fails for this file on this branch alone and passes with branch 5 below it, as in the integration branch. The pull request of this branch comes after branch 5.
- `dc3d3655` docs(hack): say where the tool versions for the kind host cluster are pinned (3 lines)
  - The README points at `make/tool-versions.mk` and `go.work`. Found by the first run.
- `259d957b` fix(hack): name the Cloud Hypervisor shim as the default shim of the Kata install (5 lines)
  - The values file for the Kata chart turned each shim off but the Cloud Hypervisor one and left the default shim of the chart, which is a QEMU shim. The installer of Kata refuses that, so the step `kata` of `up.sh` failed in the first run. The check is in the installer and not in the chart, so the static render could not show it.
- `b05ad46a` docs(hack): let the reader choose the local port of the API port forward (6 added, 2 removed)
  - A variable `API_PORT` in the README, because something on the test machine already listened on 8080.
- `6c3a033e` docs(hack): run install-capnico.sh through bash in the kind host cluster README (2 lines)
  - The script has no execute bit in the repository, so the README line stopped with "Permission denied" in the first run. The copy of the CAPNICo source now also stops when the module path is empty.
- `1845d583` docs(hack): build and load the profiles fixture image for the kind host cluster (README)
  - The deploy path names an image with the profiles fixture, as the path that it copies does, and the README had no step that builds and loads it. So the controller pod could not start in the first run. The static render could not show it.
- `edd4463f` docs(hack): say when the kind host cluster README shows the cluster as Provisioned (4 added, 1 removed)
  - The README said that the status comes when the nodes have joined. In the first run it came with the first control plane node, and the other nodes joined after it.
- `4dc1f142` docs(hack): give the measured memory and disk needs of the kind host cluster (6 added, 2 removed)
  - The README named 20 Gi of memory and no disk number. The first run measured both: 18 Gi above the idle machine for a cluster of three control plane nodes and one worker with the management plane, 25 Gi at the highest point of a rollout with three workers, about 85 G of disk for the builds, the images and one cluster, and about 12 G in the four kind nodes for each more node image.
- Four commits that arm64 needs, from the old holding branch, in this branch since 15:23 on 2026-11-28. Section 12 has what each one does.
  - `e88e9a85` docs(hack): build and load images for the architecture of the machine
  - `961c1d81` feat(hack): put the kata-podvm runtime on QEMU on arm64
  - `e222775a` fix(hack): give a kind node on arm64 a /dev/shm for QEMU guests
  - `266d8159` docs(hack): say on which architecture the kind host cluster is tested
    - The README says now that the page is tested on amd64 and on arm64.
- Proof by static checks: the repository checks passed at the tip `1845d583`, and the docs check and the name check at `edd4463f` (deploy lists, license headers, names, internal config, docs, shell lint, workflows), the controller chart renders with the settings of the path and differs from the render of `capnico-e2e` only in the four intended points, the deploy executor walks the ten items of the path in a dry run, and the Kata chart of 4.4.0 renders the custom runtime. The charts of MetalLB and of the storage provisioner were not rendered.
- Proof by the first run, 2026-11-28, its first part: all 13 set up steps of the guide passed on one test machine, from a clone of the public integration branch with no credentials. That covers the whole README of this branch up to the first cluster request, `up.sh` with each of its eight steps, and the deploy path `podvm-e2e` through `deploy-stack.sh`. These ran for the first time and passed: the guest image build from the make target of Kata, a pod on that guest image and on the guest kernel of branch 9, the custom runtime of the Kata chart, the storage provisioner on loop devices, the provider installed from the source tree, CAPNICo built from its public source, the simulator as a process on the machine, `deploy-stack.sh` outside its test runner, and `nvkectl` against the API with authentication on. Three steps passed only after a fix of this branch (the commits `259d957b`, `6c3a033e` and `1845d583`). `up.sh` ran in two parts, and one clean pass of the whole script comes at the end of the run.
- The first cluster request of the guide passed in that run, from the public tip with no local patch: `nvkectl create cluster` with the example of this branch gave three control plane nodes and one worker, each Ready after 5 minutes and 37 seconds. The Service that the provider makes had its address after 11 seconds. MetalLB announces the address on the node network. The worker of the simulator has one network. Each control plane node pulled images from a public registry by itself.
- Open, in the same run: the other nine scenarios, the clean up with a check for loop devices that stay, and one clean pass of steps 7 to 13 from the public tip in one go.
- Open, for the product: with OIDC on, the provider needs the SPIFFE program and socket in its pod to reach a cluster, as the Cluster API controllers get them from `controller/deploy/k8s/capi-spiffe-exec-auth`. The path turns OIDC off, as the lab did. The provider is not an item of the path: it installs with `kubectl apply -k` before it, because no image of the provider is published. No CI lane uses the path yet.

- Proof by the first run, 2026-11-28, the whole: on amd64 each of the 13 set up steps and each of the 10 scenarios of the guide passed (`results/first-run.md`). Steps 7, 11 and 12 passed in the first pass after a fix of this branch. A second pass then ran steps 7 to 13 in one go from a clean clone of the public tip, in 549 seconds, with a script that stops at the first failed step: `up.sh` with no argument 189 s, the Kata check 8 s, the image load 145 s, Cluster API and the provider 17 s, CAPNICo and the simulator 72 s, the deploy path 115 s, `nvkectl` 3 s. The clean up passed two times: `down.sh` took 10 seconds and left no kind cluster, no network of the run, no loop device and no volume file. On arm64 the 13 steps passed at the first try (`results/first-run-arm64.md`). Not run: the whole path in one pass from one tip, and a CI lane.

### 12. `feat/podvm-arm64` (its commits are in branches 9 and 11)

https://github.com/dims/dsx-nvke/tree/feat/podvm-arm64

The branch held what arm64 needs while the first run on arm64 went on. Since 15:23 on 2026-11-28 its six commits are in branch 9 (the two on the node image README) and in branch 11 (the four on the kind host cluster). The list below has their IDs in those branches. The branch on the fork still holds the old copies, and it can go when Davanum says so. This section stays as the record of the arm64 work and of its run. Nobody ran any part of this work on arm64 before 2026-11-28. A reading of the tree and of Kata Containers 4.4.0 showed seven places that assume amd64, and one of them is large: Kata 4.4.0 has Cloud Hypervisor with its Rust runtime for amd64 only, so on arm64 the runtime class sits on QEMU, which no test of this work ran before. Cloud Hypervisor stays on amd64, where each result so far is.

Each commit keeps what a reader on amd64 gets: the commands print and select the same on amd64 as before, and the Kata chart renders byte for byte the same with the amd64 values.

- `e88e9a85` docs(hack): build and load images for the architecture of the machine
  - The README of the kind host cluster built the controller image and the provider image for `linux/amd64` and loaded images for that platform. On arm64 two of these would build an amd64 image with no error. Now the platform is the one of the machine.
- `961c1d81` feat(hack): put the kata-podvm runtime on QEMU on arm64
  - A second values file for the Kata chart, which `up.sh` adds on arm64: the QEMU shim of the Rust runtime in the place of the Cloud Hypervisor one, with the same guest kernel, guest image and block device setting. The runtime class keeps its name, `kata-podvm`.
- `e222775a` fix(hack): give a kind node on arm64 a /dev/shm for QEMU guests
  - Under QEMU the memory of each guest is a file in `/dev/shm`, and Docker gives a container 64 MB there. On arm64 `up.sh` sets the limit to half of the memory, as a Linux machine has it. A kind node on amd64 stays as it was.
- `7f9d9331` docs(podvm): take the architecture of the machine in the node image builds
  - The README of the node image named `x86_64` for the kernel build and `amd64` for a bundle and two packages. Its home is branch 9.
- `266d8159` docs(hack): say on which architecture the kind host cluster is tested
- `844d0020` docs(podvm): say on which architecture the node image is tested
  - Both texts say now: tested on amd64 and on arm64. The first is in branch 11, the second in branch 9.
- Proof so far: checks on the workstation only, with no pull and no cluster. The repository checks pass at the tip.
- Proof on arm64 so far, 2026-11-28, on a real arm64 machine with KVM, from a clone of the public integration branch with no credentials: steps 1 to 8 of the guide passed, each as written and at the first try. A container reaches the internet with no firewall rule of ours. The guest kernel builds with all 11 options, and the guest image builds with the Kata agent of the Kata integration branch, each for the first time on arm64. Each image is for `linux/arm64`, and the node agent names a version. `up.sh` ran in one go: the installer of Kata accepted the two values files, and each kind node has the larger `/dev/shm`. The first Kata pod on arm64 ran on QEMU with the Rust runtime: the guest kernel 6.18.62 in the pod, an exec in 0.3 s, a pod delete in 1.5 s.
- What `/dev/shm` takes under QEMU, measured there: a pod takes memory there as its guest touches it, 395 MB for a pod of 6Gi at its start and at most the size of the guest. It is given back when the pod is gone. With the 64 MB of Docker not even a small pod could start.
- Steps 9 to 13 passed on arm64 too, each at the first try: the image load, Cluster API and the provider, CAPNICo built from its public source with the simulator as a process on the machine, the deploy path through `deploy-stack.sh` (each chart of the path has its images for arm64), and `nvkectl` against the API. So Part 1 of the guide has one clean pass from the public tip on arm64, in 41 minutes from the first clone to the management plane.
- Scenario 1 passed on arm64 at 13:14 on 2026-11-28, as written and at the first try: `Provisioned` after 2 minutes and 26 seconds, four nodes Ready after 3 minutes and 47 seconds. So a control plane node runs as a Kata pod on QEMU with the Rust runtime on arm64. What the run read under QEMU (`results/first-run-arm64.md`):
  - systemd in the guest is `running` with no failed unit, and `kubeadm init` and both joins passed;
  - the two block volumes are SCSI disks of QEMU with direct I/O, and the etcd WAL sync takes 3.0 to 3.6 ms on average, with 94% to 97% of the calls within 8 ms;
  - the exec readiness probe each 2 seconds holds, with under 3% of one CPU in the Kata shim;
  - a control plane node takes 3.5 to 3.8 GB of `/dev/shm` of its kind node, against a limit of half of the memory of the machine.
- Scenarios 2 and 3 passed on arm64 at 13:20, each as written and at the first try.
  - Scenario 2: 16 lines with `ok` between the pods of the four nodes and 4 to the Service. So the tunnels of the pod network work between a control plane pod on QEMU and the worker of the simulator.
  - Scenario 3: a deleted pod came back with the same name on the same kind worker, and the node was Ready again after 55 seconds. No format, the same machine ID, and no request to NVKE. The pod was gone 3 seconds after the end of its grace period, so the stop of a pod works under QEMU too (the second change in the Kata agent).
- Scenario 4 passed on arm64 at 13:26, as written and at the first try, in 347 seconds. A fourth node joined in 98 seconds. After the DELETE of the oldest node, NVKE made its replacement alone on the kind worker of the old node, in 167 seconds. The scale back to three took 81 seconds. One API call each second through the shared address: 311 answers and no failure. Each volume of a node that left was free again 70 seconds later. The times on amd64 were 141, 255 and 73 seconds.
- Scenario 5 passed on arm64 at 13:39, as written and at the first try: NVKE replaced the three control plane nodes one after the other in 526 seconds, and the API gave 484 answers with no failure. No control plane pod restarted through scenarios 1 to 5. The Rust shim of QEMU (`qemu-runtime-rs`) does what a node needs, so the Go shim was not necessary.
- Scenario 6 passed on arm64 at 13:58, as written and at the first try. Encryption was on after 414 seconds with 376 API calls and no failure. The rollout after it took 463 seconds with 422 calls and no failure. Each new node joined at its first attempt with both encryption flags, and no join wrote the `ClusterConfiguration`. In both parts the gate file came first for each node, and no two nodes were out at the same time.
- Scenarios 8, 9 and 10 passed on arm64 on 2026-11-28, each as written and at the first try, on the tip without the gate fix.
  - Scenario 8, at 14:14: the upgrade to 1.37.0 took 516 seconds from the patch to `Provisioned` (764 on amd64). The builds of the 1.37.0 images took 99 and 64 seconds, and the load 275 seconds. The cluster kept its encryption.
  - The last upgrade step without the fix: `kubeadm upgrade apply` ran 95 seconds on one node and wrote no gate file. The etcd of that node was down for 39 seconds, and 1 of 481 calls through the shared address failed. Its API server container did not start again. So the failed call comes when etcd stops under an API server that is still behind the shared address.
  - Scenario 9, at 14:17: two more workers in 73 seconds, a deleted worker replaced by NVKE in 67 seconds, a reboot by the label in 16 seconds.
  - Scenario 10, at 14:21: no cluster after 52 seconds, and twelve volumes free after 61 seconds, with no step by hand.
- The proof of the gate fix on arm64, 14:55 on 2026-11-28 (`results/first-run-arm64.md`, "The proof of the gate fix on arm64"). The clone went to the tip with the fix, and only what holds the node agent was built again (the base image, the node image and the two 1.37.0 images). So it is not a clean second pass there. Scenario 1 passed again (four nodes Ready after 236 seconds), and scenario 8 passed again with 732 of 732 calls answered.
- Scenario 7 passed on arm64 at 15:49 on 2026-11-28, on the second cluster (1.37.0, the node agent with the gate fix). The rollout took 2,431 seconds with two waits. At each wait the machine had the reason `FailureDomainUnavailable` with the text of the scheduler, the controller recorded the delete 14 min 59 s later, and the pod of a new machine was on another kind worker 16 min 9 s to 16 min 12 s after the reason first showed (amd64: 15 min 4 s and 16 min 18 s). 2,200 API calls, no failure. The image had another second name than the guide gives, by a fault of the runner's script. The path through the product is the same.
- Scenario 10 passed a second time at 15:51 (no cluster after 49 s, each volume free after 58 s), and the clean up of the guide passed: `down.sh` took 19 seconds, and no kind cluster, no network of the run, no loop device of the run, no volume file and no port forward is left. No firewall rule of ours was on that machine at any time.
- The measures on arm64: 30 GB of memory at the highest (21 GB above the machine with nothing of the run), 14 GB for one cluster with the management plane, and about 110 GB of disk for the path of the guide at its fullest, the same as on amd64.
- So the first run on arm64 is at its end (15:53): each step and each scenario passed, each at the first try, over two clusters and two tips. Open: one run of the whole guide in one pass from the tip of now, on this machine.
