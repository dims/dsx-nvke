# Phase 2, steps 1 and 2: the provider module `cluster-api-provider-podvm`

Date: 2026-11-26, 17:00 to 17:47 local time. An agent wrote the module and ran the checks. The main session reviewed the reconcile flow, the address allocation, the reboot answer, the delete and the pod builder, and pushed the branch at 17:49. Design: `phase2-design.md`, sections 4, 5 and 5a.

- Branch: `feat/cluster-api-provider-podvm` on `dims/dsx-nvke`, four commits on top of main (`d625fcfa`). https://github.com/dims/dsx-nvke/tree/feat/cluster-api-provider-podvm
- Worktree: `/scratch/kata-cp/src/nvke-podvm`. Logs: `/scratch/kata-cp/logs/phase2-provider/`.
- No pull request. The commits have a sign-off, no GPG signature and no agent text.
- Tested in a cluster on the second machine with the third commit: `lab/phase2-provider-run/result.md` (3 clusters through NVKE, a lost pod, a delete with no operator step).
- A third commit (`cdc368ea`, pushed at 17:56) makes the provider report the address when the node agent answers (section 7 of this note).

## 1. Commits

| Commit | Subject | Content |
|---|---|---|
| `638ddfd7` | feat(podvm): add the pod VM Cluster API provider module and its API | The module, the three kinds, generated deepcopy and CRDs, the manager with no controller, kustomize `config/`, a Dockerfile, a README, samples for the lab, an RBAC manifest for the NVKE controller. 43 files |
| `57f6cac4` | feat(podvm): add the cluster and machine controllers | The two controllers with tests, the generated role. 23 files |
| `cdc368ea` | feat(podvm): report the address when the node agent answers | The startup probe, the later write of `status.addresses`, a new condition reason, tests, the README. 12 files |
| `2f2841c5` | fix(podvm): finalizer name, tenant API wait, readiness probe, grace period | Four points from the first cluster test (section 10). 6 files |

Root files changed, because the checks of the repository need it: `go.work`, the root `Makefile` (two module lists), `hack/coverage.sh`, and four docs pages with the module count and a table row.

## 2. The API

Group `infrastructure.cluster.x-k8s.io`, version `v1alpha1`. Short names `pvmc`, `pvmm`, `pvmmt`.

`PodVMCluster` spec:

1. `podNamespace`: where the pods, the claims and the Secret copies go. Required, must exist, immutable.
2. `runtimeClassName`: the RuntimeClass of each pod. Required.
3. `networkAttachment.name` and `.namespace`: the NetworkAttachmentDefinition. The namespace defaults to `podNamespace`.
4. `addressRange.cidr` and `.prefixLength`: the block that the provider gives out, and the prefix length of the node network. Required, immutable.
5. `failureDomainLabelKey`: default `topology.kubernetes.io/zone`. The fallback is the host name label.

`PodVMCluster` status: `initialization.provisioned`, `failureDomains` (name, `controlPlane: true`), `conditions`.

`PodVMMachine` spec:

1. `providerID`: `podvm://<pod namespace>/<pod name>`. Immutable when set.
2. `image`, and an optional `imagePullPolicy`.
3. `resources.cpu` and `resources.memory`. Required.
4. `volumes.var` and `volumes.etcd`: each has an optional `storageClassName` and a required `size`. The claims always have the volume mode Block.

`PodVMMachine` status: `initialization.provisioned`, `addresses` (one InternalIP), `podNamespace`, `podName`, `address`, `hardwareAddress`, `lastRebootRequest`, `conditions`.

No field has the name `instanceID`, `machineID` or `instanceTypeID`.

## 3. Choices of the agent where the design fixed nothing

1. The range is a CIDR block plus a prefix length. The provider gives the lowest free address. It leaves out the first and the last address of the block, and the network and broadcast address of the node network. `172.28.1.0/24` gives `.1` to `.254`.
2. IPv4 only. The hardware address rule needs four bytes.
3. `podNamespace` and `addressRange` are immutable. A change under running machines would orphan pods or move the range.
4. Range overlap: the older `PodVMCluster` keeps its range, and the younger one is rejected.
5. `status.podNamespace` is written before the provider makes any object. A delete then needs no other object to find what to delete.
6. `status.lastRebootRequest` makes a reboot request a one time event.
7. The cluster controller has no finalizer. The delete of a `PodVMCluster` never waits.
8. Object names: claims `<pod>-var` and `<pod>-etcd`, Secret copy `<pod>-bootstrap`.
9. The pod is in another namespace than the `PodVMMachine`, so no owner reference is possible. Labels with the owner namespace, name and UID take its place. The provider changes and deletes only objects whose owner UID is the UID of the machine.
10. An empty `storageClassName` means the default class of the host cluster.
11. Readiness probe with `failureThreshold: 1`, as in the lab pod.
12. Pod settings from the lab pod: no service account token, no Service variables, `restartPolicy: Always`, requests equal to limits.
13. The failure domain rule has two alternatives: the node has the value under the label key of the cluster, or the node has that host name.
14. A node that is cordoned, or has a `NoSchedule` or `NoExecute` taint, is in no failure domain. The pods have no toleration.
15. A pod in the phase `Failed` or `Succeeded` counts as lost. The provider deletes it and makes it again.
16. The used address set comes from the `PodVMMachine` objects of all namespaces, read directly from the API server. That also covers a lagging cache.
17. The reboot answer: the provider reads `nvke.nvidia.com/reboot`, deletes the pod one time, and does not remove the annotation. NVKE waits for a new boot ID of the Node and removes its own annotation. A new Kata VM has a new boot ID.

