# Phase 1, step 7: plan for a control plane endpoint that NVKE does not manage

Date: 2026-11-26, 11:04 to 11:12 local time. A planning agent read the NVKE source and returned this plan as text. The main session wrote the file. The agent only read. It ran no build, no test and no check. "Deduction" marks a statement that is not tested.

Paths are relative to the NVKE clone `/scratch/kata-cp/src/nvke` at `bcc4376f`. Short paths in the table are under `controller/internal/` unless they start with another top folder.

## Why the change is necessary

The API servers of the three control plane pods are behind one LoadBalancer Service of the host cluster. That address stays when a pod is replaced, so it is the correct endpoint. NVKE has two cases today:

- A request with `controlPlaneVIP`. NVKE uses the VIP as the endpoint and configures kube-vip on the nodes to hold it.
- No VIP, with the deployment setting `allowControlPlaneWithoutVIP: true`. The endpoint is the address of the first node, and the cluster loses its endpoint with that node.

The lab needs a third case: NVKE uses an address as the kubeadm `controlPlaneEndpoint` and does not configure kube-vip.

## Two findings first

- The workflow needs one changed line. In `controller/internal/temporal`, only `activities/kubeadm_init.go:80-83` and `activities/configure_kube_vip.go:90-93` read the VIP. Each later step reads the endpoint back from what kubeadm wrote. The larger part of the change is nine gates that read "no VIP" as "no stable endpoint".
- The clone is one commit behind the newest API tag. `controller/api/v0.0.71` is `445bde08`, the child of `bcc4376f`. It added `enableCPNodeRecycling` to the create request. Deduction: `make api-compat-check` on a branch from `bcc4376f` reports that property as removed and fails. So the branch must start from `445bde08` or later.

## 1. Map of each place that reads the VIP or decides the endpoint

| Area | Place | With a VIP | With no VIP |
|---|---|---|---|
| API schema | `controller/api/openapi.yaml:1131-1146` (request), `:1578-1582` (response) | IPv4 only, fixed at creation | Omitted. The first node IP is the endpoint |
| Create validation | `server/clusters.go:323-328`, `server/cluster_network.go:216-243` | Must be IPv4 and outside the pod and service CIDR | Skipped |
| Count gate, create and scale | `server/clusters.go:454`, `:1050-1056`, `server/control_plane_vip.go:18-23` | Passes | 400 above one node, unless `allowControlPlaneWithoutVIP` |
| Upgrade and rollout gates | `server/clusters.go:700`, `:987-992`, `server/control_plane_vip.go:25-37` | Pass | 400, unless the setting |
| Node delete gate | `nodes/control_plane_delete.go:90-92`, `server/nodes.go:99,119` | Passes | 400, unless the setting |
| Recycling, remediation, rebalance, surge | `controllers/controlplane/controlplane.go:29-31` (used at `upgrade.go:57`, `remediation.go:34`, `rebalance.go:141`), `controllers/nodepool/controller.go:192,269` | Run | Skipped with a warning, unless the setting |
| Database | `db/clusters.go:86`, column `clusters.control_plane_vip`, nullable since `db/migrations/20250801160212_make_control_plane_vip_nullable.go:16` | Stored | Empty |
| API response and metric | `server/clusters.go:1334-1337,1414`, `dbmetrics/dbmetrics.go:162,457` | Returned. Label value | Omitted. Empty label |
| kubeadm init | `temporal/activities/kubeadm_init.go:80-83,106,137`, `kubeadmconfig/init.go:317` | `controlPlaneEndpoint` is the VIP | It is the first node IP |
| Certificate SANs | `kubeadmconfig/init.go:240-279` sets no `certSANs` | kubeadm adds the endpoint host itself (deduction; `agent/internal/agent/kube_vip.go:527-528` says the certificate covers the VIP) | The same, with the node IP |
| kube-vip at create | `temporal/workflows/provision_cluster.go:63-65`, `activities/configure_kube_vip.go:90-93,138-145` | The agent writes the kube-vip static pod before init. The VIP is also an address on `lo` (`agent/internal/agent/control_plane_graceful_shutdown.go:53-54`) | Returns with no action |
| kube-vip at node add | `temporal/workflows/provision_node.go:322-329,754-778` | The same activity, after the join | No action |
| kube-vip at certificate renewal, etcd encryption, OIDC | `rollout/guards/kubevip/guard.go:72-111`, `workflows/renew_k8s_certs.go:419`, `enable_etcd_encryption.go:207`, `enable_oidc.go:160` | The agent parks kube-vip, then restores it | The agent skips it (`agent/internal/agent/control_plane_graceful_shutdown.go:243-245`) |
| Node remove, upgrade, cluster delete | No other VIP reader in `controller/internal/temporal` (grep) | No VIP logic | No VIP logic |
| Join | `temporal/activities/kubeadm_join.go:93-126`, `kubeadmconfig/join.go:87-95` | The endpoint is the first word of the join string of a joined node | The same |
| CNI | `agent/internal/agent/cni.go:372,307` | OVN gets `k8sAPIServer` from `admin.conf` | The same |
| User kubeconfig and the NVKE kubeconfig | `controllers/tenantaccess/controller.go:201-250,331-354` | The server URL comes from `admin.conf` of a node | The same |
| Tenant client | `kube/tenant_client.go:157-191` (Secret), `:235-262` (node agent, with a `/version` probe at `:276`) | Dials the server URL of the kubeconfig | The same |
| Health checks | `temporal/activities/kube_api_health.go:87`, `rollout/preflights/lib.go:79` | Through the agent to `localhost:6443`. Nothing dials the VIP | The same |
| Cluster API `Cluster` | `controllers/tenantaccess/capi_contract.go:65-79,120-143` | NVKE patches `spec.controlPlaneEndpoint` from `admin.conf` after init | The same |
| `ProvisionedCluster` | `cluster-api-provider-provisioned/api/v1alpha1/provisionedcluster_types.go:45-56` | No endpoint field, by a recorded decision | The same |
| nvkectl | `cli/internal/bootstrap/sitespec/sitespec.go:870-876`, `cli/internal/bootstrap/sitecluster/sitecluster.go:65` | Sent as `controlPlaneVIP` | Error above one node without the flag |

