# Phase 2, the two failed tests again with the fixed NVKE agent (result)

Machine: `the second test machine`, 2026-11-27 02:02 to 03:00 UTC.
Agent: commit `f240606c` (branch `fix/agent-upload-certs-config`), binary sha256 `e465d46ad7a578b1634ca129dc2b0303c76bc6146fc346e937e18371affe8770`, version `v0.24.0-beta.18-4-gf240606c`.
Node images: `nvke-node-podvm:bcc4376f-p4` and `nvke-node-podvm:bcc4376f-p5`. Provider: `cluster-api-provider-podvm:2f2841c5`, no change. NVKE controller: `nvke-controller:c6d669ef`, no change.
Scripts: `/scratch/kata-cp/work/bigbox/remote/p2-agentfix/` (they load `p2-replace/run.sh`). The same files are in `/root/kata-cp/` on the machine.
Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/p2s6b/` (copy of `/root/kata-cp/logs/p2s6b/`, no secrets folder). Run folder: `fix-1`.

I wrote no file by hand into a guest. Each change of the cluster went through the NVKE API. The one step by hand is the pod delete of R2, which the test asks for.

## 1. Verdict

| Test | Verdict | Main facts |
|---|---|---|
| Images p4 and p5 | PASS | The agent binary in both images has the sha256 of the brief and prints `v0.24.0-beta.18-4-gf240606c`. The same check passed inside each node of the cluster |
| Cluster with p4 (first `kubeadm init` with an image of the p3 kind) | PASS | Provisioned 208.4 s after the POST, three Ready nodes after 348.8 s, all checks pass, pod traffic 6 of 6 |
| R1, replace of the first node (pass rule 5) | PASS | Desired count 4, then `DELETE` of the first node. The new Machine joined by itself. 4 good nodes 191.7 s after the DELETE. Then desired count 3 |
| R1b, an added step (section 5) | PASS | First node gone, the kept join strings of the controller too old, desired count 4. NVKE asked a joined node again and the new node joined |
| R2, a new pod for each Machine, then a join | PASS | Each of the three pods deleted and made again by the provider. Then desired count 4. NVKE asked a node with a new `/tmp` and the new node joined by itself |
| R3, rollout to p5 (pass rule 6) | PASS, with one point for you to judge | NVKE replaced the three nodes one after the other by itself. Each new node runs p5. End state: 3 Ready nodes on 3 host nodes, 3 healthy etcd members, pod traffic 6 of 6. The shared address answered each of the 519 calls. 513 answers were 200. 6 answers were HTTP 500 from `/readyz` (section 8) |

The task had 10 `JoinNode` workflows (1 for the first node, 9 joins of a new control plane node). All 10 completed. No workflow failed and none had a second attempt in `KubeadmJoin`.

## 2. The images

| Image | ID | Size | Agent sha256 | Agent version | Marker |
|---|---|---|---|---|---|
| p3 | `2a6c53793aaa` | 1 964 383 835 | `0de9abec...ba00` | `v0.24.0-beta.18` | none |
| p4 | `cc19d949693a` | 1 980 818 608 | `e465d46a...8770` | `v0.24.0-beta.18-4-gf240606c` | none |
| p5 | `34db3702f674` | 1 980 819 366 | `e465d46a...8770` | `v0.24.0-beta.18-4-gf240606c` | `p5` in `/usr/share/podvm/image-form` |

- `Dockerfile.p4`: `FROM` the image p3, a copy of the binary to `/usr/local/bin/nvke-agent` (mode 0755), a `sha256sum -c` in the build, two labels. `Dockerfile.p5`: `FROM` the image p4, the marker file, one label. Both builds ran with `--network none`.
- The binary came to the machine with one copy. Its sha256 was checked on the workstation, on the machine, in the build, in each image, and in each node of the cluster (`fix-1/fix-evidence-*.txt`).
- Save and load into the three host nodes: 71 s and 70 s. The image ID is the same in the three host nodes for each image.

## 3. Disk values

Write time of `vda` over 10 s, from `/proc/diskstats`. No value was above 15 ms. I did not have to wait.

| Before | Write time | Writes each second |
|---|---|---|
| Image build (02:02) | 1.0 ms | 122 |
| Delete of the old cluster (02:09) | 1.0 ms | 129 |
| Cluster with p4 (02:10) | 1.1 ms | 48 |
| R1, desired count 4 (02:18) | 1.0 ms | 117 |
| R1, DELETE of the first node (02:22) | 0.5 ms | 225 |
| R1, desired count 3 (02:26) | 0.5 ms | 172 |
| R1b, desired count 4 (02:28) | 0.8 ms | 144 |
| R1b, desired count 3 (02:31) | 0.6 ms | 204 |
| R2, new pods (02:33) | 0.6 ms | 157 |
| R2, desired count 4 (02:42) | 1.5 ms | 148 |
| R2, desired count 3 (02:45) | 1.4 ms | 257 |
| R3, rollout (02:47) | 0.5 ms | 187 |
| End (02:59) | 1.0 ms | 217 |

The value before the image build is in `logs/p2s6/disk.txt`. The others are in `logs/p2s6b/disk.txt`.

## 4. The cluster with p4

Delete of the old cluster (three p3 nodes) through the NVKE API: PASS. Row and objects gone 35.2 s after the DELETE. Then `storage.sh reset`: 12 volumes free.

New cluster `kata-cp1`, NVKE ID `8caca331-bf11-415b-9742-851cbe3b4b45`, three nodes, `maxSurge: 1`, `enableCPNodeRecycling: true`, image p4. POST at 02:10:22.

| Time after the POST | p4, this run | p2, step 6 | p2, step 4 |
|---|---|---|---|
| Three pods of the provider | 42.0 s | 37.7 s | |
| Three started containers | 113.2 s | 159.3 s | |
| Provisioned | 208.4 s | 286.3 s | 252.4 to 253.7 s |
| Three provisioned nodes | 312.9 s | 411.5 s | |
| Three Ready nodes | 348.8 s | 418.9 s | |
| `WaitForCAPIMachineReady`, three nodes at once | 75.3 s | | 115.3 to 115.5 s |
| `NodePreflight` | 0 to 0.1 s, 1 attempt | | 0.1 s, 1 attempt |

- The disk was at 1.1 ms before this run and at 11.2 ms before the p2 run of step 6. So a part of the gain against step 6 can come from the disk. The step 4 runs are the better comparison: provisioned is 44 s earlier with p4.
- With p4 the nodes are Ready 35.9 s after NVKE reports them as provisioned (7.4 s with p2). containerd unpacks the OVN image at its first use on each node. I measured that on one new node: the image was "already present" at 02:54:12 and the container was made at 02:54:35 (23 s). The node was Ready 55 s after it registered.
- `RESULT flow: PASS`, `RESULT after flow: PASS`. The endpoint check found 2 join commands, each with the shared address. Pod traffic 9 of 9 lines, 6 of 6 between different nodes. Name lookup 3 of 3.
- The flow of my script has one change against step 6: the pod map before the checks has all three Machines. In step 6 it had only the nodes that NVKE already reported as good, and the flow printed FAIL for that reason.

## 5. R1: replace of the first node

| Step | Time (UTC) | Result |
|---|---|---|
| Desired count 4 | PATCH 02:18:42 | 4 good nodes 156.8 s after the PATCH. `WaitForCAPIMachineReady` 45.2 s, `KubeadmJoin` 40.6 s. New Machine `kata-cp1-cp-11240139`, address `.4`, host node `kata-bb-worker` |
| Join strings for it | 02:19:31.770 | NVKE asked `kata-cp1-cp-c4c42b53`, a joined node, not the first node. It has no `/tmp/kubeadm-init-config.yaml`. The agent wrote its config with `localAPIEndpoint=172.28.1.2:6443`. The join passed |
| `DELETE /api/nodes/c1a8a6f4-...` (first node `kata-cp1-cp-fe13d66d`, address `.1`) | 02:22:19 | HTTP 202 |
| Teardown workflow | 02:22:23.0 to 02:22:57.1 | 34.0 s |
| Workflow of the new Machine | starts 02:22:58.0 | 0.9 s after the teardown. `WaitForCAPIMachineReady` 45.2 s |
| Join workflow | 02:23:46.5 to 02:24:27.3 | 40.8 s, `KubeadmJoin` 40.1 s, first attempt |
| 4 good nodes again | 02:25:31 | 191.7 s after the DELETE |
| Desired count 3 | PATCH 02:26:33 | 3 good nodes 52.8 s after the PATCH |

- New Machine `kata-cp1-cp-502352ae`: the freed address `.1`, host node `kata-bb-worker2` (the host node of the deleted node), new volumes. No pod, claim or Secret copy of the old node was left.
- After the replace: 4 Ready nodes, 4 started and healthy etcd members, pod traffic 16 of 16 lines (12 of 12 between different nodes).
- Shared address during the replace: 193 calls, 191 with 200, 2 with 500 (02:22:34 and 02:22:37, section 8). No call was without an answer.
- Provider: 0 error lines.

One fact about this join. The controller keeps the join strings of a cluster for 5 minutes (`controller/internal/temporal/activities/kubeadm.go:36`, `joinStringCacheTTL`, and `kubeadm_join.go:321-354`). The join after the DELETE started 4 minutes 15 seconds after the request of 02:19:31. So the controller used the kept strings and asked no node after the first node was gone. The strings came from a joined node with the fixed agent, so the pass is real. But the case "first node gone, and then a new request to a node" was not in R1. I added R1b for that.

### R1b (added step)

The first node is gone. The kept strings are more than 5 minutes old. No pod has a new start.

| Step | Time (UTC) | Result |
|---|---|---|
| Desired count 4 | PATCH 02:28:25 | 4 good nodes 133.8 s after the PATCH. `WaitForCAPIMachineReady` 45.4 s, `KubeadmJoin` 40.6 s |
| Join strings for it | 02:29:14.437 | NVKE asked `kata-cp1-cp-c4c42b53` again. `localAPIEndpoint=172.28.1.2:6443`. The join passed at the first attempt |
| Desired count 3 | PATCH 02:31:35 | 3 good nodes 52.7 s after the PATCH |

This is the case that failed in step 6 with the old agent (a request to a node that did not run `kubeadm init`).

## 6. R2: a new pod for each Machine, then a join

I cannot tell before a join which node NVKE asks. It asked `c4c42b53` two times and then `502352ae`. So I deleted the pod of each of the three nodes, one after the other.

| Pod delete | Old pod gone | `/readyz` of the new pod | New kubelet heartbeat | etcd healthy | Shared address |
|---|---|---|---|---|---|
| `kata-cp1-cp-502352ae` (02:33) | 22.5 s | 52.2 s | 73.7 s | 74.0 s | 163 of 163 calls |
| `kata-cp1-cp-c4c42b53` (02:36) | 22.9 s | 51.6 s | 73.2 s | 73.6 s | 163 of 163 calls |
| `kata-cp1-cp-314927d6` (02:39) | 22.1 s | 50.4 s | 66.6 s | 66.9 s | 163 of 163 calls |

- Each `RESULT lost-pod: PASS`: same pod name, host node, address, hardware address, claims and Secret copy, new pod UID, new boot ID, two repeat runs of the bootstrap units. With p2 in step 5 `/readyz` came after 84.8 and 91.3 s.
- After the three new pods: 3 good nodes in NVKE, 3 Ready nodes, 3 healthy etcd members, pod traffic 6 of 6.
- `/tmp` of each node then had only the folder `spire-agent`.

| Step | Time (UTC) | Result |
|---|---|---|
| Desired count 4 | PATCH 02:42:28 | 4 good nodes 122.1 s after the PATCH. `WaitForCAPIMachineReady` 45.2 s, `KubeadmJoin` 40.7 s, first attempt |
| Join strings for it | 02:43:17.853 | NVKE asked `kata-cp1-cp-502352ae` (new pod since 02:33, it never ran `kubeadm init`). `localAPIEndpoint=172.28.1.1:6443`. The join passed |
| Desired count 3 | PATCH 02:45:28 | 3 good nodes 58.7 s after the PATCH |

New Machine `kata-cp1-cp-3b3462ae`. After the scale up: pod traffic 16 of 16 lines. I went back to three nodes because R3 needs three.

## 7. R3: the rollout to p5

`PATCH /api/clusters/<id>` with `controlPlaneConfig.infra.machineTemplate` (image p5) at 02:47:17, HTTP 200. I did nothing after that.

| Node | New Machine | Replaces | Workflow of the new node starts | `WaitForCAPIMachineReady` | Join workflow | Teardown of the old node | Time for the node |
|---|---|---|---|---|---|---|---|
| 1 | `9b859b18`, `.3`, `kata-bb-worker2` | `502352ae`, `.1`, `kata-bb-worker2` | 02:47:17.5 | 45.2 s | 02:48:06.6 to 02:48:37.4 | 02:49:09.8 to 02:49:45.4 | 147.8 s |
| 2 | `43a3c6ef`, `.1`, `kata-bb-worker3` | `c4c42b53`, `.2`, `kata-bb-worker3` | 02:49:46.2 | 45.2 s | 02:50:34.6 to 02:51:26.2 | 02:51:59.3 to 02:52:34.0 | 167.8 s |
| 3 | `5f019555`, `.2`, `kata-bb-worker` | `3b3462ae`, `.4`, `kata-bb-worker` | 02:52:34.9 | 45.2 s | 02:53:23.3 to 02:54:04.1 | 02:54:52.5 to 02:55:26.6 | 171.7 s |

- Whole rollout: 489 s from the PATCH to the end of the last teardown. NVKE set "Control plane nodes recycling completed successfully" at 02:55:27. My end rule (two looks in a row) was true 504.7 s after the PATCH. Step 6: 151.7 s for one node with no stop, 1193.8 s for the whole rollout with two stops.
- Join strings in the rollout: join 1 used the kept strings of 02:43:17. For join 2 NVKE asked `kata-cp1-cp-c4c42b53` at 02:50:35.094 (a p4 node with a new pod since 02:36, `localAPIEndpoint=172.28.1.2:6443`). Join 3 used those strings. Each `KubeadmJoin` passed at its first attempt (30.1 s, 50.8 s, 40.1 s).
- Between the end of a join and the start of the teardown of the old node NVKE waited 32 to 48 s (until the new node is Ready, see the OVN image in section 4).
- Each new node runs p5: pod image `bcc4376f-p5`, the marker file says `p5`, the agent binary has the sha256 and the version of the fix.
- End state (02:56): 3 good nodes in NVKE, 3 Ready control plane nodes, 3 started and healthy etcd members, 3 pods on 3 host nodes, pod traffic 9 of 9 lines (6 of 6 between different nodes), name lookup 3 of 3, API Service 3 of 3. No pod of a deleted node was left in the new cluster.
- Two pods of the cluster on one host node: 02:47:24 to 02:49:42 on `kata-bb-worker2`, 02:49:54 to 02:52:31 on `kata-bb-worker3`, 02:52:42 to 02:55:24 on `kata-bb-worker`. Each surge pod ran on the host node of the node that NVKE replaced next. No `FailedScheduling` event.
- Storage loop: it made 2 volumes again after each of the three teardowns.
- Provider: 1 error line (section 9).

## 8. The shared address

One call each second to `https://172.29.255.220:6443/readyz` from the kind control plane node.

