# Phase 2 gaps: the guard for the shared address and the capacity signal on the second machine (result)

Machine: `the second test machine`, 2026-11-27 16:20 to 20:28 UTC (11:20 to 15:28 workstation local time). This file has the tests of the second task (the two gaps) and of the third task (the fix for the encryption join defect). Each time below is UTC from `date -u` on the machine, when no other clock is named.
The session on the workstation stopped at 17:53 UTC and started again at 19:24 UTC. The detached drivers on the machine went on. Their files cover the whole time of the rollout that ran then.

Versions:

- Agent: `v0.24.0-beta.18-5-gf0d83222` (sha256 `feadfb1e...`) in the node images p6, p7 and p8-nogate. Settle time 15 s.
- Agent with the fix for the encryption join defect: `v0.24.0-beta.18-6-g41e88c4d` (sha256 `cafddb1d...`) in the node images p9 and p10.
- Provider: `cluster-api-provider-podvm:d2880014`. Controller: `nvke-controller:5c08484c`, Helm revision 1 to 2, new image tag only.
- Guest kernel of the class: `vmlinux-6.18.62-211-ovs-sockdiag` (with `INET_DIAG_DESTROY`).

Scripts: this folder, as they ran, with the corrections of section 6. The working copy is `/scratch/kata-cp/work/bigbox/remote/p2-gaps/`. The same files are in `/root/kata-cp/p2-gaps/` on the machine.
Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/p2gaps/` (copy of `/root/kata-cp/logs/p2gaps/`, no secrets folder). Run folders: `c-1` (encryption, key rotation, renewal, the stopped rollout), `c-2` (the two rollouts), `c-3` (pass rule 4), `c-4` (a cluster that I deleted while it came up, when the third task arrived), `c-5` (the test of the fix, the cluster that stays).

Each change of a cluster went through the NVKE API. I started three workflows with the commands of the product pages (two forced renewals and one key rotation) and did nothing else to any workflow. No file by hand in a guest. No database write. One Helm upgrade, as the task asked.

## 1. Verdict

| Pass rule | Verdict | Main facts |
|---|---|---|
| 1. Forced certificate renewal | PASS | 510 of 510 calls with 200. Only the node under renewal lost Ready, for 60 s, inside its own renewal. The worker stayed Ready. Workflow 8 min 9.0 s |
| 2. Encryption on (the test of the gate) | PASS | 356 of 356 calls with 200. No Node lost Ready. Workflow 5 min 32.4 s |
| 2. Key rotation (no guard, a check that nothing got worse) | PASS | 203 of 203 calls with 200. No Node lost Ready. No agent closed a gate. Workflow 2 min 57.9 s |
| 3. Rollout of the three control plane nodes | PASS, two rollouts | 968 of 968 and 1630 of 1630 calls with 200. No Node that was Ready lost Ready |
| 4. The gate fails safe | PASS | With a probe that does not read the gate the quiet window check failed, and the renewal did not start. The script printed FAIL for one check of mine that was wrong (section 3) |
| 5. NVKE shows the message of the provider | PASS, two rollouts | The pending message of the node in the NVKE API is the message of the `PodVMMachine` |
| 6. NVKE places the node in another domain after 15 minutes | PASS | The controller recorded the delete 15 min after the node was made, and the rollout ended with no operator step |
| 7. A place gets free before the 15 minutes | PASS | The pod got a host node 310 s after the Machine was made. The reason went away |
| Guest kernel with `INET_DIAG_DESTROY` | PASS | A throwaway pod of the class booted, and `ss -K` gave the client a reset |
| Fix for the encryption join defect (third task) | PASS | The ConfigMap keeps its 16 flags and 3 volumes and gets 2 flags and the volume `enc`. Three new control plane nodes joined at the first attempt. A new Secret is stored encrypted. 1569 of 1569 calls with 200 |

One defect in NVKE code stopped the first try of the rollout. A control plane node cannot join a cluster on which etcd encryption was turned on. It is not in the code of the two gaps. Section 6 has the evidence. The rollouts then ran on a cluster with encryption off. Section 7 has the test of the fix.

The cluster that stays up is c-5. It has three control plane nodes and one worker on p10, Kubernetes 1.36.4 and encryption on. It was healthy at 20:25.

## 2. Build and deploy

| Step | Time (UTC) | Result |
|---|---|---|
| Provider and controller images, on the workstation | 16:13 | Built with the earlier build commands, in 26 s and 33 s. The provider manifest differs from `bb15b535` only in the image line |
| Kernel switch of the class | 16:20:35 | One line in each kind node. No containerd restart |
| Kernel proof | 16:20:36 to 16:20:58 | A throwaway pod of the class with no cluster booted in 3 s with the kernel built at 15:28:39. `ss -K` closed the test socket. The `curl` client got "Connection reset by peer" (exit code 56) at 16:20:47. Pod and namespace removed |
| Node images p6, p7, p8-nogate | 16:21:15 to 16:25:05 | Build 15 s. Each save and load about 70 s. The flag check against the real help text passed |
| Delete of `kata-cp1` of the last test | 16:21:15 | NVKE API, old stack. Row and objects gone after 57.5 s |
| Provider `d2880014` | 16:26:34 | Manifest applied, rollout done |
| Controller `5c08484c` | 16:26:45 | `helm upgrade --reuse-values --set image.tag=5c08484c`. Revision 1 to 2 in 11 s. `/readyz` ok. API version `v0.24.0-beta.18-7-g5c08484c` |
| Cluster c-1 (p6, one worker) | 16:27:10 | Three Ready nodes 325.2 s after the POST. Worker good after 87.6 s |
| Cluster c-2 (p6, one worker, encryption off) | 17:21:31 | Three Ready nodes 297.1 s after the POST |
| Cluster c-3 (p8-nogate, no worker) | 19:27:51 | Up at 19:34:56 |
| Cluster c-4 (p7, one worker) | 19:39:03 | Started as the cluster that stays. The third task arrived, and I deleted it through the NVKE API at 19:44 while it came up (row gone after 46.3 s) |
| Node images p9 and p10 | 19:44:30 to 19:47:03 | Build 10 s. Each save and load about 70 s |
| Cluster c-5 (control plane p9, worker pool p10, encryption off) | 19:47:03 | Three Ready nodes 320.9 s after the POST. It stays up |

Each new cluster passed the flow checks, the health check and `gate-facts`. So the readiness probe of each control plane pod is the exec probe of `/usr/local/bin/podvm-endpoint-ready` (period 2 s, limit 3 s, 3 failures), the agent process has the three flags, the gate file does not exist, and each guest runs the new kernel.

## 3. The tests

### Encryption on (c-1, 16:37:52 to 16:43:25)

`PATCH /api/clusters/<id>` with `enableEtcdEncryption: true`.

| Phase | Now | Last test |
|---|---|---|
| Initialize, with the guard | 3 min 43.6 s. For each node 71.0 s (guard 50.3 s, change 20.5 s) | 1 min 42 s. For each node 30.7 s, 30.7 s, 40.7 s (guard 10 s) |
| Promote | 47.4 s | 1 min 56 s |
| Rewrite | 30 s | 31 s |
| Remove the plain text entry | 31 s | 88 s |
| Workflow | 5 min 32.4 s | 5 min 39.9 s |

- Shared address: 356 calls, 356 with 200. Last test: 353 of 357, with 4 answers 500 at the API server restarts.
- Ready watch: no Node lost Ready.
- The guarded phase is 2 minutes longer. The other phases were shorter in this run, so the whole workflow is not longer.
- Old Secret readable, new Secret stored with `k8s:enc:secretbox:v1`. Health and pod traffic pass after it.

### Key rotation (c-1, 16:44 to 16:48)

Started with the command of `controller/docs/etcd-encryption-key-rotation.md:186-194`, as in the last test.

- Workflow completed in 2 min 57.9 s (5 min 37.9 s in the last test). NVKE reports the rotation as succeeded.
- Shared address: 203 of 203 with 200 (357 of 357 in the last test, in a longer window).
- No Node lost Ready. No static pod has a new container. No agent closed a gate, because the rotation has no guard.

### Forced certificate renewal (c-1, 16:50:25.5 to 16:58:34.5)

Started with the command of `controller/docs/certificate-renewal.md:183-188`, as in the last test.

| Node | Gate closed | Renewal started | Gate opened | Node not Ready |
|---|---|---|---|---|
| `kata-cp1-cp-af3343a1` | 16:50:25.9 | 16:51:17 | 16:54:16.6 | 16:52:26 to 16:53:26 |
| `kata-cp1-cp-e331dc9e` | 16:54:27.3 | 16:55:18 | 16:56:17.7 | no |
| `kata-cp1-cp-fe49730b` | 16:56:28.3 | 16:57:19 | 16:58:13.7 | no |

- Workflow completed in 8 min 9.0 s (9 min 49.1 s in the last test). Each certificate has a later end date. Lock free.
- Shared address: 510 calls, 510 with 200. Last test: 587 of 593 (4 with no answer, 2 with 500).
- Ready watch: one time range. The node under renewal `kata-cp1-cp-af3343a1` was not Ready for 60 s, inside its own renewal. The worker `kata-cp1-wk-4701` stayed Ready, and its kubelet logged 0 lease errors. In the last test the worker was NotReady two times.
- The guard before the change took 51 s for each node (10 s in the last test). The change itself took 179.6 s, 59.7 s and 54.7 s (165.3 s, 160.3 s and 180.4 s in the last test).

### Rollout to p7 (c-2, rules 3, 5, 7)

`PATCH /api/clusters/<id>` with the machine template at 17:31:33. At the start the worker was on `kata-bb-worker3` with a control plane node, so that failure domain was full.

| Step | Time (UTC) | Result |
|---|---|---|
| Node 1: new `59c0551c` on `kata-bb-worker2` | 17:31:35 to 17:35:00 | Provision 47.8 s, join 41.7 s, teardown of `0dd0fbad` 69.5 s |
| Node 2: new `94ce4d61`, domain `kata-bb-worker3` | 17:35:00 | The pod is pending. Reason `FailureDomainUnavailable` at 17:35:10 |
| Operator step through the NVKE API | 17:38:03 to 17:40:05 | Pool count 2, second worker `wk-1637` good at 17:39:34 on `kata-bb-worker2`, pool count 1, DELETE of the worker on `kata-bb-worker3` at 17:39:44 |
| Node 2 goes on | 17:40:05 to 17:43:41 | Pod scheduled 25.8 s after the DELETE. Join 40.7 s, teardown of `915be18d` 69.1 s |
| Node 3: new `6f226b49` on `kata-bb-worker` | 17:43:42 to 17:47:11 | Provision 47.8 s, join 41.3 s, teardown of `1fad48e3` 74.0 s |
| End | 17:47:35 | Three new control plane nodes with p7, 961.5 s after the PATCH |

- Shared address: 968 calls from 17:31:28 to 17:47:56, 968 with 200. The last rollout had 6 of 519 calls with 500.
- Ready watch: no Node that was Ready lost Ready.
- The teardown of an old control plane node took 69.5 s, 69.1 s and 74.0 s (28.9 s, 33.9 s and 29.6 s in the last test).
- Provider: 0 error lines. Health, pod traffic and `gate-facts` pass after it.

### Rollout back to p6 (c-2, rules 3, 5, 6)

`PATCH /api/clusters/<id>` at 17:49:53. No operator step. At the start the worker was on `kata-bb-worker2` with a control plane node.

| Step | Time (UTC) | Result |
|---|---|---|
| Node 1: new `5436ecbc` on `kata-bb-worker` | 17:49:52 to 17:53:27 | Provision 48.2 s, join 41.1 s, teardown of `6f226b49` 69.6 s |
| Node 2: new `a204de2d`, domain `kata-bb-worker2` | 17:53:27 | The pod is pending. Reason `FailureDomainUnavailable` at 17:53:38 |
| NVKE records the delete of the stuck node | 18:08:35.305 | 15 min after the node was made. Teardown workflow 18:08:35 to 18:09:39 |
| Node 2 again: new `d41114a8`, domain `kata-bb-worker` | 18:09:40 to 18:13:08 | Provision 48.1 s, join 41.2 s (joined 18:11:10), teardown of `59c0551c` 69.2 s |
| Node 3: new `ef5f9f5c` on `kata-bb-worker3` | 18:13:09 to 18:16:42 | Provision 47.5 s, join 50.7 s, teardown of `94ce4d61` 74.1 s |
| End | 18:17:10 | Three new control plane nodes with p6, 1637.1 s after the PATCH. 911 s of it was the wait of node 2 |

- Shared address: 1630 calls from 17:49:45 to 18:17:28, 1630 with 200.
- Ready watch: no Node that was Ready lost Ready. The list of the Nodes came each time.
- Placement at the end: `kata-cp1-cp-5436ecbc` and `kata-cp1-cp-d41114a8` on `kata-bb-worker`, `kata-cp1-cp-ef5f9f5c` on `kata-bb-worker3`, the worker on `kata-bb-worker2`. So two control plane nodes are on one host node, as the design note says.
- Health, pod traffic and `gate-facts` pass after it. The cluster was still healthy at 19:26.

### Pass rule 4 (c-3, 19:35:49 to 19:36:21)

Cluster with three control plane nodes on p8-nogate. The probe program of each pod has no line that reads the gate file. 12 clients with a long-lived connection ran on the machine, one `kubectl get configmaps --watch` each, through the shared address. Before the start the three nodes had 7, 4 and 10 established sockets of remote clients on `eth0` port 6443. Then the forced renewal, with the command of the product page.

| Time (UTC) | Event |
|---|---|
| 19:35:49.923 | The agent of `kata-cp1-cp-004170b6` closed its gate |
| 19:35:49 to 19:36:10 | The pod stayed ready and stayed in the ready endpoints of the shared Service |
| 19:36:04.994 to 19:36:05.064 | After the settle time the agent closed 4 sockets |
| 19:36:05.2 | Two of the 12 clients lost their connection. They connected again 1 s later |
| before 19:36:10 | The quiet window check failed. A new socket came from `172.29.0.2` |
| 19:36:10.064 | The agent opened the gate (20.1 s after it closed it) |
| 19:36:20.894 | The workflow failed, 31.5 s after its start. No renewal step ran |

- NVKE: `certificateRenewal.state: failed`, phase `renew-node`. The message ends with the text `failed at step "waiting_for_endpoint_backend_socket_quiet_window": control plane endpoint backend socket quiet window failed on 10.244.3.76: new remote VIP:6443 sockets appeared after kube-vip exit: 10.244.3.76:6443 -> 172.29.0.2:17025`.
- No certificate has another end date. No static pod has a new container. The lock is free. No gate file is left. The pods of the provider have no change.
- Shared address: 106 of 106 with 200. Health passes after it.
- The file `t4-t4.txt` ends with `RESULT pass rule 4 (t4): FAIL`. One check of my script looked for a log line of the agent about the quiet window. The agent writes no such line. The text of the failed check is in the status of its operation, and NVKE shows it. I corrected the check after the run. The other checks passed.
- The cluster went away with a DELETE through the NVKE API (row gone after 34.9 s).

## 4. The gate evidence

Each line is one closed gate. The seconds count from the closed gate. The sources are the agent journal of each node (read each 3 s while the pod existed), a watch of the pods and a watch of the EndpointSlice of the shared Service on the machine.

| Test | Node | Gate closed | Pod not ready | Out of the EndpointSlice | Sockets closed | Withdrawal done | Gate opened | In the EndpointSlice again |
|---|---|---|---|---|---|---|---|---|
| Encryption on | `af3343a1` | 16:37:53.469 | 5.0 s | 5.0 s | 7 | 45.8 s | 70.8 s | 72.6 s |
| Encryption on | `e331dc9e` | 16:39:04.455 | 4.2 s | 4.2 s | 7 | 45.8 s | 70.9 s | 72.3 s |
| Encryption on | `fe49730b` | 16:40:15.412 | 6.1 s | 6.1 s | 8 | 45.8 s | 70.8 s | 72.2 s |
| Renewal | `af3343a1` | 16:50:25.942 | 6.0 s | 6.0 s | 8 | 45.8 s | 230.7 s | 232.1 s |
| Renewal | `e331dc9e` | 16:54:27.263 | 5.5 s | 5.5 s | 5 | 45.8 s | 110.4 s | 111.5 s |
| Renewal | `fe49730b` | 16:56:28.265 | 5.3 s | 5.3 s | 10 | 45.8 s | 105.4 s | 107.1 s |
| Rollout to p7, teardown | `0dd0fbad` | 17:33:56.090 | 4.9 s | 4.9 s | 4 | 45.7 s | never | |
| Rollout to p7, teardown | `915be18d` | 17:42:37.394 | 5.6 s | 5.6 s | 2 | 45.7 s | never | |
| Rollout to p7, teardown | `1fad48e3` | 17:46:07.039 | 4.5 s | 4.5 s | 5 | 45.8 s | never | |
| Rollout to p6, teardown | `6f226b49` | 17:52:23.212 | 4.9 s | 4.9 s | 4 | 45.7 s | never | |
| Rollout to p6, teardown | `59c0551c` | 18:12:04.833 | 4.2 s | 4.2 s | 6 | 45.8 s | never | |
| Rollout to p6, teardown | `94ce4d61` | 18:15:38.913 | 4.9 s | 4.9 s | 3 | 45.7 s | never | |
| Rule 4 (probe does not read the gate) | `004170b6` | 19:35:49.923 | never | never | 4 | failed | 20.1 s | |

- The pod was not ready 4.2 to 6.1 s after the closed gate, and it left the EndpointSlice in the same instant. That is 9 to 11 s before the end of the settle time of 15 s.
- The agent closed 2 to 10 sockets for each node. The peers were the host nodes (`172.29.0.x`) and the pod gateway of the host node (`10.244.x.1`).
- No new socket came in the quiet window of 30 s in the 12 cases with the gate. With the probe that does not read the gate one came, and the operation did not start.
- The withdrawal takes 45.7 to 45.8 s. That is 15 s settle, about 0.1 s for the sockets and 30.6 s quiet window.
- Added time against the last test. The guard before a change takes 50.3 s for each node (10 s before). The teardown of a control plane node takes about 70 s (about 30 s before). So each guarded step on a node is about 40 s longer.
- No call to the shared address failed in any test with the gate. The tests had 356, 510, 968 and 1630 calls, each with 200.

The agent lines of one node (encryption on, `kata-cp1-cp-af3343a1`):

```
16:37:53.469 closed the control plane endpoint gate
16:37:53.473 waiting for the load balancer to act on the closed control plane endpoint gate backend 10.244.3.72
16:38:08.502 closing stale remote VIP socket 172.29.0.3:10074      (7 such lines, to 16:38:08.626)
16:38:39.263 no new remote VIP sockets observed
16:38:39.263 withdrew this node from the control plane endpoint through the gate backend 10.244.3.72
16:38:39.278 kube-vip is not configured; skipping kube-vip withdrawal
16:39:04.304 kube-vip is not configured; skipping kube-vip restore
16:39:04.308 opened the control plane endpoint gate
```

All lines of each test are in `gate-lines-<label>.txt` of the run folder. The table is in `gate-report-<label>.txt`.

## 5. The capacity evidence

### Rule 5 and rule 7 (rollout to p7, Machine `kata-cp1-cp-94ce4d61`, domain `kata-bb-worker3`)

At 17:35:10 the three places show the same text:

- `PodVMMachine`, condition `Ready`: status `False`, reason `FailureDomainUnavailable`, message `Pod d/kata-cp1-cp-94ce4d61 cannot be scheduled in the failure domain "kata-bb-worker3": 0/4 nodes are available: 1 node(s) didn't find available persistent volumes to bind, 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector`.
- Machine, condition `InfrastructureReady`: status `False`, reason `FailureDomainUnavailable`, the same message.
- Node in the NVKE API: conditions `pending` and `provisioningClaimed`, pending message with the same text.

