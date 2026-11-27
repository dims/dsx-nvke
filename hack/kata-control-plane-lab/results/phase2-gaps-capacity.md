# Phase 2 gaps: the capacity signal and the readiness probe program (result)

Date: 2026-11-27, 10:17 to 10:44 local time. An agent wrote the code and ran the checks. Design: `phase2-gaps-design.md`, section 2, and the readiness probe row of section 1. Nothing is pushed. No pull request and no issue exist. No cluster test ran.

Roots of the paths in this note:

- **NVKE:** `/scratch/kata-cp/src/nvke-capacity/controller/`, at `d625fcfa` plus the new commit.
- **Provider:** `/scratch/kata-cp/src/nvke-podvm/cluster-api-provider-podvm/`, at `d2880014`.
- **Cluster API:** `~/go/pkg/mod/sigs.k8s.io/cluster-api@v1.13.7/`, the version in `controller/go.mod:67`.
- **controller-runtime:** `~/go/pkg/mod/sigs.k8s.io/controller-runtime@v0.25.2/`.

## 1. Commits

| Branch | Worktree | Commit | Subject |
|---|---|---|---|
| `feat/cluster-api-provider-podvm` | `/scratch/kata-cp/src/nvke-podvm` | `b4f8837d` | feat(podvm): run a program of the node image as the readiness probe |
| `feat/cluster-api-provider-podvm` | the same | `d2880014` | feat(podvm): report a pod that the scheduler cannot place |
| `feat/capi-failure-domain-unavailable` (new, from `d625fcfa`) | `/scratch/kata-cp/src/nvke-capacity` | `23c1ed00` | feat(controller): re-place a pending control-plane node of a template-backed provider |
| `lab/controller-endpoint-and-capacity` (new, local only, from `c6d669ef`) | `/scratch/kata-cp/src/nvke-ctrllab` | `5c08484c` | The cherry-pick of `23c1ed00` |

Each commit has a sign-off, the configured author, no GPG signature and no agent text.

## 2. The facts of the three questions

### Question 1: how NVKE reads an infrastructure object of a template provider

NVKE has one way to read such an object today.

- The helper is `capiexternal.GetObjectFromContractVersionedRef` of Cluster API. NVKE calls it in three places, all in one Temporal activity file: `internal/temporal/activities/capi_node_resources.go:302`, `:421` and `:457`.
- The helper finds the API version from the CRD of the kind. It reads the CRD as metadata only (`internal/contract/version.go:173-181`). It then takes the newest version from the CRD label `cluster.x-k8s.io/<contract version>` (`version.go:118-144`). After that it reads the object as unstructured (`controllers/external/util.go:54-82`).
- The activities hold a direct client with no cache (`cmd/worker/main.go:217` and `:680`, `internal/kube/client.go:51-62`). The chart gives the controller only `get` on three named CRDs for this path (`deploy/charts/controller/templates/rbac-capi.yaml:70-79`). A direct client needs no more.

The second option also holds. Cluster API copies the `Ready` condition of the infrastructure machine into the `InfrastructureReady` condition of the Machine.

- The copy keeps the status, the reason and the message without change (`util/conditions/mirror.go:66-83`, called from `internal/controllers/machine/machine_controller_status.go:167-195`).
- Cluster API changes the reason in one case only. A condition with the status `True` and no reason gets a reason of Cluster API (`machine_controller_status.go:189-193`).
- The copy does not keep the `ObservedGeneration` of the infrastructure machine (`mirror.go:80-81`). `conditions.Set` writes the generation of the Machine in its place (`util/conditions/setter.go:83-85`).
- Cluster API makes the copy at each Machine reconcile, also while the infrastructure machine is not provisioned (`machine_controller_status.go:56`).
- NVKE reads this copy already. The pending message of a node is the message of `InfrastructureReady` (`capi_node_resources.go:353-362`, `:393-399`).

I chose the second option. The reasons:

- The rule of the control plane controller reads the Machine and gives it to the provider client (`internal/controllers/controlplane/stuck_pending.go:120-135`). So the second option needs no further read, no API version and no new right.
- The first option is not safe at this call site. The rule gives the provider client the cached client of the manager (`stuck_pending.go:129`, `internal/controllers/controlplane/controller.go:113`, `cmd/worker/main.go:609`). A cached client reads a metadata only object through its cache. Only an unstructured object goes to the API server directly (`pkg/client/client.go:297-319`, `:430-436`). The cache needs list and watch on all CRDs, and the chart gives only `get` on named CRDs. This point is a deduction from the source. I did not run it in a cluster.
- The message that NVKE shows and the reason that NVKE acts on then come from one condition.

The cost of the second option:

- The generation rule of the NICo client cannot move over as it is. That rule compares the condition with the generation of the `NicoMachine` (`internal/clients/nico/failuredomain.go:37-44`). The copy has the generation of the Machine. The new code applies the same rule to the Machine.
- The copy is as fresh as the last Machine reconcile of Cluster API. When the Cluster API controller does not run, the copy is stale.

### Question 2: can the rule fire for a node of a template provider

Yes. Each part of `isStuckPendingInDomain` (`stuck_pending.go:39-47`) can be true for such a node.

| Part | For a node of a template provider | Source |
|---|---|---|
| `IsManagedByControlPlaneController` | True. The control plane controller makes the node with `ControlPlane: true` and no node pool | `internal/db/nodes.go:100-102`, `internal/controllers/controlplane/scale.go:98-115` |
| `FailureDomain != ""` | True when the cluster has failure domains. The allocator gives the node one, and NVKE writes it to `Machine.spec.failureDomain` | `scale.go:66`, `:103`, `internal/clients/shared/machine.go:198` |
| `isPending` | True while `Machine.spec.providerID` is empty. The node is made with `Pending` true, and the wait activity keeps it true at each attempt | `controlplane.go:264-266`, `scale.go:105`, `capi_node_resources.go:353-374` |
| `!HasAllocatedInstance` | Always true. The function reads only the NICo and LaunchLayer data of a node, and a template node has none | `internal/db/nodes.go:277-285`, `internal/clients/capi/newnode.go:21`, `:26-28`, `internal/clients/shared/machine.go:48-71` |
| `!isRebalanceReplacement` | True. Only the rebalance step sets the mark, and that step ends at once for a provider with no ranker. Only NICo has a ranker | `controlplane.go:277-279`, `scale.go:23-40`, `rebalance.go:82-85`, `internal/db/control_plane_scaledown.go:42` |
| `!IsDeleteInFlight` | True for a node that waits | `internal/nodes/control_plane_delete_request.go:92-94` |
| `pendingLongerThan` | True after 15 minutes. The time counts from the last change of the status of `Pending`. A new message does not move it | `rebalance.go:472-478`, `internal/db/shared.go:63-74` |

The allocated instance of a node has no source on the template path. NVKE says so itself: "For CAPI, providerID is the provider-agnostic signal that backing infrastructure has been allocated" (`capi_node_resources.go:354-356`). So for a template node "pending" is the whole test.

The provider does not set `spec.providerID` before the pod runs. It sets it when the node agent answers (provider `controllers/machine_controller.go:531-533`). Cluster API copies it to the Machine only for a provisioned infrastructure machine (`internal/controllers/machine/machine_controller_phases.go:312-319`, `:323-374`). So a node stays pending through the wait for a place, the image pull and the start of the virtual machine. The reason of the provider tells these states apart.

The rest of the rule (`stuck_pending.go:76-116`):

