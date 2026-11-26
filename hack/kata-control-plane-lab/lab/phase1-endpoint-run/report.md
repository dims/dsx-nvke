# Phase 1, step 7: the lab run with the shared LoadBalancer address as the control plane endpoint

Date: 2026-11-26, 12:29 to 13:01 local time (17:29 to 18:01 UTC). A test agent ran the work and returned this report as text. The main session wrote the file. Scripts: this folder, with the originals in `/scratch/kata-cp/work/phase1-endpoint-run/`. Logs: `/scratch/kata-cp/logs/phase1-endpoint-run/`, with `progress.txt`. Times in the tables are UTC. "Deduction" marks what is not tested.

The NVKE change of this run: the request field `controlPlaneEndpoint`, branch `feat/control-plane-endpoint`, commit `c6d669ef` (`results/phase1-endpoint-change.md`).

## Result

Both runs pass, with each extra rule. The controller of the branch started on the first try, and the migration ran on PostgreSQL. The flow needed no code change.

In the replace test of the first node the shared address answered 364 of 364 calls. The dry run had the endpoint down for about 31 s in that test.

The second cluster is up with the new controller.

The controller `c6d669ef` is six commits newer than the agent of the node image (`bcc4376f`): three of main and three of the branch. The folder `agent/` has no difference between the two commits. No agent call failed (79 calls in e1, 88 in e2, 0 errors).

## 1. Verdict

Seconds after the POST. "Provisioned" is the end of the `ProvisionCluster` workflow. The 10 s poll saw it at 166.5 and 166.4.

| Run | Verdict | POST (UTC) | Machines bound | Helper wrote the data | Provisioned | Three provisioned nodes (poll) | Three Ready nodes | First node |
|---|---|---|---|---|---|---|---|---|
| e1 | Pass | 17:38:08.3 | 35.8 | 38.2 to 38.6 | 157.4 | 208.1 | 208.9 | host c (.223) |
| e2 | Pass | 17:46:34.5 | 36.5 | 37.4 to 37.7 | 158.0 | 228.9 | 245.3 | host b (.222) |

The extra rules, equal in both runs (`e*/endpoint-final.txt`, and `e2/endpoint-after-replace.txt`):

| Rule | Seen |
|---|---|
| kubeadm `controlPlaneEndpoint` | `172.30.255.220:6443` in the `kubeadm-config` ConfigMap. `cluster-info` has the same server |
| API server certificate | Each of the 3 nodes has the SAN `IP Address:172.30.255.220` next to its own address and `10.112.0.1` |
| Kubeconfig of NVKE | The Secrets `kata-cp1-kubeconfig` and `kata-cp1-admin-kubeconfig` in `nvke-system` have the server `https://172.30.255.220:6443`. The REST API has no kubeconfig path |
| Join strings | 2 `kubeadm join` commands in the agent journals, each one with `172.30.255.220:6443`. In step 5 it was the address of the first node |
| No kube-vip | Manifests in each node: etcd, kube-apiserver, kube-controller-manager, kube-scheduler only. 0 kube-vip containers. 0 `ReconcileKubeVip` calls in the agent journals. The 4 runs of `ConfigureKubeVip` in the Temporal history end in 10 to 21 ms with an empty result |
| GET | Returns `"controlPlaneEndpoint":"172.30.255.220:6443"`, and no `controlPlaneVIP` |
| PATCH with the field | HTTP 400: `property "controlPlaneEndpoint" is unsupported`. The cluster did not change |

The files of kubeadm in the nodes: `admin.conf` and `super-admin.conf` use the shared address. `kubelet.conf`, `controller-manager.conf` and `scheduler.conf` use the own address of the node.

## 2. Order of work

1. The Helm revision before the change was 1. The rollback is `/scratch/kata-cp/work/phase1-endpoint-run/ctl.sh rollback 1`. It was not run.
2. Upgrade with `ctl.sh upgrade` and a copy of the values file (tag `c6d669ef`, `allowControlPlaneWithoutVIP: false`). The rendered manifests differ only in the image, the setting and the config checksum. It took 12 s. Revision 2. No file in `phase1-stack/` changed.
3. Checks after the upgrade:
   - The migration `20261126120000` ran at 17:30:15. The column `clusters.control_plane_endpoint` exists (text, NULL).
   - Version `v0.24.0-beta.18-6-gc6d669ef`. `/readyz` answers, 0 restarts. The new worker polls the task queue.
   - Cluster 3 of step 5 stayed provisioned. Its GET had no `controlPlaneEndpoint` key, and its 3 nodes kept all conditions.
   - The log of the start has 1 ERROR of the database logger ("transaction has already been committed or rolled back"), the same as at the first install.
