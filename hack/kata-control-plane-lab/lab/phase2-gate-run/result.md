# Phase 2, exit gate: certificate renewal, etcd encryption with key rotation, Kubernetes upgrade (result)

Machine: `the second test machine`, 2026-11-27 04:36 to 06:07 UTC.
Provider: `cluster-api-provider-podvm:bb15b535`, no change. NVKE controller: `nvke-controller:c6d669ef`, no change, default settings (Helm release revision 1, no Helm change in this task). Agent: commit `f240606c` in each node image.
Scripts: `/scratch/kata-cp/work/bigbox/remote/p2-gate/` (they load `p2-worker/run.sh` and the scripts under it). The same files are in `/root/kata-cp/` on the machine.
Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/p2g/` (copy of `/root/kata-cp/logs/p2g/`, no secrets folder). Run folders: `g-1` (G2 and G1, the cluster of step 8), `g-2` (G3, a new cluster), `g-2u` (the unblock step of G3).

Each change went through the NVKE API, with two exceptions that the coordinator allowed in this task: the start of the forced certificate renewal and the start of the key rotation, each with the command of its product page. I started these two workflows and did nothing else to any workflow. No file by hand in a guest. No database write. No Helm change.

## 1. Verdict

| Test | Verdict | Main facts |
|---|---|---|
| G2, etcd encryption on | PASS | `PATCH` with `enableEtcdEncryption: true`. Workflow completed in 5 min 39.9 s. Old Secret readable, new Secret stored with `k8s:enc:secretbox:v1`. Healthy after it. Shared address 353 of 357 with 200 |
| G2, key rotation | PASS | Operator start of `RotateEtcdEncryptionKey`. Completed in 5 min 37.9 s. No static pod restart. Old and new Secret readable and stored under the new key name. Shared address 357 of 357 |
| G1, certificate renewal | PASS by its pass rules, with one finding | Operator start of the forced `RenewK8sCertsV2`. Completed in 9 min 49.1 s. Each certificate has a later end date. Healthy after it. During it the worker Node was NotReady two times, because the kube-vip guard has nothing to do in this cluster. Shared address 587 of 593 with 200 |
| G3, Kubernetes upgrade 1.35.5 to 1.36.4 | PASS at the end, with one stop in between | A second node image was built in 20 s. Two control plane nodes were replaced by NVKE alone. The third waited 16 min 53 s for a volume place on its host node, which the worker held. After I freed the place through the NVKE API the upgrade ended by itself: each node on v1.36.4 with the image p5, add-on step completed, healthy. Shared address 1615 of 1619 with 200 |
| etcd backup and restore | None in NVKE at this commit | Section 8 |

The cluster that stays up is the cluster of G3: three control plane nodes and one worker, Kubernetes 1.36.4, image p5.

## 2. How each flow starts in NVKE

Paths are under `/scratch/kata-cp/src/nvke-endpoint/controller/` when they have no other root.

| Flow | Start | Source |
|---|---|---|
| Certificate renewal, scheduled | A controller. At its first look at a cluster it sets `nextCertRenewalDue` to now plus `certRenewal.interval` (12 h here, allowed 1 h to 24 h). At that time it starts `RenewK8sCertsV2` with `certRenewal.thresholdDays` (30 here, allowed 7 to 90). A scheduled cycle renews a node only when a leaf certificate ends inside the threshold. The certificates of a new cluster are good for 365 days, so a scheduled cycle renews nothing there | `internal/controllers/certrenewal/controller.go:66-94`, `internal/config/config.go:245-251`, `internal/config/credential_monitoring.go:23-27`, `docs/certificate-renewal.md:6-33`, `:68-70` |
| Certificate renewal, forced | No API request and no CLI: "an operator-started Temporal workflow". The page gives the command | `docs/certificate-renewal.md:167-189`, workflow `internal/temporal/workflows/renew_k8s_certs.go:160` |
| etcd encryption on | `PATCH /clusters/{id}` with `enableEtcdEncryption: true`. `false` is refused. One way only. The API puts the workflow `enable-etcd-encryption-<cluster ID>` on its queue | `api/openapi.yaml:1703-1708`, `internal/server/clusters.go:642-644`, `:720-745`, `internal/constants/constants.go:15`, workflow `internal/temporal/workflows/enable_etcd_encryption.go:66-150` |
| Key rotation | No API request and no automatic rule: "the operator-initiated NVKE controller Temporal workflow". The page gives the command. It needs encryption on and Kubernetes 1.34 or newer | `docs/etcd-encryption-key-rotation.md:3-13`, `:16-60`, `:162-194` |
| Kubernetes upgrade | `PATCH /clusters/{id}` with `controlPlaneKubernetesVersion`. The version must be newer, at most one minor ahead, and each worker pool must stay within 3 minors. The API takes any `X.Y.Z`. The control plane controller then updates the kubeadm ConfigMap, replaces each control plane node by a new node, and runs the add-on workflow | `api/openapi.yaml:1689-1698`, `internal/server/clusters.go:690-717`, `:1583-1619`, `internal/controllers/controlplane/k8s_upgrade.go:42`, `:83`, `:121`, `:234`, `:292` |
| What an upgrade needs from the node image | "The API accepts any `X.Y.Z`, but nodes run only a version their node image carries." The supported version is 1.36.3. The product way for a local cluster is to build the node image again from the `kindest/node` tag of the target, then to send the `PATCH` | `docs/overview/supported-platforms.md:11-14`, `docs/kubernetes-minor-versions.md:1-10`, `hack/capd-upgrade.sh:5-10` |
| Worker pool, new version | `PATCH /nodePools/{id}` with `kubernetesVersion` and `infra.machineTemplate` makes a new node set. With a recycle budget NVKE only marks the old nodes (`NeedsRecycle`). Another component removes them | `api/openapi.yaml:699-704`, `internal/controllers/automode/controller.go:93-131` |
| kube-vip guard | A node guard of the rollout framework: before the change on a node the controller starts a kube-vip drain on the agent, after it a restore. The agent skips both when it finds no kube-vip manifest and no address of it on `lo` | `internal/rollout/guards/kubevip/guard.go:42-176`, agent `agent/internal/agent/control_plane_graceful_shutdown.go:228-250` (line 244), `:388-410` (line 405) |

## 3. G2: etcd encryption

### Encryption on (04:44:55 to 04:50:35)

Cluster of step 8 (`8caca331-...`, Kubernetes 1.36.4, three control plane nodes, one worker, made with `etcdEncrypted: false`).

| Phase of the workflow | Time (UTC) | For each node |
|---|---|---|
| Checks, pending key | 04:44:55.9 to 04:44:57.1 | |
| Initialize, with the kube-vip guard (API server restart) | 04:44:57 to 04:46:39 | `43a3c6ef` 30.7 s, `5f019555` 30.7 s, `9b859b18` 40.7 s |
| Promote (reload, no restart) | 04:46:40 to 04:48:36 | 46.2 s, 28.2 s, 42.2 s |
| Rewrite of the stored objects | 04:48:36 to 04:49:07 | one node |
| Remove the plain text entry | 04:49:07 to 04:50:35 | 18.7 s, 28.6 s, 40.6 s |
| kubeadm ConfigMap, key final, done | 04:50:35.8 to 04:50:35.9 | |

- Order of the nodes in each phase: `kata-cp1-cp-43a3c6ef`, `kata-cp1-cp-5f019555`, `kata-cp1-cp-9b859b18`.
- kube-vip guard, for each node: `rollout.node_guard_pre_apply`, the agent logs "kube-vip is not configured; skipping kube-vip withdrawal", the check passes 10 s later, the change runs, then `rollout.node_guard_post_apply` and the agent logs "kube-vip is not configured; skipping kube-vip restore".
- Each API server got a new container (04:45:23, 04:45:51, 04:46:33) with `--encryption-provider-config=/etc/kubernetes/kube-api-encryption/encryption-config.yaml` and automatic reload. On the third node the controller manager and the scheduler restarted one time.
- Secrets: `p2g-before` was stored as plain protobuf before (`k8s.....v1..Secret...`). After it: readable with the same value, and stored as `k8s:enc:secretbox:v1:current-primary-encryption-...`. The new Secret `p2g-after` has the same prefix. I read at most 48 bytes of my own test Secrets.
- Shared address: 357 calls, 353 with 200, 4 with 500 (04:45:08, 04:45:09, 04:45:42, 04:46:11), one or two at each API server restart. No call was without an answer.
- Provider: 0 log lines. Its pods had no change (UID, host node, restart count).
- After it: NVKE `etcdEncrypted: true`, 4 good nodes, 4 Ready nodes, 3 healthy etcd members, pod traffic 16 of 16 lines, API server calls to the pod on the worker pass. No Node lost Ready.

### Key rotation (04:52:58 to 04:58:35)

Start, as `docs/etcd-encryption-key-rotation.md:186-194` says (namespace, queue and address from the controller config):

```
temporal workflow start --address temporal-frontend.temporal.svc.cluster.local:7233 --namespace cloud-workflow-engine --type RotateEtcdEncryptionKey --task-queue cloud-workflow-engine-tasks --workflow-id etcd-key-rotation-8caca331-bf11-415b-9742-851cbe3b4b45-20261127T045236Z --id-reuse-policy RejectDuplicate --id-conflict-policy Fail --input '{"clusterID":"8caca331-bf11-415b-9742-851cbe3b4b45"}'
```

Before the start, as the page asks: `etcdEncrypted: true`, no update in progress, API servers v1.36.4, the three agents on `v0.24.0-beta.18-4-gf240606c` (the page allows the probe of the prepare phase as the proof of the identity RPC, and it passed), and a copy of the whole key Secret into the mode 700 secrets folder of the machine (427 bytes, not printed).

| Phase | Time (UTC) | For each node |
|---|---|---|
| prepare | 04:52:58.1 to 04:52:58.7 | |
| add_secondary | 04:52:59 to 04:54:36 | 26.5 s, 27.7 s, 42.6 s |
| promote_primary | 04:54:36 to 04:56:35 | 50.1 s, 27.8 s, 40.5 s |
| rewrite, membership check | 04:56:35 to 04:57:08 | |
| remove_old_keys | 04:57:09 to 04:58:35 | 15.6 s, 29.9 s, 40.8 s |
| finalize | 04:58:35.9 | |

- Workflow completed in 5 min 37.9 s. NVKE: `conditions.etcdKeyRotation.state: succeeded`, lock free.
- No static pod got a new container. The keys reload.
- Secrets: the one written before is readable and now stored as `k8s:enc:secretbox:v1:kube-api-encryption...` (a new key name). The new one has the same prefix.
- The membership probe of the workflow ran a script with `jq` on a node. The node image has `jq`.
- Shared address: 357 of 357 with 200. Provider: 0 log lines. Health and traffic pass after it.
- The key Secret of the controller has the fields `active`, `active-name`, `active-since` before and after (names only).

## 4. G1: certificate renewal

A scheduled cycle would renew nothing on this cluster (section 2), and its time was 14:10 UTC. So the test is the forced cycle.

Start, as `docs/certificate-renewal.md:183-188` says:

```
temporal workflow start --address temporal-frontend.temporal.svc.cluster.local:7233 --namespace cloud-workflow-engine --task-queue cloud-workflow-engine-tasks --type RenewK8sCertsV2 --workflow-id operator-k8s-cert-renewal-20261127T050017Z-3bad3555-33da-40bc-b2af-6d2eb6992922 --input '{"clusterID":"8caca331-bf11-415b-9742-851cbe3b4b45","thresholdDays":30,"force":true}'
```

| Node | Guard before | `RenewKubernetesCertificates` | Guard after | New end date of the certificates |
|---|---|---|---|---|
| `kata-cp1-cp-43a3c6ef` | 05:00:39.5 | 05:00:49.7 to 05:03:35.0 (165.3 s) | 05:03:35.0 | Nov 27 05:00:50 2027 (was 02:50:35) |
| `kata-cp1-cp-5f019555` | 05:03:45.6 | 05:03:55.7 to 05:06:36.1 (160.3 s) | 05:06:36.1 | Nov 27 05:03:56 2027 (was 02:53:23) |
| `kata-cp1-cp-9b859b18` | 05:07:07.0 | 05:07:17.1 to 05:10:17.5 (180.4 s) | 05:10:17.5 | Nov 27 05:07:17 2027 (was 02:48:06) |

- Workflow: started 05:00:38.98, completed 05:10:28.08 (9 min 49.1 s). NVKE: `certificateRenewal.state: succeeded`, `outcome: renewed`, `forced: true`. `nextCertRenewalDue` moved to 17:10:28. Lock free.
- On each node the agent ran `kubeadm certs renew all` and then restarted etcd, the API server, the controller manager and the scheduler, one after the other. etcd of a node was down for about 80 s (first node: 05:00:50 to 05:02:09).
- Checked certificates on each node: `apiserver`, `etcd/server`, `etcd/peer` (each 2.2 to 2.3 hours later than before). The other leaf certificates and the three kubeconfig files have the same new date.
- kube-vip guard: the same two agent lines as in G2 ("kube-vip is not configured; skipping ..."), for each node.
- Provider: its pods had no change. It logged three lines "API server of the new cluster does not answer, the provider ID of the Node waits" (05:01:25, 05:01:55, 05:02:25): three calls to the shared address ran into their 30 s limit.
- After it: 4 good nodes in NVKE, 4 Ready nodes, 3 healthy etcd members, pod traffic 16 of 16, API server calls to the pod on the worker pass.

### Finding: what the missing kube-vip drain costs

| Time (UTC) | Event in the new cluster |
|---|---|
| 05:01:59 to 05:02:51 | `kata-cp1-cp-43a3c6ef` NotReady (its own renewal) |
| 05:04:45 | the worker `kata-cp1-wk-0495` NotReady |
| 05:04:50 to 05:06:02 | `kata-cp1-cp-5f019555` NotReady (its own renewal) |
| 05:08:29 to 05:09:26 | the worker NotReady again |
| 05:08:29 to 05:09:33 | `kata-cp1-cp-9b859b18` NotReady (its own renewal) |

- The kubelet of the worker logged "Failed to update lease ... https://172.29.255.220:6443 ... timeout=10s" from 05:07:37 to 05:08:37. Its connection through the shared address was on the API server of the node under renewal, and that API server had no etcd for about 80 s.
- Shared address probe: 593 calls, 587 with 200. 4 calls had no answer in 2 s (05:00:52, 05:00:55, 05:03:57, 05:07:23) and 2 got 500 (05:03:02, 05:04:02).
- The product page says what the guard is for: it "removes kube-vip from the node and waits for VIP connections to drain before the apiserver restarts, so worker kubelets pinned to that node fail over instead of going NotReady" (`docs/certificate-renewal.md:76-86`, which also says "Nodes without kube-vip skip the drain"). In a cluster of the provider the shared address is a Service of the host cluster, the agent finds no kube-vip, and the guard does nothing. The pod of the node stays behind the Service until its readiness probe fails, and a connection that exists stays on it.
- No pod was moved off the worker (NotReady for less than a minute each time). It is a gap of the design for the shared address, not a fault in the provider code, the agent fix or the node image. The same gap gives the 500 answers in G2 and in each teardown.

## 5. G3: Kubernetes upgrade

### The second node image

- `kindest/node` tags that exist for an older version: `v1.36.1`, `v1.35.5`, `v1.35.1`, `v1.35.0`. I took `v1.35.5` (one minor below 1.36.4).
- `nvke-node-podvm:bcc4376f-p5-k1355` = the image p5 with three binaries (`kubeadm` as `/usr/bin/kubeadm.real`, `kubelet`, `kubectl`) and the control plane images of `kindest/node:v1.35.5`, read from that image in a first build stage (`p2-gate/image/Dockerfile.k8s`, `build-k8s.sh`). The same agent, containerd, Open vSwitch and CNI.
- kubeadm 1.35.5 asks for `registry.k8s.io/pause:3.10.1`. The kindest image carries `pause:3.10`. The first build stopped at my check for that. The machine pulled that one public image and the second build has it.
- Build 20 s, save and load into the three host nodes 90 s. In the image: kubeadm v1.35.5, kubelet v1.35.5, the seven images that kubeadm asks for, marker `bcc4376f-p5-k1355`.
- So a second image is possible with small effort when the other version has a `kindest/node` image. A full build of the base image (`hack/capd-kindest-node/`) was not needed and not done.

### The cluster with 1.35.5

The cluster of G1 and G2 was deleted through the NVKE API (row and objects gone after 46.1 s, nothing left, also not the key Secret). New cluster `kata-cp1`, NVKE ID `e626b015-cd52-419b-a3f9-8f882365b017`, `controlPlaneKubernetesVersion: 1.35.5`, image `p5-k1355`.

| Time after the POST (05:18:10) | 1.35.5, this run | 1.36.4 with p4 (last task) |
|---|---|---|
| Three started containers | 130.6 s | 113.2 s |
| Provisioned | 225.5 s | 208.4 s |
| Three provisioned nodes | 288.3 s | 312.9 s |
| Three Ready nodes | 316.1 s | 348.8 s |

Flow PASS. Worker pool `workers` with one node: good after 99.0 s. Health PASS, pod traffic 16 of 16. Each node reported kubelet v1.35.5.

### The upgrade

`PATCH /api/clusters/<id>` at 05:27:58 with `controlPlaneKubernetesVersion: "1.36.4"` and `controlPlaneConfig.infra.machineTemplate` (image p5) in one request. HTTP 200.

| Step | Time (UTC) | Result |
|---|---|---|
| kubeadm ConfigMap to v1.36.4 | 05:27:58.4 to 05:27:58.8 | workflow `update-kubeadm-configmap-<id>-1.36.4`, 0.43 s |
| Node 1: new `8bc7bac7` on `kata-bb-worker2` | 05:27:58 to 05:30:30 | `WaitForCAPIMachineReady` 45.2 s, join 41.4 s (a v1.36.4 node joins the v1.35.5 cluster), teardown of `35bb1322` 28.9 s. 151.8 s |
| Node 2: new `41b1d0a0` on `kata-bb-worker` | 05:30:31 to 05:33:40 | join 50.8 s, teardown of `3781e59d` 33.9 s. 189.1 s |
| Node 3: new `d10b34e5`, failure domain `kata-bb-worker3` | 05:33:41 | **the pod stays Pending** (below) |
| Place free | 05:50:03 to 05:50:34 | DELETE of the worker on that host node, the pod is scheduled 31 s later |
| Node 3 goes on | 05:50:34 to 05:52:45 | agent answers 05:51:08, join 31.2 s, teardown of `089ab948` 29.6 s. 131 s from the scheduling |
| Add-on step | 05:52:46.2 to 05:54:40.4 | workflow `kubeadm-upgrade-<id>-1.36.4` completed: `KubeadmUpgradeApply` 113.6 s, `InstallKubeLocalDNS`, `LabelSystemNamespacesForPSA` |
| NVKE: "Control plane upgrade completed successfully" | 05:54:55 | 1636.4 s after the PATCH, 1006 s of it the wait |

At the end: each control plane Node reports kubelet v1.36.4, each static pod of API server, controller manager and scheduler runs the image of v1.36.4, etcd `3.6.8-0`, each control plane pod has the image p5, the kubeadm ConfigMap says v1.36.4, CoreDNS runs v1.14.2 (kubeadm 1.35.5 asks for v1.13.1). Health PASS, pod traffic 16 of 16, API server calls to the pod on the worker pass. Provider: 0 error lines.

Shared address during the whole upgrade (27 minutes): 1619 calls, 1615 with 200. 2 with 500 (05:33:18, 05:33:19, the teardown of the second old node) and 2 with no answer in 2 s (05:53:21, 05:53:26, in the add-on step, when `kubeadm upgrade apply` ran on one node and its etcd got a new container).

### The stop at the third node

- NVKE gave the surge Machine `kata-cp1-cp-d10b34e5` the failure domain `kata-bb-worker3`, the host node of the old node that it replaces next (the same rule as in the rollout of the last task).
- On `kata-bb-worker3` the two Machine places of the lab storage were taken: the old control plane node and the worker (a worker Machine has no failure domain, the scheduler had put it there).
- The pod: `FailedScheduling: 0/4 nodes are available: 1 node(s) didn't find available persistent volumes to bind, 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector`.
- NVKE has a rule for a control plane node that is pending for 15 minutes in a domain with no capacity: it places it again in another domain (`internal/controllers/controlplane/stuck_pending.go:23-47`, `:74-110`). The rule asks the provider client if the domain is out of capacity, and the client for a template provider always says no (`internal/clients/capi/rotation.go:28-31`). At 05:49:52, 16 minutes after the Machine was made, nothing had changed and the controller had logged no line about it.
- So the upgrade would have waited without end. Cause: the lab storage has two Machine places for each host node, and a worker can take the spare place that the control plane needs for its surge. With a storage driver that makes volumes on request it would not stop. In the design it is a point for the provider (a signal "no capacity in this domain") or for NVKE.
- How I freed the place, through the NVKE API, with a worker in the cluster at each moment: pool count 2 (a second worker came up on `kata-bb-worker2`, good after about 90 s), pool count 1, `DELETE /api/nodes/<id>` of the worker on `kata-bb-worker3`. The surge pod ran 41.2 s after that DELETE.
- In the first two node replacements and during the wait the workers on v1.35.5 stayed Ready with two control plane nodes on v1.36.4. No Node lost Ready in the upgrade.