- **No delete in flight.** A rollout records the delete of the old node only after the surge node is healthy (`upgrade.go:73-82`). So no delete is in flight while the surge node waits.
- **The endpoint gate.** `controlPlaneReplacementBlocked` stops the rule for a cluster with no `controlPlaneVIP`, unless the controller setting `allowControlPlaneWithoutVIP` is on (`controlplane.go:29-31`, `internal/config/config.go:430-432`). On `main` a cluster of the pod provider has no VIP. The branch `feat/control-plane-endpoint` makes the gate pass for a cluster with `controlPlaneEndpoint` (lab branch `internal/db/clusters.go:201-203`). The same gate stops the rollout surge itself (`upgrade.go:57`).
- **The failure domains.** They come from `status.failureDomains` of the Cluster API `Cluster`, with `controlPlane: true` (`failure_domain_discovery.go:43-65`). Cluster API copies them from the infrastructure cluster. The pod provider publishes one for each zone or host node (provider `controllers/failure_domains.go:25`).
- **Another domain.** `hasAlternativeDomain` needs one more domain that is not marked (`stuck_pending.go:139-149`). The lab cluster has three.
- **The delete record.** `recordControlPlaneManagedDelete` applies the quorum floor. A node that never joined is not an etcd member (`scaledown.go:95-98`, `:120-153`).

What happens after the rule records the delete:

1. `reconcileRequestedDeletes` starts the teardown (`reconciler.go:212-215`). The teardown cancels the provisioning workflow (`internal/temporal/workflows/teardown_node.go:134`). It skips the graceful shutdown of a node that never joined (`:240-261`). It deletes the Machine (`:155`) and then the node row (`:170`).
2. No new node comes while the row exists. `size()` and `countControllerManagedNodes()` count each row (`controlplane.go:104-106`, `:140-148`).
3. The new node then comes from one of two steps. After a create or a node delete it is the scale up step (`reconciler.go:302`). In a rollout it is the surge of the rollout step (`upgrade.go:55-63`), because the old node still fills the count.
4. Both steps use an allocator with no marked domain. `discoverPlacement` removes the marked domains (`reconciler.go:245`, `stuck_pending.go:57-69`). The allocator counts only the domains that are left (`failure_domain_assignment.go:55-59`). The rollout releases the domain of the old node first, and that release does nothing for a domain that is not in the allocator (`:63-67`). `take` then gives the least used domain, and the name decides a tie (`:22-30`, `:70-77`).

So the new node goes to another domain. For the lab case of `lab/phase2-gate-run/result.md`, section 5, the next surge goes to `kata-bb-worker`. A throwaway test on the lab branch gave that answer. It also showed that the rule acts for a cluster with `controlPlaneEndpoint` and no VIP, and does not act with neither.

The control plane controller runs on database events and on a resync of 15 minutes (`internal/controllers/dbreconcile/dbwrapper/wrapper.go:20`). The wait activity writes the node row at each attempt, at most 10 s apart (`internal/temporal/workflows/provision_node.go:349-371`). So the rule looks often while a node waits. This is a deduction from the source.

### Question 3: stop or go on

I went on. The rule can fire, and the new node can move. Nothing outside the contract is missing for the lab build. One point depends on another branch. On `main` alone the endpoint gate stops the rule for a cluster of the pod provider. The lab branch has the endpoint commits and the new commit.

## 3. What changed

### Provider, `b4f8837d`: the readiness probe runs a program

- `controllers/machine_resources.go:65-87`, `:527-534`: the readiness probe of a control plane pod is an exec probe with the command `/usr/local/bin/podvm-endpoint-ready`. The period (2 s), the time limit (3 s) and the failure count (3) are the same. The startup probe is the same. A worker pod has no readiness probe, as before.
- `controllers/machine_pod_test.go`: the contract test checks the new probe.
- `README.md:160`, `:170-182`: the table row and a new text about the gate file.

### Provider, `d2880014`: a pod that the scheduler cannot place

