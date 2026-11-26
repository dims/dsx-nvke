# Phase 1, step 5: the cluster through the real NVKE controller

Date: 2026-11-26, 11:47 to 12:24 local time (16:47 to 17:24 UTC). A test agent ran the work and returned this report as text. The main session wrote the file. Scripts: this folder, with the originals in `/scratch/kata-cp/work/phase1-run/`. Logs: `/scratch/kata-cp/logs/phase1-run/`, with `progress.txt`. Times in the tables are UTC. "Deduction" marks what is not tested.

## Result

The pass rule of phase 1 is met 3 of 3 times from empty volumes. The NVKE controller made a cluster with three control plane nodes on three Kata pods, with no lab client. The create path needed no NVKE code change and no new image.

The delete path is not possible through the API alone. It needs two operator steps. They worked 2 of 2 times and left an empty state.

## 1. Verdict

Times are seconds after the POST. "Provisioned" is the end time of the `ProvisionCluster` workflow. The 10 s poll of the test saw it 1 to 4 s later (157.3, 342.6, 156.2).

| Run | Verdict | POST (UTC) | Machines bound | Helper wrote the data | Provisioned | Three provisioned nodes (poll) | Third kubelet Ready |
|---|---|---|---|---|---|---|---|
| r1 | Pass | 16:47:25.4 | 34.9 | 38.3 to 38.7 | 156.2 | 209.4 | about 207 |
| r2 | Pass at the second check | 17:04:22.5 | 36.8 | 199.5 (fault of the run script) | 338.3 | 405.1 | 417.5 |
| r3 | Pass | 17:15:28.7 | 33.3 | 38.2 to 38.5 | 154.3 | 239.4 | 237.3 |

Each run at the end:

- From the NVKE API, the cluster: `provisioned` True ("Provisioned cluster"), `provisioning` False, `deleting` False, `controlPlaneUpgrading` False, `cpNodesRecycling` Unknown.
- From the NVKE API, each of the 3 nodes: `joined`, `kubernetesReady`, `nodeAgentReady`, `provisioned`, `provisioningClaimed` and `readyToJoin` are True.
- In the new cluster: 3 nodes `Ready control-plane` at v1.36.4 with the addresses .221, .222 and .223, and 3 started etcd members, all healthy.
- 0 container restarts and 0 OOM events.

Timing: the load average was 4.1 at the start of r2 and 0.8 at the start of r3 (24 CPUs). The step times of r1 and r3 are equal within 0.2 s. So the code build that ran on the machine at the same time did not disturb the runs.

## 2. Step times from the Temporal history

Seconds.

| Step | r1 | r2 | r3 |
|---|---|---|---|
| POST to the start of `ProvisionCluster` | 2.3 | 4.5 | 0.7 |
| `WaitForControlPlaneNodeReadyToJoin` | 70.2 | 250.1 | 70.0 |
| Of this: start of the 3 `ProvisionNode` workflows after the cluster workflow start | 30.3 | 30.1 | 30.5 |
| Of this: `WaitForCAPIMachineReady` (attempts 1 and 2 fail, attempt 3 passes) | 3.1 | 3.1 | 3.1 |
| Of this: `NodePreflight` | 30.1 (2 attempts) | 210.1 (4 attempts) | 30.1 (2 attempts) |
| Of this: `ConfigureOpenVSwitch` | 2.0 | 2.0 | 2.0 |
| `KubeadmInit` | 20.1 | 20.1 | 20.1 |
| `InstallCNI` | 3.1 | 3.1 | 3.1 |
| `InstallKubeLocalDNS` (attempt 1 fails, retry after 60 s) | 60.2 | 60.2 | 60.2 |
| `KubeadmJoin` of the second node | 30.7 | 30.2 | 30.2 |
| `KubeadmJoin` of the third node | 20.0 | 30.1 | 20.1, after one failed workflow run and a 30 s wait |

Deduction: about 120 of the 156 s are fixed retry waits of NVKE and not work. They are the 30 s requeue of the control plane reconciler, the 30 s preflight retry and the 60 s DNS retry.

## 3. Changes against the dry run

1. No lab client. NVKE did the preflight, the Open vSwitch step, init, the CNI install, the joins, the labels, the taints and the certificate approvals.
2. The agent runs in mTLS mode. The wrapper has no plaintext setting, writes no file in `/etc/spire-agent` and no cloud-init status.
3. The wrapper puts `/etc/spire-agent` on the `/var` volume (a copy of the image content, then a bind mount from `/var/lib/g1-state/etc-spire-agent`).
4. Each pod has the label `nvke.lab/host: kata-host-a|b|c`, the container name `node`, and the kernel config file of gate 1.
5. Kept from the dry run: the bridge address form, the etcd patch file at each start, the two Open vSwitch image changes as drop-ins, `/dev/net/tun`, `publishNotReadyAddresses`, the ports 15005, 6443, 2379, 2380 and 10250 TCP and 6081 UDP, 2 CPUs and 6Gi, the same six loop devices.
6. The request is the draft with one difference: the host addresses are 172.30.255.221 to .223.
7. Namespace `phase1-run`. The dry run cluster and its namespace were removed first.

