# Phase 2, steps 6 and 7: node replace through the NVKE API, rollout to a new node image, placement (result)

Machine: `the second test machine`, 2026-11-27 00:31 to 01:50 UTC.
Provider: `cluster-api-provider-podvm:2f2841c5`. Node images: `nvke-node-podvm:bcc4376f-p2` and `nvke-node-podvm:bcc4376f-p3`. NVKE controller: `nvke-controller:c6d669ef`, no change.
Scripts: `/scratch/kata-cp/work/bigbox/remote/p2-replace/` (and `p2-image/Dockerfile.p3`, `build-ctr`, `build-p3.sh`). The same files are in `/root/kata-cp/` on the machine.
Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/p2s6/` (copy of `/root/kata-cp/logs/p2s6/`, no secrets folder).

## 1. Verdict

| Test | Verdict | Main facts |
|---|---|---|
| S6a, delete of a joined node with three nodes | NVKE refuses by design | `DELETE /nodes/{id}` gives 400: "only 2 joined control-plane node(s) would remain, below the minimum of 3" |
| S6a, the way that the answer names: desired count 4, then delete a joined node | PASS | NVKE tears the node down in 29.4 s, the provider removes pod, claims and Secret copy, NVKE makes a new Machine 0.9 s later, new pod with a new name, the freed address and empty spare volumes, 4 good nodes 180.7 s after the DELETE |
| S6a, the same for the first node | FAIL with NVKE and the image as they are | Teardown and new pod pass. The new Machine does not join: 4 failed `JoinNode` workflows in 12 minutes. Cause in section 5. With one small file by hand on the node that NVKE asks, the join passed |
| S6b, rollout to the image p3 | FAIL with NVKE and the image as they are. The steps of the rollout pass with that file by hand | NVKE starts the rollout at once and makes the first new node. Its join fails (same cause). With the file by hand on each joined node the rollout ends by itself: three new nodes with p3, 3 Ready nodes, 3 healthy etcd members, pod traffic 6 of 6 |
| S7, placement | Recorded | Each Machine runs on the host node of its failure domain in each step. "Three pods on three host nodes" holds with three nodes, and does not hold while the cluster has four nodes or a surge node |

Three more facts:

- Scale up to 4 and scale down to 3 through the API pass (192.1 s and 47.4 s).
- The delete of run 3 through the NVKE API with the old provider passed (teardown workflow 29.2 s, row gone 35.2 s, nothing left). The permission system let it through this time.
- The disk was below 15 ms before each test. I did not have to wait.

The point where NVKE needs a change (section 5) stops each flow that makes a new control plane node after the first node of the cluster is gone or has a new pod: replace, scale up, rollout.

## 2. Preparation

1. Run 3 deleted through the NVKE API with the provider `cdc368ea`. Then `storage.sh reset`.
2. Provider `2f2841c5`: `docker save` on the workstation (30 MB), one copy, import into the four kind nodes, `infrastructure-components-2f2841c5.yaml` applied. The new manager holds the lease since 00:32:58. No `PodVMMachine` with the old finalizer was left.
3. Image p3 (`p2-image/Dockerfile.p3`): `FROM` the image p2, one `RUN` step. It starts containerd in the build container, installs the CNI images package of the base image with an import that does not unpack (a `ctr` wrapper for the build adds `--no-unpack`, a build container has no mount rights), and removes the package file. The unit `nke-container-cni-images.service` has the condition "the package file exists", so it does not run. Build 22 s, save and load into the three workers 114 s. Size 1,964,383,835 bytes against 1,301,888,330 bytes for p2.
4. Node start in one pod made by hand (`p2-replace/nodestart.sh`, provider pod form, test data with fake values). End point: the end of the commands unit (cloud-init status `done`), which is when the agent units start. With fake SPIRE data the agent opens no listener. In the real runs the listener came 1.1 to 1.5 s after that point.

| Image | First start, empty volumes | Later start, same volumes | Longest unit |
|---|---|---|---|
| p2 | 68.1 s (62.7 s in a first try) | 39.8 s | `nke-container-cni-images.service` 42.9 s and 26.5 s |
| p3 | 35.3 s | 14.5 s | `nke-container-network.service` 2.7 s and 3.4 s |

   - With p3 the copy of `/var` at the first use takes 8 s more (the image has 318 MB more in its containerd store). systemd is up in 5.2 s.
   - In the cluster, for one new node: `WaitForCAPIMachineReady` 65.2 to 75.7 s with p2 and 45.3 to 45.5 s with p3. `KubeadmJoin` 50 s with p2 and 30 s with p3.
   - containerd unpacks the OVN image at its first use. `ovnkube-node` was 5/5 on each p3 node.
5. Request (`request.json.tmpl`): as in step 4, plus `enableCPNodeRecycling: true` and `controlPlaneConfig.maxSurge: 1`.
6. `storage-loop.sh` ran in the background for the whole test: each 10 s it makes each Released volume again.

What the API says (`controller/api/openapi.yaml` of `nvke-endpoint`): a control plane node is deleted with `DELETE /nodes/{nodeID}` (`:933-1003`). The machine template is changed with `PATCH /clusters/{clusterID}`, field `controlPlaneConfig.infra.machineTemplate` (`:321-375`, `:3701-3714`). A recycle needs `enableCPNodeRecycling` (`:1204-1210`, `:1686-1688`), and `maxSurge` is 0 or 1 (`:1447-1450`).

## 3. Disk values

Write time of `vda` over 10 s, from `/proc/diskstats`. Earlier today: 0.43 ms.

| Before | Write time | Writes each second |
|---|---|---|
| Delete of run 3 (00:31) | 4.9 ms | 121 |
| Node start p2 (00:43) | 1.5 ms | 77 |
| Node start p3 (00:46) | 5.1 ms | 50 |
| Cluster flow (00:51) | 11.2 ms | 41 |
| Scale up (00:59) | 2.5 ms | 156 |
| Delete of the joined node (01:03) | 1.4 ms | 192 |
| Delete of the first node (01:07) | 1.5 ms | 226 |
| Scale down (01:24) | 1.0 ms | 178 |
| Rollout (01:26) | 2.5 ms | 174 |

Two values right after the load of the image p3 (15.7 ms and 25.9 ms at 63 MB each second) are from that load. No test failed with etcd warnings.

## 4. The cluster and S6a

Cluster (`run-1`, image p2): three pods 37.7 s after the POST, started 159.3 s, provisioned 286.3 s, three Ready nodes 418.9 s. Pod traffic 6 of 6, one pod for each host node.

### The literal test

`DELETE /api/nodes/<id>` of a joined node with three joined nodes: HTTP 400.

> cannot delete control-plane node "kata-cp1-cp-bb1fb72a": only 2 joined control-plane node(s) would remain, below the minimum of 3 needed for etcd to survive another failure. Raise the control-plane desired count first so a replacement joins before this node is removed. To replace control-plane nodes for an upgrade, set enableCPNodeRecycling: true on the cluster and the controller replaces them one at a time

Source: `controller/internal/nodes/control_plane_delete_request.go:26` (the minimum of 3), `:154-189` (the check at request time), `:58-66` (the text). Nothing changed in the cluster.

### Desired count 4 (`PATCH` with `controlPlaneConfig.desiredCount`)

4 good nodes 192.1 s after the PATCH. New Machine `kata-cp1-cp-8e953900`, address `.4`, failure domain and host node `kata-bb-worker` (the second pod on that host node), spare volumes `loop66` and `loop63`. `WaitForCAPIMachineReady` 75.7 s, `NodePreflight` 0.07 s, join 50.4 s.

### Delete of a joined node that is not the first node (4 nodes)

Node `kata-cp1-cp-bb1fb72a` (address `.2`, `kata-bb-worker2`). `DELETE` at 01:03:43, HTTP 202.

| Part | Time (UTC) | Length |
|---|---|---|
| Teardown workflow of NVKE | 01:03:48.6 to 01:04:18.0 | 29.4 s |
| Drain | | 5.2 s |
| Graceful shutdown of the control plane | | 20 s |
| etcd member remove, kubeadm reset, Machine delete, Node delete | | 3.5 s |
| Provider deletes pod, claims, Secret copy | 01:04:17.87 | |
| Provider: all gone, address released | 01:04:21.13 | 3.3 s |
| NVKE starts the workflow of a new node | 01:04:18.84 | 0.9 s after the teardown |
| Provider gives the address `.2` to the new Machine, makes Secret copy, claims and pod | 01:04:21.36 to .38 | |
| Agent of the new node answers | 01:05:22.8 | 61 s after the pod |
| `WaitForCAPIMachineReady`, `NodePreflight` | | 65.2 s, 0.06 s (1 attempt) |
| Join workflow | 01:05:27.6 to 01:06:18.6 | 51 s |
| 4 good nodes again | | 180.7 s after the DELETE |

- New Machine `kata-cp1-cp-f289adc3`: the freed address `.2` is used again (the provider gave it 0.2 s after the old Machine released it). Same failure domain and host node as the deleted node (`kata-bb-worker2`, the domain with the fewest nodes).
- Volumes: the spare volumes of that host node (`loop67`, `loop64`), empty (the entry point made the filesystems). The pod was scheduled 1 s after it was made. It did not wait for a volume. The storage loop made the volumes of the deleted node again at 01:04:27.
- Nothing of the deleted Machine is left: no pod, claim, Secret copy, `PodVMMachine`, Machine, bootstrap Secret of NVKE, SPIRE entry.
- Shared address: 181 calls, 179 with 200. 2 calls got 500 from `/readyz` (01:03:57 and 01:03:58), while the API server of the deleted node was in its graceful shutdown and its pod was still behind the Service. No call was without an answer.
- After it: 4 Ready nodes, 4 healthy etcd members, pod traffic 12 of 12, name lookup 4 of 4.

### Delete of the first node (4 nodes)

Node `kata-cp1-cp-8711c0b3` (address `.1`, `kata-bb-worker3`, the node of `kubeadm init`). `DELETE` at 01:07:44, HTTP 202.

- Teardown workflow 01:07:48.0 to 01:08:27.6 (39.6 s, drain 15.1 s).
- The provider released the address at 01:08:31.00 and gave it to the new Machine `kata-cp1-cp-ac84bc57` at 01:08:31.02. New pod on `kata-bb-worker3` with the spare volumes `loop62` and `loop65`, scheduled in 1 s.
- Agent answers at 01:09:32.7. `WaitForCAPIMachineReady` 65.3 s, `NodePreflight` 0.06 s.
- Then the join fails. 4 `JoinNode` workflows failed between 01:09:40 and 01:20, each with a second attempt, each attempt after 70 s in the activity `KubeadmJoin`. NVKE starts the workflow again each time, with no end.
- After the file by hand at 01:20:06 (section 5) the next run passed. Joined at 01:22:51. 4 good nodes 931.2 s after the DELETE.
- Shared address: 915 calls, 913 with 200, 2 with 500 (01:08:04 and 01:08:07, graceful shutdown).
- After it: 4 Ready nodes, 4 healthy etcd members, pod traffic 12 of 12.

### Desired count 3

3 good nodes 47.4 s after the PATCH. NVKE removed `kata-cp1-cp-e8014a9d`, one of the two nodes on `kata-bb-worker`. One pod for each host node again. Pod traffic 6 of 6.

## 5. Why a new node does not join when the first node is gone

Error of the controller (`rollout-join/stop-1.txt`):

> failed to update and fetch kubeadm join strings from node kata-cp1-cp-8e953900: ... kubeadm init phase upload-certs --upload-certs: exit status 1 ... could not bootstrap the admin user in file admin.conf: unable to create ClusterRoleBinding: Post "https://10.244.2.58:6443/apis/rbac.authorization.k8s.io/v1/clusterrolebindings?timeout=10s": tls: failed to verify certificate: x509: certificate is valid for 10.112.0.1, 172.28.1.4, 172.29.255.220, not 10.244.2.58

The chain, with source lines:

1. For each join NVKE gets new join strings from a joined control plane node: the first joined node of its node list (`controller/internal/temporal/activities/kubeadm_join.go:93`, `:216-231`). I found no order rule in that query (`controller/internal/db/nodes.go:357`). In the tests it asked the first node while it existed, then other old nodes, and in the rollout one time a new node.
2. The agent of that node runs `kubeadm init phase upload-certs --upload-certs`. It adds `--config` only when the file `/tmp/kubeadm-init-config.yaml` exists (`agent/internal/agent/agent.go:51`, `:1597-1602`). The agent writes that file only for `kubeadm init`, on the first node (`:863-872`).
3. With no config, kubeadm v1.36.4 talks to the local API server at the address of the interface with the default route. In a pod of design B that is the pod IP on `eth0`. The node address is on `net1`.
4. The certificate of the API server has the node address and the shared address, not the pod IP. So the call fails, kubeadm tries for 60 s, and the phase ends with an error.

First hand:

- `kubeadm init phase upload-certs --upload-certs -v=6` by hand on the joined node `kata-cp1-cp-e8014a9d`: each POST goes to `https://10.244.2.57:6443` (its pod IP) and gets no HTTP status.
- The same command with a config file of five lines (`InitConfiguration` with `localAPIEndpoint.advertiseAddress: 172.28.1.3`): the POST goes to `https://172.28.1.3:6443`, gets 409 (the binding exists), and the phase ends with a certificate key (`first-node-join/upload-certs-with-config.txt`).
- That file put at `/tmp/kubeadm-init-config.yaml` on the node by hand: the next call of the agent ran with `--config`, logged "kubeadm update join commands completed successfully", and the `JoinNode` run of NVKE completed.