### The worker pool

- The upgrade of the control plane does not touch a worker pool. The worker stayed on v1.35.5 with the old image and was Ready.
- `PATCH /api/nodePools/<id>` with `kubernetesVersion: "1.36.4"`, the machine template with p5, `recycleBudget: 1`, `maxSurge: 1` (05:56:29, HTTP 200): NVKE made a second node set, set `markedForRecycling` on the old worker and the Node condition `nvke.nvidia.com/NeedsRecycle=True`, and made one new worker from the new node set by itself (good after about 90 s). It did not remove the old worker. The source says another component does that (`internal/controllers/automode/controller.go:99-102`).
- A fault of my script deleted the new worker in the place of the old one (it took the first worker by address). NVKE made the next new worker 35 s later. Then I deleted the old worker by its name through the NVKE API (gone after 24.4 s). NVKE made no more node.
- End: one worker `kata-cp1-wk-4368`, kubelet v1.36.4, image p5. W1 checks PASS, health PASS, traffic 16 of 16.

## 6. Disk values

Write time of `vda` over 10 s, from `/proc/diskstats`. I did not have to wait.

| Before | Write time |
|---|---|
| G2, encryption on (04:44) | 0.8 ms |
| G2, key rotation (04:52) | 1.2 ms |
| G1, certificate renewal (05:00) | 0.9 ms |
| Image build (05:13) | 0.6 ms |
| Delete of the first cluster (05:16) | 0.5 ms |
| G3, cluster with 1.35.5 (05:18) | 0.4 ms |
| G3, worker pool (05:25) | 0.7 ms |
| G3, upgrade (05:27) | 0.5 ms |
| G3, worker deletes (05:59, 06:03) | 0.9 ms, 0.5 ms |
| End (06:06) | 0.5 ms |