## 4. The controllers

Paths are in `cluster-api-provider-podvm/controllers/`.

Cluster controller (`cluster_controller.go`):

- It checks the spec (`cluster_validation.go:31`): the range, the namespace, the overlap.
- It publishes the failure domains from the nodes (`failure_domains.go:25`) and sets `provisioned`. It never clears `provisioned`.
- It watches the nodes with a filter for label, taint, cordon and delete changes.

Machine controller (`machine_controller.go`, `machine_resources.go`):

- `Reconcile` (`machine_controller.go:140`): the finalizer, the owner Machine, the `PodVMCluster`, the bootstrap Secret name, the address, the pod, the Node.
- `allocateAddress` (`:275`): one status patch with an optimistic lock for the address, the hardware address, the pod namespace and the pod name.
- `reconcilePod` (`:351`): the same rule makes the first pod and each later pod.
- `createPodResources` (`machine_resources.go:139`): the Secret copy (one time), the two claims, the pod in the form of section 5a (`buildPod`, `:363`), the placement (`podAffinity`, `:481`).
- `answerRebootRequest` (`machine_controller.go:415`): it asks the API server for the record before it deletes a pod.
- `reconcileRunningPod` (`:449`): the provider ID, then `provisioned`. A failed look at the Node does not hold back `provisioned`.
- `reconcileDelete` (`:495`): delete the pod, the two claims and the Secret copy, wait until all are gone, then remove the finalizer.
- The Node provider ID in the new cluster: the logic of the provisioned provider.
- The manager caches only pods with the owner UID label. Secrets and claims are read with no cache.

Tests: 61 test functions with 100 subtests, all on the fake client. They cover the address rules (two machines never get one address, in three variants), each row of section 5a in the pod, the failure domain as a node rule, a new pod for a lost pod, the reboot answer, and a delete in 8 states.

The agent also ran a mutation check outside the repository: 20 single rule breaks, and a named test fails for each.

## 5. Checks

All pass, with 4 build jobs:

- In the module: `make generate manifests`, `make generate-check`, `gofmt`, `make lint` (0 issues, golangci-lint 2.14.0), `go vet`, the race tests, and a render of `config/default` (10 objects).
- From the root: `make coverage-check` (14 modules collect coverage now), `make license-header-check`, `make work-check`, `make docs-check`, `make go-version-check`, `make base-image-check`, `make tool-version-check`, `make name-check`, `make lint-shell`.
- Not run: `make internal-config-check` (a tool is not on the machine), the root `make build`, `make lint`, `make gate`, and each image build.
- No new dependency. Cluster API v1.13.7 and controller-runtime v0.25.2, as in the provisioned provider.
- An offline check of the three CRDs with the validation code of the API server: the schemas are valid, each CEL rule compiles, and both samples validate.

## 6. Not done, and not verified without a cluster

Limits of this first form:

- No toleration and no node selector field.
- The provider does not read the paused annotation, as the provisioned provider.
- It does not recover an address from a pod when the status of a `PodVMMachine` is lost.
- Two managers with no leader election can give one address to two machines. The Deployment has leader election on.
- The spec of a `PodVMMachine` is not protected against edits, except the provider ID.

Not verified without a cluster:

- Block claims, the Multus annotation and the interface name on a real pod.
- That the Node reports a new boot ID after a pod replace, so the reboot workflow of NVKE ends.
- The Node provider ID against a real API server.
- The scheduling rules, RBAC at run time, and the delete timing with the claim protection of Kubernetes.

For the lab storage: the claim names follow the Machine name, so a volume with a fixed claim reference does not bind. The lab needs volumes with no claim reference, and a storage class that binds at the first use of the pod.

## 7. The address timing (done in `cdc368ea`)

The first form writes `status.addresses` at the allocation, before the pod exists. NVKE then goes on to the agent calls while the pod still starts.

- NVKE polls for the address with a retry of at most 10 s (`controller/internal/temporal/workflows/provision_node.go:349-360`).
- Its preflight retry starts at 30 s and grows to 2 minutes (`:376-388`).
- Test T4 of the node image (the pod came after the POST, the address was known): the preflight step took 100 to 221 s, against 30 s when the pods ran before the POST.

Decision of the main session, inside the accepted design: the pod gets a startup probe on TCP port 15005 (the secure port of `nvke-agent`), and the provider writes `status.addresses` when the container is started. A new pod for the same machine keeps the address in the status.