| Test | Calls | Answer 200 | Answer 500 | No answer |
|---|---|---|---|---|
| R1, replace of the first node | 193 | 191 | 2 (02:22:34, 02:22:37) | 0 |
| R2, three pod deletes | 163 each | 163 each | 0 | 0 |
| R3, rollout | 519 | 513 | 6 (02:49:22, 02:52:11, 02:52:13, 02:52:15, 02:55:04, 02:55:08) | 0 |

Cause of the 500 answers, with evidence:

- The teardown workflow of NVKE runs `StartControlPlaneGracefulShutdown` on the old node after the drain (02:22:33.8, 02:49:20, 02:52:10.0, 02:55:03). Each 500 came in the 6 s after that step.
- From that moment `/readyz` of the API server of the old node answers 500. The pod event says so: `Readiness probe failed: HTTP probe failed with statuscode: 500` (02:52:20 for `c4c42b53`, 02:55:06 for `3b3462ae`).
- The pod stays behind the Service until 3 probes fail (period 2 s). In that time about one call in four goes to the old node.
- The API server has `--shutdown-delay-duration=10s`. By the design of the API server it still serves requests in that time, and `/readyz` is the signal for a load balancer. I did not measure that with another API call. My probe calls only `/readyz`.

So the address answered each call, and 6 of 519 answers were the "not ready" answer of a node in its graceful shutdown. It is the same case as in step 6 (1 or 2 calls for each teardown). It has nothing to do with the agent fix. A provider that takes the pod out of the Service at the start of the delete would remove it.