## 4. Where the real controller differs from the lab client

- **Identity check.**
  - Before the helper acts, the SPIRE agent unit restarts in a loop and port 15005 is closed. NVKE gets "connection refused".
  - After it, the agent runs with `--secure-server-port 15005` only, and NVKE reports `nodeAgentReady`.
  - The controller ID has the prefix `/nvke-service/`, which the agent accepts (`agent/cmd/agent/main.go:208-229`).
  - The lab arguments and `NKE_LOCAL_DEV` are gone, so kubeadm runs its system check. It passed with the kernel config file.
- **Join token and entry.**
  - NVKE makes one `ClusterStaticEntry host-<node ID>` for each node. The ID is `spiffe://kata-cp.nvke.local/host/<node ID>`. The parent is `spiffe://kata-cp.nvke.local/join-token-spire-agent/host-id/<node ID>`.
  - Each SPIRE agent attested with its token on the first try. The agent record expires 4 h after the attestation.
- **Kubelet serving requests.** Each one is `Approved:NKEValidatedNodeIdentity` 0 to 2 s after its creation. No manual approval.
- **`ProvisionedMachine` bind.**
  - It happens 33 to 37 s after the POST. The provider bound the machines to hosts a, b and c in inventory order and set `provisioned://kata-cp1/<address>`.
  - NVKE chose the node on host a as the first node in 3 of 3 runs. The Machines reach the phase Running with a node reference.
- **Helper timing.**
  - The data arrived 3.4 to 3.7 s (r1) and 4.9 to 5.1 s (r3) after the bind. The token life is 1 h.
  - In r2 it arrived 162.7 s after the bind, and the token still worked.
  - The first write of the helper through the bind mount worked 3 of 3 times (`files=3 commands=1 run=first`).
- **Extra test in r1.** The helper was scaled to 0, then host c got a new container. The SPIRE files were still there, the agent loaded its identity from disk, port 15005 opened, and NVKE kept `nodeAgentReady` and `kubernetesReady`. `/readyz` came 27.9 s after the stop.

## 5. Failures and their causes

Faults of the run scripts, corrected:

1. r2, helper. `run.sh full` exported `IMAGE` (the node image), and it went into the helper manifest. The helper pod failed at once. The correction came 198 s after the POST. NVKE waited in `NodePreflight` (retry after 30, 60, 120 s, with no end, `controller/internal/temporal/workflows/provision_node.go:376-393`) and went on at attempt 4. The log of that first helper write is lost. The file times in the hosts show the write at 17:07:41.9 to 17:07:42.3.
2. r2, check. NVKE reports a node as `provisioned` before its kubelet is Ready. The check looked 11 s after the third join and wrote a failure. The node was Ready 13 s later. The check now waits with one `kubectl wait` call. The second check passed.
3. r1, delete. The poll did not see the 404, so `r1/delete/delete.log` says 342 s. The Temporal history gives the true time (section 7).

NVKE behavior that costs time, with no fault of the run:

4. `NodePreflight` attempt 1 fails in each run, because NVKE calls the agent 1 to 2 s after the bind and the helper needs up to 5 s. Cost: 30 s. Deduction: a provider that gives the data at pod start removes this.
5. `InstallKubeLocalDNS` attempt 1 fails in each run with "waiting for a Ready pod with dns-role=cluster-dns" (`controller/internal/temporal/activities/install_kube_local_dns.go:245`), 3 s after the CNI install. The retry interval is 1 minute (`controller/internal/temporal/workflows/provision_cluster.go:271-285`). Cost: 60 s.
6. r3 only: the first `JoinNode` run of the third node failed after 0.35 s in `KubeadmJoin`: "failed to get etcd mirror Pod for node kata-cp1-cp-41990d57: pods ... not found".
   - The etcd quota check reads the etcd mirror pod of each joined control plane node before it calls the agent (`controller/internal/temporal/activities/kubeadm_join.go:158`, `:233-263`, `:278-283`).
   - The second node had joined 1.3 s before, and its mirror pod did not exist yet.
   - The workflow retry (30 s, 5 attempts, `controller/internal/controllers/controlplane/join.go:27-31`, `:140-153`) passed.
   - This is a race in NVKE. It hit 1 of 3 runs.
7. Each run has 2 warnings "Control-plane failure-domain discovery failed", 4 warnings "No healthy joined control plane nodes found", and 1 error of the `tenant-access` reconciler ("client CSR nvke-breakglass is not signed yet") right after the first join. All go away by themselves.
8. The Cluster API Cluster stays at `ControlPlaneAvailable=Unknown (InternalError)`. It has no control plane reference. NVKE does not use this condition.

## 6. Pod traffic between nodes

- No NVKE step waits for something that the fault of the dry run breaks. No step waits for a DaemonSet.
- The DNS step needs only a Ready CoreDNS pod, and that pod is on the first node.
- Node health uses the kubelet Ready condition and the agent call over the node address.
- On the second and third node the `ovnkube-node` pod has 4 of 5 containers ready, as in the dry run. NVKE still reports all nodes as provisioned.
- Pod traffic was not measured again in this step.