What follows:

- On a machine whose node address is on the interface with the default route, kubeadm finds the right address by itself. So the fault shows only in the pod design with the node address on a second interface.
- `/tmp` is new in each pod of the node image. So the first node loses the file with its first new pod (deduction from the entry point, not tested). After that no node of the cluster can give join strings.
- Each flow of NVKE that makes a new control plane node is hit: the refill after a delete, scale up, remediation, the rollout.

Ways out (not tested, except the file by hand):

- NVKE: the agent passes a config with the node address to the `upload-certs` phase on each control plane node. It has the address in its join config (`/tmp/kubeadm-join-config.yaml` on a joined node).
- Image: a unit of the node image writes that small file when it is absent, with the address of `PODVM_NODE_ADDRESS`. The init of NVKE writes over it on the first node.

## 6. S6b: the rollout to p3

`PATCH /api/clusters/<id>` with the machine template of the image p3 at 01:26:20, HTTP 200. Three nodes with p2 before it, all without the file of section 5 (the node that had it was removed by the scale down).

| Time (UTC) | Event |
|---|---|
| 01:26:21 | NVKE makes the node `kata-cp1-cp-58719b16`. The three old nodes get the condition `controlPlaneRolloutRequired` |
| 01:26:23.9 | Provider makes its pod: image p3, address `.3`, domain and host node `kata-bb-worker` (where the old node `8e953900` runs), spare volumes |
| 01:27:01.6 | Agent answers (37.7 s after the pod). `WaitForCAPIMachineReady` 45.5 s, `NodePreflight` 0.06 s |
| 01:28:21 | The first `JoinNode` attempt fails with the error of section 5 (2 failed workflows in all). NVKE asked the old node `8e953900`. **The rollout stops here** |
| 01:29:33 | By hand: the small file on the three old nodes |
| 01:32:05.7 | Join of the first new node done |
| 01:32:47.9 to 01:33:24.1 | NVKE tears down the old node `8e953900` (36.2 s) |
| 01:33:24.9 | NVKE makes the node `kata-cp1-cp-7b1fb63f`: address `.4` (freed 0.03 s before), `kata-bb-worker3` (where the old node `ac84bc57` runs) |
| 01:34:05.4 | Agent answers (37.7 s). `WaitForCAPIMachineReady` 45.4 s |
| 01:34:14.1 to 01:34:45.2 | Join (31 s, first run) |
| 01:35:16.5 to 01:35:56.6 | Teardown of the old node `ac84bc57` (40.1 s) |
| 01:35:57.4 | NVKE makes the node `kata-cp1-cp-a0f684be`: address `.1`, `kata-bb-worker2` (where the old node `f289adc3` runs) |
| 01:36:37.4 | Agent answers (37.7 s). `WaitForCAPIMachineReady` 45.3 s |
| 01:37:56 | `JoinNode` fails again (3 failed workflows in all). NVKE asked the new node `58719b16`, which has no file. **The rollout stops again** |
| 01:41:51 | By hand: the small file on the two new nodes |
| 01:44:30.3 | Join of the third new node done |
| 01:45:22.2 to 01:45:57.1 | Teardown of the old node `f289adc3` (34.9 s) |
| 01:46:08 | 3 good nodes, each with p3. NVKE reports the rollout as ended: 3 of 3 nodes up to date, `inProgress: false`, `cpNodesRecycling` False since 01:45:57 |