## 9. Evidence of the fix

Source of the fix (read only): `agent/internal/agent/agent.go:94` (annotation), `:96` (config path), `:1562-1586` (the request takes a lock, writes the config, then runs upload-certs), `:1617-1618` (upload-certs always gets `--config`), `:1651-1681` (the config from the manifest annotation and the `kubeadm-config` ConfigMap), `:1679` (the log line).

The log line `wrote the kubeadm config for upload-certs`, from the agent journal of each node (a background loop read the journals each 15 s, because a deleted node takes its journal with it). File: `fix-1/fix-lines.txt`.

| Time (UTC) | Node that NVKE asked | `localAPIEndpoint` | For |
|---|---|---|---|
| 02:13:44.220 | `kata-cp1-cp-fe13d66d` (first node) | `172.28.1.1:6443` | The two joins of the new cluster |
| 02:19:31.770 | `kata-cp1-cp-c4c42b53` (joined node) | `172.28.1.2:6443` | R1 desired count 4, and the join after the DELETE of the first node |
| 02:29:14.437 | `kata-cp1-cp-c4c42b53` | `172.28.1.2:6443` | R1b |
| 02:43:17.853 | `kata-cp1-cp-502352ae` (new pod) | `172.28.1.1:6443` | R2, and join 1 of the rollout |
| 02:50:35.094 | `kata-cp1-cp-c4c42b53` (new pod) | `172.28.1.2:6443` | Joins 2 and 3 of the rollout |