## 7. Failures and their causes

No flow of NVKE failed. Each of the 36 workflows of this task completed (1 `EnableEtcdEncryption`, 1 `RotateEtcdEncryptionKey`, 1 `RenewK8sCertsV2`, 1 `UpdateKubeadmConfigMap`, 1 `UpgradeControlPlaneAddons`, and the node and cluster workflows). What went wrong or is not clean:

1. G1: the worker Node NotReady two times and calls on the shared address that waited. Cause: the kube-vip guard has no effect here (section 4). Design.
2. G2, G3: single 500 answers on the shared address at an API server restart or a teardown. The same cause as in the earlier tasks.
3. G3: the stop at the third node. Cause: lab storage (two places for each host node) together with two design points: a worker has no failure domain, and NVKE does not place a pending surge again for a template provider (section 5).
4. G3: my image build stopped one time at my own check (the pause image). Lab, corrected.
5. G3: my script deleted the new worker in the place of the old one. Lab, corrected (the step takes the name of the worker now). No harm: NVKE made the next worker.
6. One command of mine ended its own remote shell (a process pattern that was also in the command). Nothing was lost. I ran the steps again one by one.

## 8. etcd backup and restore in NVKE at this commit

- No API request: `controller/api/openapi.yaml` has no backup, restore or etcd snapshot operation ("snapshot" there means a configuration snapshot).
- No code: the controller and the agent have no `etcdctl snapshot`, no `etcdutl` and no restore step. The agent has etcd defragmentation, health, status, member removal and encryption (`agent/internal/agent/etcd_*.go`).
- The docs say it: "No backup or restore procedure. NVKE provides no procedure to back up or restore the management cluster or the management plane's state" (`docs/overview/preview-status.md:26`). The key rotation page asks the operator for "an established backup/recovery process" of his own and tells him to keep the key Secret with his etcd backups (`controller/docs/etcd-encryption-key-rotation.md:73-83`).
- One page says the opposite in one line: "etcd operations, managed by NVKE with built-in encryption and `etcd-manager` for compaction and snapshots" (`docs/concepts.md:108`). The name `etcd-manager` is nowhere else in the source.