- Order: NVKE replaced the nodes one after the other, new node first (`maxSurge: 1`). Old nodes in the order `8e953900`, `ac84bc57`, `f289adc3`.
- Time for one node with no stop (the second): 151.7 s from the workflow of the new node to the end of the teardown of the old node. The whole rollout took 1193.8 s. About 12 minutes of that were the two stops.
- The extra pod of each surge ran on the host node of the node that it replaces, in the same failure domain. Two pods of the cluster on one host node: `kata-bb-worker` 01:26:27 to 01:33:22, `kata-bb-worker3` 01:33:34 to 01:35:59, `kata-bb-worker2` 01:36:05 to 01:45:56. Without the stops that is about 2.5 minutes for each node.
- Volumes: each surge pod took the spare volumes of its host node and was scheduled 1 s after it was made. No pod waited for a volume, and there is no `FailedScheduling` event. The storage loop made the volumes of each old node again 6 to 13 s after its pod was gone.
- Shared address during the whole rollout: 1176 calls, 1174 with 200. One call had no answer in 2 s (01:30:24), one got 500 (01:33:02, graceful shutdown of an old node).
- What NVKE reported: the condition `controlPlaneRolloutRequired` on each old node, and in `GET /clusters/<id>/control-plane` the counts `upToDateNodeCount` 0, 1, 2, 3, `pendingNodeCount` 3, 2, 1, 0, `inProgressNodeCount` 1 while a new node starts, `inProgress` true from the first replaced node to the end. While a join failed it reported the node as "Control-plane join is in progress" and no error.
- End: 3 Ready nodes on 3 host nodes with p3, 3 healthy etcd members, pod traffic 6 of 6, name lookup 3 of 3, `ovnkube-node` 5/5.