After the DELETE of the worker on that host node at 17:39:44:

- 17:40:05: the scheduler assigned the pod to `kata-bb-worker3`, 310 s after the Machine was made.
- `PodVMMachine` and Machine: reason `WaitingForPod`, then `WaitingForNodeAgent`, then `PodRunning`. The pending message of NVKE changed to `Pod d/kata-cp1-cp-94ce4d61 does not run yet`.
- The node joined, and the rollout ended.

### Rule 5 and rule 6 (rollout to p6, Machine `kata-cp1-cp-a204de2d`, domain `kata-bb-worker2`)

- 17:53:38: reason `FailureDomainUnavailable` on the `PodVMMachine` and on the Machine, and the message of the provider as the pending message of the node in the NVKE API.
- 18:08:35.305, a line of the controller log with `"msg":"Recorded delete of a control-plane node stuck pending in its failure domain","nodeName":"kata-cp1-cp-a204de2d","failureDomain":"kata-bb-worker2"`.
- 18:08:35 to 18:09:39: the teardown workflow of that node. Two of its activities failed, `LabelNode` and `KubeadmReset` (after 60 s). The node never ran. The workflow completed.
- 18:09:40: NVKE made `kata-cp1-cp-d41114a8` with the failure domain `kata-bb-worker`. It joined at 18:11:10.
- At the end no control plane Machine is in `kata-bb-worker2`.
- The cluster record of the NVKE API does not show the mark of the failure domain. I saw the mark only through its effect.