4. Delete of cluster 3 with the new controller: the same behavior as in step 5. The workflow completes 3.6 s after the two operator steps. The empty check passes.
5. Gate checks. Each one gives HTTP 400, and the cluster list stayed empty:
   - The old request with 3 nodes, no VIP and no endpoint: `controlPlaneVIP or controlPlaneEndpoint is required to increase desired control-plane capacity above one; recreate the cluster with one of them configured`
   - Both fields: `controlPlaneEndpoint and controlPlaneVIP are mutually exclusive; set only one of them`
   - The endpoint `10.112.0.50:6443`: `controlPlaneEndpoint "10.112.0.50:6443" overlaps network.serviceCIDR "10.112.0.0/16"`
6. The request is the step 5 request plus `"controlPlaneEndpoint": "172.30.255.220:6443"`.

## 3. The shared address

- Service `cp-api` in the namespace `phase1-ep`: LoadBalancer, address 172.30.255.220, port 6443, selector `p1-role: control-plane`. The address was free.
- Choice: no `publishNotReadyAddresses`. The Service forwards only to a ready pod, and the readiness probe of a host pod is `/readyz` of its API server, each 2 s. This is the form of gate 4.
- Why: a Service that forwards to all three pods sends 2 of 3 calls to a pod with no API server during init. The probe on the own addresses also shows what the gate hides: each API server gave 403 and then 500 for 1 to 3 s at its start. The shared address gave only 200 or no answer.
- What a real load balancer does: the same. It takes a backend when its health check passes. Its check interval is longer than 2 s in most products, so the endpoint appears later.
- Seen in e2, from the audit log of the first API server (`e2/audit-sources-init.txt`):
  - The 33 requests of kubeadm during init came from the own address of the node, 17:47:59 to 17:48:02, before the shared address answered (17:48:04). So `kubeadm init` did not need the endpoint for its own calls.
  - The first client of the shared address was Helm of the CNI install at 17:48:09.
  - Deduction: with a slow health check the CNI install can start before the endpoint answers. Not tested.
- The own Service address works:
  - Each guest called the shared address 30 times, with 30 of 30 passes in both runs and after the replace. Each guest also got answers from its own node (6 to 14 of 30).
  - The 113 Helm requests of the first node went through the Service while that node was the only endpoint.
  - The API server sees the source 10.244.0.1 for each call through the Service.
- The address is not on an interface of a guest (`lo` has only 127.0.0.1). So the drain guard risk of the change report does not apply.

## 4. What NVKE sees at each step, against step 5

Seconds.

| Step | Step 5 (r1, r3) | e1 | e2 |
|---|---|---|---|
| `WaitForControlPlaneNodeReadyToJoin` | 70.2, 70.0 | 70.0 | 70.0 |
| `NodePreflight` (attempt 1 fails, retry 30 s) | 30.1 | 30.1 | 30.1 |
| `KubeadmInit` | 20.1 | 20.1 | 20.1 |
| `InstallCNI` | 3.1 | 3.3 | 3.1 |
| `InstallKubeLocalDNS` (attempt 1 fails, retry 60 s) | 60.2 | 60.3 | 60.2 |
| `KubeadmJoin`, second and third node | 30.7 and 20.0, 30.2 and 20.1 | 20.3 and 20.1 | 30.3 and 30.1 |

- No retry because of the endpoint. The failed attempts are the same as in step 5. No workflow run failed. The race of step 5 in the etcd quota check did not occur.
- The shared address answered 9 s after the API server container started (e1).
- NVKE made no call to the agent for kube-vip.

## 5. The replace of the first node

Run e2, host b, node `kata-cp1-cp-30bdc549`.

- Probe from the kind node, one call each second for 372 s:
  - Shared address: 364 calls, 0 failed.
  - Own address of the node: 9 calls failed, 17:51:59 to 17:52:11 (about 14 s).