## 2. Three ways to say that NVKE does not manage the endpoint

### A. A new optional request field, `controlPlaneEndpoint`

- Change: `controller/api/openapi.yaml` (request and `Cluster` response), `db/clusters.go` (field at the end, plus one method `HasStableControlPlaneEndpoint`), one new migration (pattern: `db/migrations/20261022120000_add_clusters_cp_auto_scale_down_disabled.go`), `server/clusters.go`, `server/cluster_network.go`, `server/control_plane_vip.go`, the gates in the table, `temporal/activities/kubeadm_init.go`.
- Generated: `controller/api/models.gen.go` and `controller/api/server.gen.go`, by `make generate`. Commit `445bde08` is the precedent. It changed only those two.
- Compatibility: not a break (deduction). `controller/hack/openapi-compat/README.md` names a removed field, a narrowed type and a newly required property as breaks. `controller/api/openapi-compat-waivers.yaml:13-15` says to prefer a new optional property. `445bde08` and `be19c614` added optional request properties with no waiver.
- Risk: the API owners must accept the name and decide if the field is public or `x-fern-ignore`. A missed gate leaves a cluster that cannot upgrade.

### B. A deployment setting, for example `kubeVip.enabled: false`

`controlPlaneVIP` stays the endpoint, and NVKE skips kube-vip.

- Change: `config/config.go:430-436`, `controllerconfig/config.go:69-72`, `controllerconfig/apply.go:161-163`, `controller/deploy/charts/controller/values.yaml:737`, `templates/configmap-controller-config.yaml:89`, chart `README.md:167`, `controller/hack/local-controller-config.yaml:51`, `configure_kube_vip.go:90`.
- Generated: none. No migration. The compatibility check does not apply.
- Tests: `controllerconfig/config_test.go:1230`, `chart_test.go:141`, `drift_test.go:110`, `temporal/activities/configure_kube_vip_test.go`.
- Risk: the setting covers the whole site, so one controller cannot serve both kinds of cluster. `controlPlaneVIP` gets two meanings and stays IPv4 only. The cluster row does not record the mode. If the setting changes back, the next control plane join starts kube-vip, which then announces the load balancer address over BGP. This is a lab workaround.

### C. `spec.controlPlaneEndpoint` on the infra cluster object

- Change: `provisionedcluster_types.go`, and the controller reads the manifest before init and at each gate.
- Generated: `zz_generated.deepcopy.go`, `config/crd/bases/*.yaml`, and the CRD copy in `cli/internal/bootstrap/controllerdeploy/manifests/provisioned-provider.yaml:27-80`.
- Compatibility: no REST change. It is a CRD change in a second module.
- Tests: the provider tests, plus the controller tests of A.
- Risk: it reverses the decision at `provisionedcluster_types.go:45-48`. It works only on the `infra` path, because `NicoCluster` has no such field (`capi_contract.go:115-117`). The gates need the value on each call, so it also needs the column of A.