The watch file of each rollout is `gap2-<label>-watch.txt`. The check is `gap2-check-<label>.txt`.

## 6. Failures and their causes

### A control plane node cannot join after encryption was turned on (NVKE code, not the code of the two gaps)

The first rollout to p7 ran on c-1, after "encryption on". It stopped at the first node.

- The surge node `kata-cp1-cp-9e6e3223` never joined. `JoinNode` failed 2 times with a timeout of `KubeadmJoin` (17:07:34 and 17:13:06) and ran again.
- On the node `etcd`, the controller manager and the scheduler ran. The API server had no container. The kubelet logged `MountVolume.SetUp failed for volume "encryption-config" ... hostPath type check failed: /etc/kubernetes/encryption-config.yaml is not a file`.
- The manifest that `kubeadm join` made has two volumes for the encryption. They are `enc` for the folder `/etc/kubernetes/kube-api-encryption` (it exists, the agent wrote the config there), and `encryption-config` for the file `/etc/kubernetes/encryption-config.yaml` with the type `File`. Nothing makes that file.
- The volume comes from the `kubeadm-config` ConfigMap. After "encryption on" its `apiServer` part has only 2 arguments (the two encryption arguments) and 2 volumes (`encryption-config` and `enc`). A new cluster has 16 arguments and 3 volumes there (`audit-logs`, `audit-policies`, `oidc-auth-config`). So "encryption on" also removed the other 16 arguments and the 3 volumes from the ConfigMap. The running API servers keep them. A node that joins later does not get them.
- The cause is in the source of the agent (the lab agent `f0d83222`, and the same lines on `main` at `d625fcfa`), in `agent/internal/agent/etcd_encryption_at_rest.go:889-940`, function `updateEncryptionEntryForKubeadmConfigMap`. The file uses `gopkg.in/yaml.v2` (`:21`). With it the `apiServer` part is not a `map[string]any`, so the check at `:909-914` makes a new empty map, and `:916-924` sets `extraVolumes` to one entry for `/etc/kubernetes/encryption-config.yaml`. The first control plane node calls it at the end of `InitializeKubernetesAPIEncryption` (`:289-292`). The controller then adds its own two arguments and the volume `enc` (`controller/internal/kubeadmconfig/configmap.go:37`).
- The effect is that each flow that adds a control plane node after "encryption on" fails. That is a rollout, an upgrade and a node replace.
- I recorded the evidence (`c-1/defect-encryption-join.txt`, `c-1/kubeadm-clusterconfiguration-after-enc.yaml`, `c-2/kubeadm-clusterconfiguration.yaml`), stopped my rollout driver, and deleted c-1 through the NVKE API (row gone after 57.5 s). I changed no code and wrote no file into a guest. The shared address answered 1078 of 1078 calls with 200 during the 18 minutes of the stopped rollout.