The change in `cdc368ea`:

- The startup probe is on each pod: TCP port 15005, each 2 s, failure threshold 600, which gives the node 20 minutes (`controllers/machine_resources.go:442-448`).
- The allocation record stays at the allocation: the address, the hardware address, the pod namespace and the pod name, in one patch before any object exists.
- `status.addresses` is written when the pod runs and the container `node` has `started: true`, then the provider ID, then `provisioned` (`controllers/machine_controller.go:467`).
- While a pod runs and the agent does not answer, the Ready condition has the new reason `WaitingForNodeAgent`.
- A new pod for the same machine clears nothing. NVKE knows the node by the address and the provider ID, and it reads a removed one as a lost machine.
- Tests: 63 test functions with 106 subtests now. The mutation check has 26 rule breaks, and a named test fails for each.
- All checks of section 5 pass again on the new commit.

Not verified without a cluster:

- That the probe of the kubelet reaches the agent in a Kata pod. The kubelet connects to the pod IP, and the agent listens on all addresses.
- That the port opens only when the agent can serve. In phase 1 the port was closed until the SPIRE agent had its identity.
- What happens after 20 minutes with no answer: the kubelet starts the container again.
- The gain in time itself. A run on the second machine shows it.

## 8. What a pull request still needs

- Workflows: a lint entry, a generate check step, a race test step, the Dockerfile in the image workflow, an image workflow of its own, the tag form.
- Repository lists: code owners, the labeler, the pull request template, the maintainers file, the dependency update configuration, the tables in `AGENTS.md`.
- Release: a component in `release/registry.yaml` and in the qualification list.
- Notices: the Dockerfile copies the notices file of the controller. The new binary must be added to that generator or get its own notices.
- Chart: rules for the three kinds in the controller chart, in place of the lab RBAC manifest.
- nvkectl: only if the site bootstrap should install the provider.
- Docs: `docs/operate/infrastructure-providers.md` calls the provider set closed. It needs a decision and a page for this provider.

## 9. Build and install in a kind cluster

Commands of the agent, not run yet:

```bash
make -C cluster-api-provider-podvm docker-build \
  IMG=docker.io/library/cluster-api-provider-podvm:latest \
  PLATFORMS=linux/amd64 BUILDX_OUTPUT=type=docker \
  BUILD_VERSION="$(git describe --tags --always --dirty --match 'v*')"
kind load docker-image docker.io/library/cluster-api-provider-podvm:latest --name <kind cluster>
kubectl apply -k cluster-api-provider-podvm/config/default
kubectl -n podvm-system rollout status deployment/podvm-controller-manager
kubectl apply -f cluster-api-provider-podvm/hack/nvke-controller-rbac.yaml
```

Before the first cluster request:

1. The pod namespace exists, with the network attachment and a storage class for block volumes.
2. The shared endpoint Service selects `cluster.x-k8s.io/cluster-name: <cluster>` and `cluster.x-k8s.io/control-plane: ""`.
3. `supportedInfraProviders` of the NVKE controller contains `infra`.
4. The node image of step 3 is on each host node.
5. The request carries `infra.cluster` (a `PodVMCluster` spec) and `controlPlaneConfig.infra.machineTemplate` (a `PodVMMachineTemplate`). `config/samples/` has complete specs for the lab.

## 10. Four points from the first cluster test (done in `2f2841c5`)

The provider made three clusters through NVKE on the second machine with the third commit. No fault in the provider code stopped a step. Four points came out, and the fourth commit has them. Pushed at 19:26.

1. **The finalizer name** is now `podvm.infrastructure.cluster.x-k8s.io/machine-cleanup`. The API server warned at each write of an object whose finalizer has a domain and no path. There is no migration code.
2. **The look at the tenant Node.** A machine whose owner Machine has a delete time gets no look. An API server of the new cluster that does not answer is a wait with one info line and a requeue of 30 s, and not a reconcile error. An answer that rejects the call (forbidden, unauthorized) stays an error. The Ready condition stays True, and its message says that the provider ID of the Node is not checked.
3. **The readiness probe** has a time limit of 3 s and needs 3 failures, with the period of 2 s. A pod is out of the shared Service after about 6 s of failed answers. With the old values one slow answer took a pod out, and with a slow disk all three pods were out at one time.
4. **The grace period** of the pod is 20 s. A control plane node does not stop by itself in the default of 30 s, so each lost pod cost the whole 30 s.

Tests: 68 test functions with 130 subtests. The mutation check has 36 rule breaks, and a named test fails for each. All checks of section 5 pass on the new commit.

Not verified without a cluster: that the API server prints no warning for the new name, the error form of a real refused connection, and that the new probe values keep the pods behind the shared Service on a slow disk.

One limit that the agent names: an API endpoint that hangs, and does not refuse, holds one look for up to 30 s. The controller reconciles one machine at a time, so a lost pod of another machine can wait behind it. A shorter time limit for this one look would bound it. Not changed yet.