- `api/v1alpha1/condition_consts.go:63-79`: the reasons `FailureDomainUnavailable` and `PodUnschedulable`.
- `controllers/machine_resources.go:175-225`: `podUnschedulable` reads the pod condition `PodScheduled`. `unschedulableProblem` makes the reason and the message.
- `controllers/machine_controller.go:437-445`: the case for a pod that does not run asks `unschedulableProblem` first. It logs one info line and adds no requeue.
- `controllers/machine_unschedulable_test.go` (new) and one helper in `controllers/test_helpers_test.go`.
- `README.md:129-132`, `:200-232`, and one item of the list "What the provider does not do".
- No generated file changed.

The messages:

- With a failure domain: `Pod <namespace>/<name> cannot be scheduled in the failure domain "<domain>": <text of the scheduler>`
- With no failure domain: `Pod <namespace>/<name> cannot be scheduled: <text of the scheduler>`

### NVKE controller, `23c1ed00`: read the signal

- `internal/clients/capi/failuredomain.go` (new): `FailureDomainUnavailable` answers yes when the `InfrastructureReady` condition of the Machine has the status `False`, the reason `FailureDomainUnavailable`, and a generation that is not older than the Machine. The doc comment of the function is the contract text.
- `internal/clients/capi/rotation.go`: the old function with the comment "no contract to read" is gone.
- `internal/clients/capi/failuredomain_test.go` (new): a table with 12 cases, and one test that runs the copy code of Cluster API on an unstructured `PodVMMachine`.
- `internal/controllers/controlplane/stuck_pending_test.go`: one new table test. It runs the rule with the real client for a template provider.
- The rule itself (`stuck_pending.go`) has no change.

NVKE has no page that says what it expects from a template provider. I searched the Markdown files of the repository and the API spec for the provider facing points: the reboot annotation, `status.addresses`, `spec.providerID`, `InfrastructureReady` and the failure domains. The page `docs/operate/infrastructure-providers.md:62` at the repository root says that `infra` "accepts raw Cluster API manifests from the caller and is not an infrastructure provider in its own right". The API spec calls the template an "Arbitrary JSON manifest" (`api/openapi.yaml:3389`). No page names the rule for a pending node. So the contract is in the Go doc comment only, and in the README of the provider.

## 4. Choices that a reviewer can change

1. **NVKE reads the copy on the Machine, and not the infrastructure machine.** The design text says "reads the infrastructure machine". Section 2, question 1, has the reasons. The other way needs a change. Either the rule gives the client the direct reader (`cmd/worker/main.go:610`), or the chart gives list and watch on CRDs. The README of the provider and the commit text of `d2880014` describe the copy, so they change with this choice.
2. **The generation rule uses the Machine.** A condition whose `ObservedGeneration` is lower than the generation of the Machine does not count. NVKE does not change the spec of a Machine after it made it, so the rule has no effect in the flows of today. It is one line.
3. **The function moved to a new file** `failuredomain.go`, as in the NICo client. It can stay in `rotation.go`.
4. **One new test is in the test file of the rule.** The design says that the rule needs no change. The rule has none, and the test can go.
5. **The provider does not look at the cause.** Each `Unschedulable` pod of a Machine with a failure domain gets `FailureDomainUnavailable`, also when no host node at all can take the pod. NVKE then tries each other domain one time, 15 minutes apart, and stops when each domain is marked.
6. **A lost pod of a provisioned machine gets the same reasons.** NVKE does not act on it, because that node is not pending.
7. **`PodScheduled` with the reason `SchedulerError` stays `WaitingForPod`.**
8. **The provider logs one info line** at each reconcile of a machine whose pod has no place. It adds no requeue.
9. **A scheduler message that is empty** becomes "the scheduler gave no message".
10. **The provider does not know the path of the gate file.** The node image sets it for the probe program and for the node agent.
11. **The README of the provider names the NVKE rule** with its 15 minutes and 3 hours. Those numbers are constants of NVKE (`stuck_pending.go:26`, `:30`).

## 5. Tests and checks

Flox is not on the PATH of this workstation. Each target ran with plain `make`. The linter is the pinned golangci-lint 2.14.0.

### Provider, at `d2880014`