### Other points of the code, with no effect on a verdict

1. The agent writes no log line when the quiet window check fails. The text is only in the status of the operation. The text says "after kube-vip exit" on a node that has no kube-vip.
2. The teardown of a node that was never scheduled waits 60 s for `KubeadmReset` and then goes on.
3. The cluster record of the NVKE API does not show the failure domain that the controller marked.

### Lab faults, corrected

1. My detached start had the form `cd <folder> && setsid nohup <driver> &`. The shell that waits for the driver kept the output of my SSH call open, so the call ended only with the driver. No effect on a result. The later starts have no `cd`.
2. `gap2-check` stopped with exit code 2 for the rollout to p6, at a file that exists only after an operator step. I corrected it and ran it again on the recorded files. It reads only files.
3. The check of pass rule 4 that looked for an agent log line (section 3).
4. `gap2-check-r3.txt` of the third task prints `RESULT pass rule 6 (r3): FAIL`. The check counts the second pending Machine of that rollout as a case of rule 6. I freed its place with the same operator step, under another label. Rule 6 is not a pass rule of that test.
5. Before the first rollout I changed `gap2-check` so that it judges each pending Machine by its own case (rule 7 for the Machine whose place the operator step freed, rule 6 for each other one).

## 7. The test of the fix for the encryption join defect (third task, c-5)