## 7. S7: placement after each step

The failure domain of a Machine is a host node name. In each step each pod runs on the host node of its domain.

| Step | Machines: address, host node, volumes | One pod for each host node |
|---|---|---|
| Cluster made | `8711c0b3` `.1` worker3 `loop68` `loop71`. `bb1fb72a` `.2` worker2 `loop61` `loop70`. `e8014a9d` `.3` worker `loop60` `loop69` | holds |
| Desired count 4 | and `8e953900` `.4` worker `loop66` `loop63` | does not hold: 2 on worker |
| Joined node replaced | `bb1fb72a` gone. New `f289adc3` `.2` worker2 `loop67` `loop64` | does not hold: 2 on worker |
| First node replaced | `8711c0b3` gone. New `ac84bc57` `.1` worker3 `loop62` `loop65` | does not hold: 2 on worker |
| Desired count 3 | `e8014a9d` gone. Left: `ac84bc57` `.1` worker3, `f289adc3` `.2` worker2, `8e953900` `.4` worker | holds |
| During the rollout | one surge pod on the host node of the node it replaces | does not hold for the time of each surge (section 6) |
| Rollout ended | `a0f684be` `.1` worker2 `loop61` `loop70`. `58719b16` `.3` worker `loop60` `loop69`. `7b1fb63f` `.4` worker3 `loop68` `loop71` | holds |

