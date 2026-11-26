# Phase 1, step 7: the `controlPlaneEndpoint` request field in NVKE

Date: 2026-11-26, 11:37 to 12:09 local time. An agent wrote the change and ran the checks. The main session read the handwritten code and the OpenAPI changes, checked the logs, and pushed the branch at 12:11. Plan: `results/phase1-endpoint-plan.md` (way A, the decision of Davanum).

- Branch: `feat/control-plane-endpoint` on `dims/dsx-nvke`, three commits on top of `d625fcfa` (main). https://github.com/dims/dsx-nvke/tree/feat/control-plane-endpoint
- Worktree: `/scratch/kata-cp/src/nvke-endpoint`. Logs of the checks: `/scratch/kata-cp/logs/phase1-endpoint/`.
- No pull request. The commits have a sign-off, no GPG signature and no agent text.
- Not tested yet: a real cluster with the field. The lab run comes after step 5.

## 1. Commits

| Commit | Subject | Content |
|---|---|---|
| `92867b3e` | refactor(controller): ask one cluster method at each control-plane endpoint gate | `db.Cluster.HasStableControlPlaneEndpoint()` and its use at each gate. No behavior change |
| `3ff11e2a` | feat(controller): accept controlPlaneEndpoint on cluster create | The OpenAPI field, the generated code, the column with its migration, the validation, the response, the gates, tests, five docs pages |
| `c6d669ef` | feat(controller): use controlPlaneEndpoint for kubeadm init and skip kube-vip | The endpoint choice for `kubeadm init`, the kube-vip step, tests |

34 files, 1512 lines added and 519 removed. Generated files: `controller/api/models.gen.go` and `controller/api/server.gen.go`.

## 2. What the field does

Paths are relative to the worktree.

| Place | Code |
|---|---|
| Request schema | `controller/api/openapi.yaml:1154`. A string of 1 to 259 characters |
| Response schema | `controller/api/openapi.yaml:1619`. Omitted when the cluster has none |
| Both fields in one request | `controller/internal/server/cluster_network.go:234` (`validateAPIServerEndpointFields`). The request is rejected |
| Form: `host` or `host:port`, IPv4 or DNS name, port 1 to 65535 | `cluster_network.go:294` (`parseControlPlaneEndpoint`) |
| An IPv4 host outside the pod CIDR and the service CIDR | `cluster_network.go:251` and `:266`. The VIP check uses the same helper now |
| Storage | `controller/internal/db/clusters.go:123`, column `control_plane_endpoint`, text, NULL when empty. One new migration adds the column |
| Fixed at creation | The update request has no such property and rejects unknown properties, so a PATCH gives 400. A test proves it |
| The one method for all gates | `controller/internal/db/clusters.go:201`. True with a VIP or with the new field |
| `kubeadm init` | `controller/internal/temporal/activities/kubeadm_init.go:38` (`kubeadmControlPlaneEndpoint`). Order: the new field, the VIP, the node IP |
| kube-vip step | `controller/internal/temporal/activities/configure_kube_vip.go:90`. No action when the field is set |

The gates that ask the method (ten call sites, one more than the plan counted):

1. Count gate at create: `server/clusters.go:453-454`.
2. Count gate at scale: `server/clusters.go:1050`.
3. Upgrade gate: `server/clusters.go:700`.
4. Rollout gate: `server/clusters.go:987`.
5. Node delete gate: `nodes/control_plane_delete.go:89`.
6. Recycling and surge at upgrade: `controllers/controlplane/upgrade.go:57`.
7. Remediation: `controllers/controlplane/remediation.go:34`.
8. Rebalance: `controllers/controlplane/rebalance.go:141`.
9. Replacement of a node that is stuck pending: `controllers/controlplane/stuck_pending.go:82`. The plan did not list it.
10. Node pool controller, surge and NodeSet replacement: `controllers/nodepool/controller.go:191` and `:268`.

`allowControlPlaneWithoutVIP` has no change and stays `false` by default.

What the main session checked in the code:

- The renderer gives the value to kubeadm with no change (`controller/internal/kubeadmconfig/init.go:317`), and the agent does the same on its old path (`agent/internal/agent/agent.go:762`). Nothing adds a port, so `host:port` is safe.
- The migration is one `ALTER TABLE clusters ADD COLUMN IF NOT EXISTS control_plane_endpoint text`.
- The commit messages have no agent text, and the diff has no private path or address.

## 3. Choices of the agent inside the decided rules

- The field is public in the API reference, as `controlPlaneVIP` is. One line (`x-fern-ignore`) hides it. This is a point for the review of a pull request.
- A host of only digits and dots must be a valid IPv4 address. Without this rule `10.96.0.300` passes as a DNS name and skips the CIDR rule.
- The value is not trimmed. A value with a space is rejected.
- The kube-vip step checks the new field before the VIP, so the rule does not depend on the API validation alone.
- The four 400 messages and five log warnings now say `controlPlaneVIP or controlPlaneEndpoint`. They still contain `controlPlaneVIP`, which the e2e tests match.
- The database has no constraint for "not both". Only the API enforces it.