The images p9 and p10 have the content of p6 and p7 and the agent with the fix. Provider and controller have no change. The cluster c-5 came up with the control plane on p9, so the node that ran `kubeadm init` had the new binary before encryption was turned on. Its worker pool has the image p10, so that the worker is on p10 at the end.

### The ConfigMap (steps 3 and 4)

The `apiServer` part of the ClusterConfiguration in the `kubeadm-config` ConfigMap. Names only.

| | c-5 before | c-5 after encryption on (agent with the fix) | c-1 after encryption on (old agent) |
|---|---|---|---|
| Flags | 16 | 18 (the same 16, `encryption-provider-config`, `encryption-provider-config-automatic-reload`) | 2 (only the two encryption flags) |
| Volumes | `audit-logs`, `audit-policies`, `oidc-auth-config` | The same 3 and `enc` (`/etc/kubernetes/kube-api-encryption`, `DirectoryOrCreate`) | `enc` and `encryption-config` (`/etc/kubernetes/encryption-config.yaml`, type `File`) |

The 16 flags are `audit-log-maxage`, `audit-log-maxbackup`, `audit-log-maxsize`, `audit-log-path`, `audit-policy-file`, `authentication-config`, `bind-address`, `enable-admission-plugins`, `etcd-compaction-interval`, `kubelet-certificate-authority`, `profiling`, `service-account-extend-token-expiration`, `shutdown-delay-duration`, `shutdown-send-retry-after`, `shutdown-watch-termination-grace-period`, `tls-cipher-suites`.