| Check | Result |
|---|---|
| `make generate-check` | Pass. No generated file changed |
| `make test` | Pass |
| `go test -race -count=1 ./...` | Pass |
| `make lint` | Pass, 0 issues |
| `go vet ./...`, `gofmt -l .` | Pass |
| Root: `make coverage-check`, `make license-header-check`, `make docs-check` | Pass |

- The module has 81 test functions with 161 subtests. No test fails.
- `make test` and `make lint` also passed at `b4f8837d`.
- I broke 5 rules of the new code one at a time, and a named test failed for each. The rules were the reason of `PodScheduled`, its status, the failure domain branch, the call in the controller, and the search for the condition by its type.

### NVKE controller, at `23c1ed00`

| Check | Result |
|---|---|
| `make license` | Pass. It also adds a header to `test/e2e/internal/oidc/testdata/auth-config.yaml`, a file of `main` that I did not touch. I restored that file. It is not in the commit |
| `make fmt` | Pass, no change |
| `make lint` | Failed one time, because the linter `grouper` wants a `const` group. I corrected it. Then pass, 0 issues |
| `make test` | Pass, 76 packages |
| Root: `make coverage-check`, `make license-header-check` | Pass |

- Each module resolved. No `replace` was needed.
- I broke 4 rules of the new code one at a time, and a named test failed for each. The rules were the answer itself, the status, the generation, and the condition type.
- I did not run `make generate` and `make api-compat-check`, because the API spec has no change.

### Lab branch, at `5c08484c`

- The cherry-pick had no conflict.
- `go build ./...` passes.
- `go test -count=1 ./internal/clients/... ./internal/controllers/controlplane/...` passes, 6 packages.
- The throwaway test of section 2 ran here. The file is removed, and the worktree is clean.
- No image was built.

## 6. Not verified

- **No cluster test.** The tests 5, 6 and 7 of `phase2-gaps-design.md`, section 4, are open.
- **The probe program.** It is in the next node image, which another agent builds. With an image that has no such program, for example p5, the probe fails each time, and no control plane pod gets behind the shared Service. So the provider and the image go out together.
- **An exec probe in a Kata pod.** The kubelet runs the program in the guest each 2 s. The cost and the behavior under load are not measured.
- **The text of a real scheduler.** The tests use the text of the lab run. The reason `Unschedulable` and the condition type are constants of Kubernetes.
- **The copy in a real cluster.** One unit test runs the copy code of Cluster API. No test ran the Machine controller of Cluster API.
- **The teardown of a pod node that never ran.** NVKE has this path for a NICo node with no instance. The provider deletes a machine in each state in its unit tests. The two together did not run.
- **When the rule fires after the 15 minutes.** Section 2 has the deduction.
- **The cached client and the CRD read.** The reason against the first option is a deduction from the source of controller-runtime.
- **Root targets that I did not run:** `make build`, the root `make lint`, `make gate`, `make work-check`.

## 7. Points for Davanum

1. **The read path differs from the design text.** Choice 1 of section 4.
2. **Two control plane nodes can end on one host node.** After the rule moves a node, the spread in the lab case is 2, 1 and 0 nodes. The loss of the host node with 2 nodes then costs the etcd quorum. NVKE does not use the first domain for 3 hours and has no step that moves a node back. The design names this effect.
3. **On `main` the rule needs a VIP.** The branch `feat/capi-failure-domain-unavailable` alone has an effect for a pod cluster only with `allowControlPlaneWithoutVIP`. The lab branch has the endpoint commits.
4. **The provider needs the new node image.** See section 6.
5. **Two notes still name the HTTPS probe.** `phase2-design.md`, section 5, point 9, and the row "Readiness probe" of section 5a. I did not change the notes.
6. **`make license` changes one test data file on `main`.** It is not part of this work.
7. **Choice 5 of section 4** can cost up to two wasted moves in a cluster with three domains when the cause is not in the domain.