- Each address is the node address on the node network. It is in the API server certificate of that node.
- On each asked node the agent ran `kubeadm init phase upload-certs --upload-certs --config /var/lib/nvke/kubeadm-upload-certs-config.yaml` (one line for each request, from the journal).
- The file `/var/lib/nvke/kubeadm-upload-certs-config.yaml`: 3022 bytes, mode 600. It has an `InitConfiguration` with `localAPIEndpoint` (`advertiseAddress` = the node address, `bindPort: 6443`) and the `ClusterConfiguration` of the cluster (`certificatesDir: /etc/kubernetes/pki`, `controlPlaneEndpoint: 172.29.255.220:6443`, `kubernetesVersion: v1.36.4`, pod and service subnets, the etcd settings). Copies: `fix-1/upload-certs-config/kata-cp1-cp-{fe13d66d,c4c42b53,502352ae}.yaml`. The file is on the `/var` volume, so it stays over a new pod.
- `/tmp/kubeadm-init-config.yaml` exists only on the first node. The agent writes it there at `kubeadm init`. It was absent on each other node, also on each node that NVKE asked after 02:19. In my evidence files the line label "files by hand" is a bad name for that check: nothing was written by hand.
- The agent redacts the token and the certificate key in its own log lines (`h1cmv0.<redacted>`, `"--certificate-key","<redacted>"`). The logs have no certificate key.