- PASS. Each of the 19 lines from before is still there. Exactly three lines are new. No volume names the file `/etc/kubernetes/encryption-config.yaml`.
- Encryption on ran from 19:57:19 to 20:04:10 (`PATCH` with `enableEtcdEncryption: true`). Workflow 6 min 50.9 s, 428 of 428 calls with 200, no Node lost Ready, rule check PASS.

### The rollout to p10 (step 5, PATCH at 20:05:09)

Two surges were pending in a full domain. The first place got free through the NVKE API after 69 s. The second worker of that step went to `kata-bb-worker2` and made that host node full, so the third surge was pending too. I freed its place with the same step after 66 s. A wait of 15 minutes was not necessary.

| Node | Machine made | Joined (`JoinNode`) | API server started | Teardown of the old node |
|---|---|---|---|---|
| `kata-cp1-cp-9847bd25` on `kata-bb-worker3` | 20:05:11, pending to 20:08 | 20:09:10 to 20:09:51 | 20:09:19 | `ac7ba1f6`, 20:10:24 to 20:11:33 |
| `kata-cp1-cp-79564e00` on `kata-bb-worker` | 20:11:34 | 20:12:23 to 20:13:04 | 20:12:31 | `90bc1eca`, 20:13:58 to 20:15:08 |
| `kata-cp1-cp-a3d39d47` on `kata-bb-worker2` | 20:15:09, pending to 20:18 | 20:18:37 to 20:19:19 | 20:18:48 | `0cf9ea90`, 20:20:12 to 20:21:26 |