So the plan is right: NVKE has no etcd backup and no restore.

## 9. Not tested

- A scheduled certificate renewal cycle (it renews nothing on a new cluster, and it would need a shorter interval through Helm and an hour of wait). No Helm change was made.
- A failed renewal or rotation and its recovery (reset of a workflow, a retained lock).
- The key rotation on a cluster in the middle of other work, and the lost node procedure of the rotation page.
- An upgrade with enough volume places, so with no stop. An upgrade of an encrypted cluster.
- A full build of the base node image for another version. A version with no `kindest/node` image.
- OIDC enablement, which uses the same guard.
- A worker pool with more than one node in a rollout.

## 10. Changes on the machine and how to remove them

All under `/root/kata-cp` or in the lab cluster. No firewall rule, no listener on an outside interface, no change of the Docker or containerd configuration or of the network settings, no restart, no database write, no Helm change. Temporal: two workflow starts, both completed. Machine checks at the end are unchanged (disk 210 GB of 300 GB, 9 GB more than before). The workstation got only scripts, logs and this file.

What differs from the start of the task:

| Point | Start | End |
|---|---|---|
| Cluster | `kata-cp1`, ID `8caca331-...`, made with 1.36.4 | `kata-cp1`, ID `e626b015-cd52-419b-a3f9-8f882365b017`, made with 1.35.5 and upgraded to 1.36.4. The first cluster is gone (deleted through the NVKE API) |
| Control plane nodes | `43a3c6ef`, `5f019555`, `9b859b18` | `kata-cp1-cp-8bc7bac7` (.5, `kata-bb-worker2`), `kata-cp1-cp-41b1d0a0` (.6, `kata-bb-worker`), `kata-cp1-cp-d10b34e5` (.3, `kata-bb-worker3`), image p5 |
| Worker | `kata-cp1-wk-0495` | `kata-cp1-wk-4368` (.4, `kata-bb-worker`), image p5, v1.36.4 |
| Worker pool | `workers`, `recycleBudget: 0`, no `maxSurge` | `workers` (`21a6ffe6-b569-401a-8c39-51a1d96ff7e1`), `kubernetesVersion: 1.36.4`, `recycleBudget: 1`, `maxSurge: 1`, two node sets (the one of 1.35.5 has no node) |
| etcd encryption | off | off on the cluster that is up (the cluster with encryption on was the first one) |
| Controller settings, provider | | no change |