## 3. Recommendation of the agent: A

The endpoint is a fact of one cluster. The cluster row records it, it works for each provider, and `controlPlaneVIP` keeps one meaning.

The operator writes `"controlPlaneEndpoint": "172.18.255.200:6443"` and no `controlPlaneVIP`. `allowControlPlaneWithoutVIP` stays `false`.

Rules for the field:

- The value is `host` or `host:port`. The host is an IPv4 address or a DNS name.
- NVKE rejects it together with `controlPlaneVIP`.
- An IP host must be outside the pod and service CIDR.
- The value is fixed at creation.
- The renderer accepts this form now (`kubeadmconfig/init_test.go:388` uses `cluster.local:6443`).

What NVKE does in this mode:

1. Create: it validates the field, accepts `desiredCount: 3`, and stores the endpoint with an empty VIP.
2. Cluster API objects, one node ready to join: no change.
3. kube-vip step: it returns with no action, because the VIP is empty. No code change.
4. `kubeadm init`: the endpoint is the new field, then the VIP, then the node IP. kubeadm puts the endpoint host in the API server certificate (deduction). NVKE needs no SAN code.
5. CNI install, first node joined, DNS, labels, "provisioned": no change. OVN dials the endpoint.
6. Tenant access: it publishes both kubeconfigs with the endpoint and patches `Cluster.spec.controlPlaneEndpoint`. No change.
7. Nodes 2 and 3: the join string carries the endpoint. The kube-vip step does nothing.
8. Scale, upgrade, rollout, node delete, remediation, rebalance: the gates pass. The kube-vip drain guard runs, and the agent skips it.

Order of work:

1. Add `db.Cluster.HasStableControlPlaneEndpoint()` (true with a VIP) and use it at the nine gates. This step changes no behavior.
2. Add the column, the field and the migration. Extend the method.
3. Edit `openapi.yaml`, run `make generate`, add the validation and the response mapping.
4. Change `kubeadm_init.go:80-83`. Put the choice in one small function.
5. Run `make generate-check` and `make api-compat-check`.

Tests:

- Extend: `server/clusters_test.go:572`, `server/cluster_network_test.go:246`, `server/cluster_control_plane_config_test.go:415,432,975`, `server/control_plane_vip_upgrade_test.go:22`, `nodes/control_plane_delete_request_test.go:478`, `controllers/controlplane/upgrade_test.go:96`, `remediation_test.go:653`, `rebalance_test.go`, `controllers/nodepool/controller_test.go:640,716`.
- `temporal/activities/configure_kube_vip_test.go`: a cluster with the endpoint makes zero `ReconcileKubeVip` calls.
- New: a table test for the endpoint choice. The agent found no test of `kubeadm_init.go:80-83`.
- Later: nvkectl (`sitespec.go:870-876`) and an e2e beside `controller/test/e2e/no_vip_scale_test.go`. The lab does not need them.

## 4. Not determined from the source

- If `kubeadm init` completes when the endpoint does not yet forward to the first node. NVKE sets up kube-vip before init today (`provision_cluster.go:63-70`). Deduction: the host Service must forward to a pod that is not ready. Gate 4 of phase 0 has lab evidence for this point.
- If a control plane pod can reach its own Service address. With kube-vip the VIP is local on `lo`. In the new mode the kubelet and OVN dial the endpoint through the load balancer. Gate 4 put the address in the guest for this reason.
- The result of `make api-compat-check`. The agent did not run it.
- If the API owners want one `host:port` string or two fields, and a public or a hidden field.
- If kubeadm upgrade and certificate renewal on the agent keep the endpoint SAN. The agent did not read those agent paths.
- If a dashboard or alert reads an empty `control_plane_vip` label as "one node" (`dbmetrics/dbmetrics.go:162`).
- Which pages in `docs/` and `fern/` repeat the VIP rule. `openapi.yaml` repeats it at lines 140, 946, 1238, 1410, 1497, 1506, 1654, 1910, 1961 and 1987.

## Files that the change touches most

- `controller/api/openapi.yaml`
- `controller/internal/db/clusters.go`
- `controller/internal/server/clusters.go`
- `controller/internal/server/control_plane_vip.go`
- `controller/internal/temporal/activities/kubeadm_init.go`