- NVKE picks the domain with the fewest nodes for a new Machine. With a tie it took `kata-bb-worker`. A surge node gets the domain of the node that it replaces. The scale down removed a node from the domain with two nodes.
- The provider gives the lowest free address. A freed address is used again by the next new Machine.
- Each host node has two Machine places. A fourth node and each surge node used the spare place of its host node. A cluster with four nodes has no spare place on one host node, so a surge for a node there would wait for a volume. That case did not come up (the rollout ran with three nodes).

## 8. What the provider commit `2f2841c5` changed in the logs

- The API server warning about the finalizer name is gone (0 lines). The finalizer is `podvm.infrastructure.cluster.x-k8s.io/machine-cleanup`.
- The lines "Reconciler error ... failed to get tenant Node ... connection refused" are gone. Where the Node does not exist yet, the log has the INFO line "Waiting for the tenant Node".
- The pods have a grace period of 20 s and a readiness probe with a time limit of 3 s and 3 failures.
- One new error line, at 3 of 6 Machine deletes: "Reconciler error ... failed to remove the finalizer from PodVMMachine ...: not found" (`controllers/machine_controller.go:576`). The Machine was already gone and the delete was complete. A not found answer is the wanted end there.
- At each graceful shutdown of an API server (the teardown of NVKE) 1 or 2 calls to the shared address got 500. The pod stays behind the Service until 3 probes fail. Step 5 had 0 failed calls, but there the pod was deleted with no graceful shutdown, so the two are not the same case.