## 10. Placement after each step

| After | Machines (address, host node) | One pod for each host node |
|---|---|---|
| Cluster flow | `fe13d66d` (.1, worker2), `c4c42b53` (.2, worker3), `b9ce7667` (.3, worker) | holds |
| R1, count 4 | plus `11240139` (.4, worker) | does not hold (worker has 2) |
| R1, replace | `502352ae` (.1, worker2) in the place of `fe13d66d` | does not hold (worker has 2) |
| R1, count 3 | `502352ae`, `c4c42b53`, `11240139` | holds |
| R1b, count 4 | plus `314927d6` (.3, worker) | does not hold (worker has 2) |
| R1b, count 3 | `502352ae`, `c4c42b53`, `314927d6` | holds |
| R2, new pods | the same three, each on its host node | holds |
| R2, count 4 | plus `3b3462ae` (.4, worker) | does not hold (worker has 2) |
| R2, count 3 | `502352ae`, `c4c42b53`, `3b3462ae` | holds |
| R3, rollout | `43a3c6ef` (.1, worker3), `5f019555` (.2, worker), `9b859b18` (.3, worker2) | holds |

Each Machine ran on the host node of its failure domain in each step. Each scale down removed one of the two nodes on the host node with two pods (3 of 3 times).

## 11. Failures and their causes