- PASS. Three `JoinNode` workflows since the PATCH. Each is completed, and its `KubeadmJoin` activity started one time (attempt 1). No `JoinNode` workflow failed. All workflows since the PATCH are completed: 3 `JoinNode`, 5 `ProvisionNode`, 5 `TeardownNode`.
- PASS. The API server pod of each new node runs with `--encryption-provider-config`, 44 flags, 0 restarts. Without `--advertise-address` the 43 flags and their values are the same as on the three old nodes (one checksum for all six).
- Three new control plane nodes with p10, 4 good nodes, 996.6 s after the PATCH. Shared address during the rollout: 1002 of 1002 with 200. Provider: 0 error lines. Pass rule 3 holds here too.
- With the old agent the same step stopped at the first node (section 6).

### A new Secret (step 6)

At 20:23:31, after the rollout, with only new nodes in the cluster:

- `kubectl create secret generic p2gaps-encfix-after` through the API.
- The first bytes of its value in etcd are `k8s:enc:secretbox:v1:current-primary-enc`. It is not plain text. This is the check of the last encryption test (at most 48 bytes, cut inside the guest).
- The Secret is readable through the API with the same value. Then I deleted it.

### The two watches for the whole test (step 7)

- Shared address, one call each second from 19:56:51 to 20:23:32. 1569 calls, 1569 with 200.
- Ready watch for the same time: no Node that was Ready lost Ready. The list of the Nodes came each time.

### The gate in this test

| Step | Node | Gate closed | Pod not ready | Out of the EndpointSlice | Sockets closed | Withdrawal done | Gate opened |
|---|---|---|---|---|---|---|---|
| Encryption on | `0cf9ea90` | 19:57:20.579 | 5.9 s | 5.9 s | 7 | 45.9 s | 70.9 s |
| Encryption on | `90bc1eca` | 19:58:31.597 | 6.1 s | 6.1 s | 7 | 45.8 s | 80.9 s |
| Encryption on | `ac7ba1f6` | 19:59:52.584 | 4.7 s | 4.7 s | 9 | 45.8 s | 81.2 s |
| Rollout, teardown | `ac7ba1f6` | 20:10:29.827 | 5.5 s | 5.5 s | 2 | 45.7 s | never |
| Rollout, teardown | `90bc1eca` | 20:14:04.537 | 5.2 s | 5.2 s | 6 | 45.8 s | never |
| Rollout, teardown | `0cf9ea90` | 20:20:22.726 | 5.8 s | 5.8 s | 7 | 45.8 s | never |

### The end state

The cluster of c-5 has the NVKE ID `394bd6d7-5872-41bc-b616-bc5f32378d9d`. At 20:25 it has `etcdEncrypted: true`, the condition `provisioned` only, 4 good nodes, 4 Ready nodes, 3 healthy etcd members, pod traffic passes, no workflow runs.

| Node | Address | Host node | Image |
|---|---|---|---|
| `kata-cp1-cp-79564e00` | `172.28.1.2` | `kata-bb-worker` | p10 |
| `kata-cp1-cp-a3d39d47` | `172.28.1.4` | `kata-bb-worker2` | p10 |
| `kata-cp1-cp-9847bd25` | `172.28.1.5` | `kata-bb-worker3` | p10 |
| `kata-cp1-wk-5163` (worker) | `172.28.1.1` | `kata-bb-worker` | p10 |

## 8. Numbers that differ from the last test