## 4. Checks

Flox is not on the machine, so the agent used plain `make`, with 4 build jobs.

| Command | Result |
|---|---|
| `make generate`, `make generate-check` (in `controller/`) | Exit 0, no difference |
| `make api-compat-check` | Exit 0. Baseline `controller/api/v0.0.71`. 14 changes, 14 additive, 0 breaking |
| `make license` | Exit 0. It also added a header to one file that this branch does not touch (`controller/test/e2e/internal/oidc/testdata/auth-config.yaml`). The agent reverted that edit. It is a fault of main |
| `make fmt` | Exit 0, no difference |
| `make lint` | Exit 0, 0 issues, golangci-lint 2.14.0 |
| `make test` | Exit 0. 76 packages pass, 0 fail. The tests use SQLite in memory. No container and no port |
| `make coverage-check`, `make docs-check` (root) | Exit 0 |
| `go vet` in `cli`, `management-engine`, `controller/test/e2e`, and with the test tags | Exit 0 |

The agent removed the new logic for a moment in three places (the method, the choice, the kube-vip check). The new tests failed each time.

## 5. Not verified

- The migration on PostgreSQL. The first start of the new controller image in the lab is the first real run.
- A real `kubeadm init` with the field. Three points stay open from the plan: if init completes while the load balancer forwards to a node that is not ready, if a node reaches its own Service address, and if the certificate keeps the endpoint SAN after an upgrade and a renewal.
- Not run: `fern check`, the tests that need a PostgreSQL address, each e2e test, and the full `make build` and `make gate` at the root.

One risk in the agent, with no change on this branch:

- The kube-vip drain guard still runs on such a cluster at certificate renewal, at etcd encryption and at OIDC enable.
- The agent reads each IPv4 /32 with host scope on `lo` that is not a loopback address as the VIP (`agent/internal/agent/control_plane_graceful_shutdown.go:577-614`) and removes it for the drain.
- So the load balancer address must not be on `lo` of the guest. The lab uses a bridge for the node address, so it is not affected.

## 6. What a complete product change still needs

- nvkectl: the site bootstrap path demands a VIP above one node (`cli/internal/bootstrap/sitespec/sitespec.go:868-878`) and sends only the VIP (`cli/internal/bootstrap/sitecluster/sitecluster.go:65`). `nvkectl create cluster -f` should accept the field after a rebuild (read, not run).
- An e2e test beside `controller/test/e2e/no_vip_scale_test.go`.
- management-engine maps `spec.apiServerEndpoint.address` to `controlPlaneVIP` only (`management-engine/controllers/nvkecluster_controller.go:884-886`).
- A decision on the drain guard of the agent.
- The metric `nvke_controller_cluster_info` has the label `control_plane_vip` and no label for the endpoint.
- Texts not changed: the chart value comment and the chart README, a comment in `controller/internal/config/config.go:430-432`, `docs/operate/plan-installation.md:45`, `docs/workload-clusters/create.md:112`, `docs/tenant-clusters/certificate-renewal.md:25`.

## 7. The controller image for the lab

Do not use step 03 of `phase1-stack/install.sh`. It has the commit `bcc4376f` fixed and would replace the image that the lab runs. Build with a new tag:

```bash
SRC=/scratch/kata-cp/src/nvke-endpoint
TAG=nvke-controller:c6d669ef
DOCKER_BUILDKIT=1 docker build --builder default \
  --file "$SRC/controller/Dockerfile" --platform linux/amd64 --provenance=false --progress=plain \
  --build-arg "BUILD_VERSION=$(git -C "$SRC" --no-optional-locks describe --tags --always --dirty --match 'v*')" \
  --build-arg "GIT_VERSION=$(git -C "$SRC" rev-parse --short=8 HEAD)" \
  --build-arg "GOLANG_IMAGE=mirror.gcr.io/library/golang:1.27.4@sha256:fe517acaa580cc7915457080f850c37e618b3c1e750f98b58fc6429b605147a1" \
  --tag "$TAG" "$SRC" </dev/null
```

- Import: `docker save --platform linux/amd64 "$TAG" | docker exec -i kata-cp-control-plane ctr -n k8s.io images import --digests -`.
- Then set the image tag in `values/controller-values.yaml` to `c6d669ef`. `check_values` in `install.sh` compares the tag with the fixed commit, so the script needs the same change.
- The chart did not change between `bcc4376f` and this branch.
- The request then has `"controlPlaneEndpoint": "<shared address>:6443"`, no `controlPlaneVIP`, and `desiredCount: 3`. `allowControlPlaneWithoutVIP` can go back to `false`.