## 7. The delete path, a finding for NVKE

Seen in r1 and r2, equal in both:

- `DELETE /api/clusters/<ID>` gives HTTP 202. The node rows, the bootstrap Secrets and the `ClusterStaticEntry host-*` objects go away within 22 s.
- Then the workflow `teardown-cluster-<ID>` stays in the activity `DeleteCAPIClusterResources`, attempt 1, with the heartbeat "3 machines remaining". The cluster message stays "Deleting etcd encryption key secret".
- The 3 Machines are in the phase Deleting and wait for their `ProvisionedMachine`. The 3 `ProvisionedMachine` objects keep the provider finalizer with `DeletionNotSupported`. The 3 host claims stay. The state did not change for 65 s.
- Source:
  - The provider refuses the delete of a bound machine (`cluster-api-provider-provisioned/controllers/machine_controller.go:104-127`).
  - Host claims are permanent (`controllers/claims.go:120-128`).
  - NVKE waits for zero Machines with no end (`controller/internal/temporal/activities/capi_cluster_resources.go:102-128`, `controller/internal/temporal/workflows/shared.go:38-49`).

The operator procedure of the lab (`delete.sh all`). Each kubectl call runs through `docker exec kata-cp-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf`:

1. `/scratch/kata-cp/work/phase1-stack/api.sh delete /api/clusters/<ID>`. Poll each 10 s until the state is equal for 60 s with 0 node rows.
2. `run.sh down` (delete the 3 StatefulSets, the pods, the namespace `phase1-run` and the 6 volumes), then `run.sh wipe` (`wipefs -a` on the 6 loop devices in the kind node).
3. List the objects and write the list to `delete/release-*.txt`: `kubectl -n nvke-system get provisionedmachines -l cluster.x-k8s.io/cluster-name=kata-cp1`, and the `provisionedhostclaims` with `.spec.clusterName=="kata-cp1"`. The script stops unless it finds 3 and 3 and each claim names a listed machine.
4. For each of the 3 machines: `kubectl -n nvke-system patch provisionedmachine <name> --type=json -p '[{"op":"test","path":"/metadata/finalizers/0","value":"provisionedmachine.infrastructure.cluster.x-k8s.io"},{"op":"remove","path":"/metadata/finalizers/0"}]'`
5. For each of the 3 claims: `kubectl delete provisionedhostclaim <name>`
6. Poll until `GET /api/clusters/<ID>` gives HTTP 404 (limit 600 s), then the check for an empty state.

Limits of the procedure: no other object, no database edit, no Temporal change. The main session decided on it for the lab cluster only.

| Delete | DELETE (UTC) | Wait state after | Operator steps done | Workflow completed | Empty check |
|---|---|---|---|---|---|
| r1 | 16:55:27 | 22 s | 16:57:32.4 | 16:57:35.9, 3.5 s later | All pass |
| r2 | 17:12:46 | 22 s | 17:14:31 | 17:14:34.6, 3.6 s later | All pass |

- After the operator steps Cluster API and NVKE removed the Machines, the `ProvisionedCluster`, the Cluster, the Secrets and the cluster row by themselves.
- The empty check: no cluster row (404), no cluster with the name, no node row, no Cluster API object, no bootstrap Secret, no host claim, no `host-<node ID>` entry, the workflow COMPLETED, and nothing with the cluster name in `nvke-system`.
- The same names and addresses worked in the next run.
- What stays: the SPIRE agent record of each node until its expiry, 4 h after the attestation. They did not block a run.
- Unused join tokens cannot be listed, because the SPIRE server has no list command for them. Each token of these runs was used.

## 8. Not tested

- A delete during provisioning, and a new cluster name with new hosts next to an old cluster.
- Pod traffic between nodes, and DNS from the second and third node.
- A node replace or a remediation through NVKE, a new pod on the same volumes through NVKE, worker nodes, an upgrade, and the certificate renewal that NVKE plans for 2026-11-27 05:15 UTC.
- A helper that is down at the first bootstrap for longer than 163 s, and an expired token.
- The runc baseline, and the removal of the helper.

## 9. Files and state

- Scripts in this folder: `run.sh` (`full`, `check`, `record`, `evidence`, `down`, `wipe`), `delete.sh` (`all`, `state`), `rest.sh`, `wrapper.sh`, `podspec.inc`, the templates.
- Logs for each run in `/scratch/kata-cp/logs/phase1-run/r1`, `r2`, `r3`: `check-*.txt`, `timeline.txt`, `times.txt`, `record-final/` (API JSON, Cluster API objects, helper and provider logs, workflow time lines), `evidence-final/`, `delete/` (r1, r2).
- Secrets (the kubeconfig, raw controller and agent logs, raw workflow histories) are in `r*/secrets/` with mode 700, and not in the notes.
- The third cluster stayed up at the end of step 5: NVKE cluster `kata-cp1`, pods `cp-a-0`, `cp-b-0`, `cp-c-0` in `phase1-run`, with the helper in `nvke-lab-bootstrap-helper`. Step 7 deletes it with the same procedure, after the change of the controller image.