| Number | Last test | Now |
|---|---|---|
| Encryption on, calls with 200 | 353 of 357 | 356 of 356, and 428 of 428 in the third task |
| Encryption on, workflow | 5 min 39.9 s | 5 min 32.4 s, and 6 min 50.9 s in the third task |
| Encryption on, guarded phase for each node | 30.7 s, 30.7 s, 40.7 s | 71.0 s each |
| Key rotation, calls with 200 | 357 of 357 | 203 of 203 |
| Key rotation, workflow | 5 min 37.9 s | 2 min 57.9 s |
| Renewal, calls with 200 | 587 of 593 | 510 of 510 |
| Renewal, workflow | 9 min 49.1 s | 8 min 9.0 s |
| Renewal, worker NotReady | 2 times | 0 times |
| Renewal, guard before the change | 10 s | 51 s |
| Rollout, calls with 200 | 513 of 519 | 968 of 968, 1630 of 1630, 1002 of 1002 |
| Rollout, teardown of a control plane node | 28.9 s, 33.9 s, 29.6 s | 69.1 s to 74.1 s |
| Pending surge in a full domain | waited with no end (stopped by hand after 16 min 53 s) | NVKE placed it again after 15 min, by itself |
| Delete of a cluster | 46.1 s | 57.5 s, 57.5 s, 46.1 s, 34.9 s, 46.3 s |
| Rollout of a cluster with encryption on | not tested | With the old agent it stops at the first node. With the fix three nodes join at the first attempt |

I do not know why the key rotation and the renewal on the second and third node were shorter than in the last test.

## 9. Not tested

- A repair of a cluster on which the old agent turned encryption on. The report of the fix says that the fix does not repair such a cluster.
- An upgrade and a node replace of a cluster with encryption on. The third task tested the rollout.
- A control plane join in the middle of the workflow that turns encryption on.
- The OIDC enabling and the etcd defrag with the gate.
- The gate after an agent restart or a node restart in the middle of an operation.
- A rollout that meets a full domain two times.
- A settle time of 10 s. All tests ran with 15 s.
- Pass rule 4 on the teardown path. It ran on the renewal.
- More than one run of each test.
- A scheduled certificate renewal cycle, and a worker pool with more than one node in a rollout.

## 10. Changes on the machine and how to remove them

All under `/root/kata-cp` or in the lab cluster. No firewall rule, no listener on an outside interface, no change of the Docker or containerd configuration or of the network settings, no restart of the machine, no database write.

| Change | Removal or way back |
|---|---|
| The cluster `kata-cp1` (run folder c-5, NVKE ID `394bd6d7-5872-41bc-b616-bc5f32378d9d`). It has three control plane nodes and one worker on p10 and encryption on. It stays up. In its namespace `default` the test pods and Services `p1-t-a` to `p1-t-d`, the ConfigMap `p1-probe` and the two test Secrets `p2g-before` and `p2g-after` of the encryption step | `LOG_DIR=/root/kata-cp/logs/p2gaps/c-5 /root/kata-cp/p2-gaps/run.sh delete`, then `/root/kata-cp/p2-provider/storage.sh reset` |
| The class `kata-clh-runtime-rs-fix-direct-ovs` uses the kernel `vmlinux-6.18.62-211-ovs-sockdiag` | `/root/kata-cp/p2-gaps/kernel/kernel-switch.sh old`. A running guest keeps its kernel |
| Provider `cluster-api-provider-podvm:d2880014` | Apply `p2-worker/install/infrastructure-components-bb15b535.yaml`. That provider needs a node image with the HTTPS probe (p5) |
| Controller `nvke-controller:5c08484c`, Helm revision 2 | `/root/kata-cp/p2-gaps/install-stack.sh rollback 1` |
| Images in Docker and in the kind nodes: `nvke-node-podvm:bcc4376f-p6`, `-p7`, `-p8-nogate`, `-p9`, `-p10` (archives in `dl/img/`, 2.0 GB each), the provider and controller images (archives in `dl/img/p2gaps/`). The cluster that stays uses p10 | `docker rmi`, `ctr -n k8s.io images rm` in each node, `unlink` of the archives |
| Three closed workflows in Temporal that I started: the forced renewal and the key rotation on c-1 (completed), the forced renewal on c-3 (failed, as the test asks). Their clusters are gone. The third task started no workflow by hand | Nothing to do |
| Secrets folders `secrets/d-c-1` to `d-c-5`, `d-free-r1`, `d-free-r3`, `d-free-r3b` (mode 700): kubeconfig files of the test clusters, raw logs, and the copy of the key Secret of c-1 from before the rotation | Remove the folders of c-1 to c-4 and of `d-free-r1`. Their clusters are gone |
| Folders `p2-gaps`, `logs/p2gaps`, `work/p6-image-ctx`, `work/p9-image-ctx`, `dl/img/p2gaps`, and the kernel build folders of the preparation | Remove the folders |
| The storage loop | Stopped at 20:25. Each driver starts it when it does not run. 8 volumes Bound, 4 Available |

At the end the disk has 224 GB of 300 GB in use (213 GB after the preparation) and 32 GB of memory are in use. No driver, no watch and no probe unit of mine runs.

The stack is ready for one more node image and one more cluster. The lab storage has six Machine places and c-5 uses four of them, so a second cluster of this size needs the delete of c-5 first.