No test failed. Points that are not clean:

1. R1 as the brief words it did not make NVKE ask a node after the first node was gone (5 minute cache of the controller, section 5). R1b and R2 cover that case.
2. 2 answers of 500 in R1 and 6 in R3 on the shared address (section 8). Cause: graceful shutdown of the old API server while its pod is still behind the Service.
3. One error line of the provider at 02:55:29.730: `failed to remove the finalizer from PodVMMachine kata-cp1-cp-3b3462ae: ... not found`. It is the line that step 6 reported (the object was gone already). It had no effect.
4. `command terminated with exit code 1` three times in the etcd check of the flow: a `grep -c` with the count 0 for refused peer connections. It is a line of my check, not a fault.

Two faults of my own scripts from step 6 are corrected: the rollout step now prints its RESULT line when no `FailedScheduling` event exists, and the cluster flow no longer fails on a pod map with two nodes.

## 12. Not tested

- A request for join strings to a p5 node. NVKE asked only p4 nodes. The agent binary is the same in p4 and p5.
- A join with a slow disk. Each value was at or below 1.5 ms.
- Another API call than `/readyz` in the seconds of a graceful shutdown.
- A failed upload-certs with the new agent (the error path of the fix). No request failed.
- Worker nodes, and a cluster with another Kubernetes version than v1.36.4.
- The reboot through NVKE and the literal delete with three nodes: NVKE refuses both by design (steps 5 and 6), not repeated.

## 13. Changes on the machine and how to remove them

All under `/root/kata-cp` or in the lab cluster. No firewall rule, no listener on an outside interface, no change of the Docker or containerd configuration or of the network settings, no restart, no database write, no Temporal change, no write on an NVKE or Cluster API object except through the NVKE API. Machine checks at the end are unchanged (disk 201 GB of 300 GB). The workstation got only scripts, logs and this file.

| Change | Removal |
|---|---|
| Cluster `kata-cp1` (NVKE ID `8caca331-bf11-415b-9742-851cbe3b4b45`), three nodes with the image p5 in `d`: `kata-cp1-cp-43a3c6ef`, `kata-cp1-cp-5f019555`, `kata-cp1-cp-9b859b18`. It stays up | `LOG_DIR=/root/kata-cp/logs/p2s6b/fix-1 p2-agentfix/run.sh delete`, then `p2-provider/storage.sh reset` |
| The cluster of steps 6 and 7 (three p3 nodes): gone, deleted through the NVKE API | Nothing to do |
| Images `nvke-node-podvm:bcc4376f-p4` and `-p5` in Docker and in the three workers, archives `dl/img/nvke-node-podvm_bcc4376f-p4.tar` and `-p5.tar` (2.0 GB each) | `docker rmi`, `ctr -n k8s.io images rm` in each worker, `unlink` of the archives |
| The agent binary `p2-agentfix/image/nvke-agent` (55 MB) and the build folder `work/p4-image-ctx` (53 MB) | Remove them |
| The storage loop and the evidence loop: stopped. 6 volumes Bound, 6 Available | Nothing to do |
| Folders `p2-agentfix`, `logs/p2s6b`, `secrets/d-fix-1` (mode 700, raw journals, controller log, workflow histories, kubeconfig of the cluster). `p2-replace/run.sh` and `disk.sh` have small changes (log paths from the environment, the RESULT line of the rollout) | Remove the folders |