| Change | Removal |
|---|---|
| The cluster above. It stays up | `LOG_DIR=/root/kata-cp/logs/p2g/g-2 p2-gate/run.sh delete`, then `p2-provider/storage.sh reset` |
| In the new cluster, namespace `default`: test pods and Services `p1-t-a` to `p1-t-d`, ConfigMap `p1-probe` | They go with the cluster |
| Image `nvke-node-podvm:bcc4376f-p5-k1355` in Docker and in the three workers, archive `dl/img/nvke-node-podvm_bcc4376f-p5-k1355.tar` (2.3 GB). `kindest/node:v1.35.5` (1.28 GB) and `registry.k8s.io/pause:3.10.1` in Docker, `dl/img/inner/pause-3.10.1.tar` | `docker rmi`, `ctr -n k8s.io images rm` in each worker, `unlink` of the archives |
| Two closed workflows in Temporal that I started: `etcd-key-rotation-8caca331-...-20261127T045236Z` and `operator-k8s-cert-renewal-20261127T050017Z-3bad3555-...` | Nothing to do |
| A copy of the key Secret of the first cluster: `secrets/d-g-1/etcd-encryption-key-8caca331-...-before-rot.yaml` (mode 600, in a mode 700 folder). The cluster is gone | `unlink` |
| The storage loop: stopped. 8 volumes Bound, 4 Available | Nothing to do |
| Folders `p2-gate`, `logs/p2g`, `work/k8s-image-ctx`, `secrets/d-g-1`, `d-g-2`, `d-g-2u`. One small change in `p2-worker/run.sh` (the worker delete step takes a name) | Remove the folders |