- After the pod delete: the old pod is gone after 8.8 s, systemd is up after 13.3 s, `/readyz` of the new pod answers after 19.8 s, the new kubelet heartbeat comes after 36.1 s, and etcd is healthy after 36.4 s.
- NVKE, one poll each 10 s for 360 s:
  - The cluster stayed `provisioned` in 35 of 35 polls.
  - The node had `kubernetesReady` not True in 1 poll (17:52:25). `nodeAgentReady` stayed True in all polls.
  - NVKE started no workflow.
- The helper wrote 1 file 2 s after systemd was up and ran no command. The first NVKE call to the new agent came at 17:52:17.
- After the replace: the pass rule passes, the endpoint checks pass, the reach test gives 30 of 30 from each guest, and etcd has 3 started members, all healthy.

## 6. Failures and their causes

1. e1: the shared address failed for 3 calls (about 6 s) at 17:39:59, 14 s after the CNI install, while the first node was the only endpoint. NVKE had no failed step from it. It did not occur in e2. The cause is not found. Deduction: one failed readiness probe (threshold 1) removed the only endpoint.
2. A fault of the run script: `run.sh endpoint` stopped with no result after the replace, because the new boot of the replaced node has no join line in its journal. Corrected, and the second call passed.
3. As in step 5, in each run: `NodePreflight` attempt 1 fails (30 s), `InstallKubeLocalDNS` attempt 1 fails (60 s), 1 error of the `tenant-access` reconciler, and warnings about failure domains.
4. The delete still needs the two operator steps. They were used for cluster 3 and for e1, each with an empty state after.

## 7. Not tested

- A health check slower than 2 s, a DNS name as the endpoint, and an endpoint with no port.
- The gates for scale, upgrade, rollout, node delete and remediation with the field. Only the create gate ran.
- The endpoint SAN after an upgrade and after a certificate renewal. NVKE plans the renewal of e2 for 2026-11-27 05:46 UTC.
- A Helm rollback. The new column would stay in the database.
- Pod traffic between nodes (not measured again), and a call to the shared address from outside the kind node.
- The delete of e2.

## 8. Files and state

- Scripts in this folder: `ctl.sh` (Helm history, upgrade, rollback, status, database column), `run.sh` (step 5 plus `endpoint`, `patch-check`, `reach`, `probe-start`, `probe-stop`, `replace-init`), `delete.sh`, `steps.sh`, `api-service.yaml.tmpl`, `request.json.tmpl`, `values/controller-values.yaml`, `gates/*.json`.
- Logs in `/scratch/kata-cp/logs/phase1-endpoint-run/`: `01` to `05` (upgrade), `gates/`, `c3-delete/`, `e1/`, `e2/`.
- Secrets are in `secrets/` folders with mode 700 (the old Helm values with the database password, rendered manifests, raw logs, workflow histories, a kubeconfig). They are not in the notes.
- Timing: the load average was 0.8 and 2.2 at the two starts (24 CPUs). The step times are equal to step 5.

State at the end of the run:

- Controller: Helm revision 2, image `nvke-controller:c6d669ef`, `allowControlPlaneWithoutVIP: false`, ready, 0 restarts.
- Cluster `kata-cp1` with the endpoint `172.30.255.220:6443`, provisioned. Pods `cp-a-0`, `cp-b-0` (replaced one time) and `cp-c-0`, and the Services `cp-a`, `cp-b`, `cp-c` and `cp-api`, in the namespace `phase1-ep`.
- The helper runs in `nvke-lab-bootstrap-helper` for `phase1-ep`.

How to look at it:

- `/scratch/kata-cp/work/phase1-stack/api.sh get /api/clusters` gives the cluster with its ID.
- `docker exec kata-cp-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf -n phase1-ep exec cp-a-0 -c node -- kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide`. This call uses the shared address.
- `LOG_DIR=/scratch/kata-cp/logs/phase1-endpoint-run/e2 CLUSTER_NAME=kata-cp1 /scratch/kata-cp/work/phase1-endpoint-run/run.sh check <label>`, and the same with `endpoint <label>` or `reach <label>`.

How to remove it: `LOG_DIR=/scratch/kata-cp/logs/phase1-endpoint-run/e2 CLUSTER_NAME=kata-cp1 /scratch/kata-cp/work/phase1-endpoint-run/delete.sh all`. It is the delete with the two operator steps.