## 9. Failures and their causes

1. S6a with three nodes: refused by NVKE by design (section 4).
2. S6a for the first node, and S6b: the join of a new node fails (section 5). NVKE and the node image need a change. The provider did its part in each case.
3. My scripts:
   - The first form of the node start measure waited for a wrong condition and ran 300 s too long. The measured times were right. Fixed, and measured again.
   - Pod traffic after the scale up to 4 was not measured: a block D array had no entry for a fourth node. Fixed. The measure after the next step has 4 nodes (12 of 12).
   - The cluster flow printed `RESULT flow: FAIL` because of one rule of the block D endpoint check (join commands in the agent journal, read too early). The checks after it pass.
   - `delete-node first` printed PASS when the end state came, 931 s after the DELETE and after the file by hand. The verdict in section 1 is the true one.
   - The rollout step ended before its RESULT line (a `grep` with no match). The record is complete.
4. By hand steps in the cluster (`run-1/by-hand.txt`): the small config file in `/tmp` of 6 node pods, 3 times, each as a diagnostic. No NVKE or Cluster API object was written by hand.

## 10. Not tested

- A rollout or a first node replace with no step by hand. One of the two ways out of section 5.
- A new pod for the first Machine, and then a join (the loss of `/tmp` there is a deduction).
- A cluster made with the image p3 (the rollout tested only joins with p3, not `kubeadm init`).
- A rollout with `maxSurge: 0`. A change of the Kubernetes version. Remediation.
- A surge or a new Machine that waits for a volume. The loss of a host node.
- A repeat with a slow disk (the disk was not slow in a test).

## 11. Changes on the machine and how to remove them

All under `/root/kata-cp` or in the lab cluster. No firewall rule, no listener on an outside interface, no change of the Docker or containerd configuration or of the network settings, no restart, no database write, no Temporal change. Machine checks at the end are unchanged (disk 197 GB of 300 GB).

| Change | Removal |
|---|---|
| Cluster `kata-cp1` (NVKE ID `c5f6e8c3-1551-49ba-9bf8-55278b6e8881`), three nodes with the image p3 in `d`. It stays up. Two of its pods have the file of section 5 in `/tmp` (lost with their next pod) | `LOG_DIR=/root/kata-cp/logs/p2s6/run-1 p2-replace/run.sh delete`, then `p2-provider/storage.sh reset` |
| Run 3 of step 4: gone (delete through the NVKE API) | Nothing to do |
| Provider Deployment now with the image `2f2841c5`, the image in the four kind nodes, archive `dl/img/cluster-api-provider-podvm_2f2841c5.tar` | `kubectl delete -f` of the two manifests in `p2-replace/install/`, `ctr -n k8s.io images rm` in each node |
| Image `nvke-node-podvm:bcc4376f-p3` in Docker and in the three workers, archive `dl/img/nvke-node-podvm_bcc4376f-p3.tar` (1.9 GB) | `docker rmi`, `ctr -n k8s.io images rm` in each worker, `unlink` of the archive |
| Namespace `p2m` for the node start measure: made and removed | Nothing to do |
| The storage loop: stopped | Nothing to do |
| Folders `p2-replace`, `p2-image/Dockerfile.p3` and two files beside it, `work/p3-image-ctx`, `logs/p2s6`, more files in `secrets/d-run-1` (mode 700) | Remove the folders |
| Workstation: `/scratch/kata-cp/tmp/p2s4/cluster-api-provider-podvm_2f2841c5.tar` (30 MB), scripts, logs, this file | `unlink` of the archive |
