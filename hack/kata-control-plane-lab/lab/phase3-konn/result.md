# Phase 3, Konnectivity prototype: result of the lab test

The test ran on 2026-11-28 from 01:36 to 03:07. All times are UTC, from `date -u` on the second machine.

The design is `hosted/phase3-konnectivity-design.md` (way L, a prototype in the lab alone). The runbook is `prep.md` in this folder. The lab changes are the ones of the design, section 6, as the coordinator passed them on: one NetworkPolicy in the lab host cluster, one more port on the lab Service, two new image tags, and a delete of the mixed cluster that was up. Nothing changed on the second machine itself.

## 1. Verdict

### Pass rules

| Pass rule | Verdict | Evidence |
|---|---|---|
| 1. With the policy and no proxy, logs, exec and port forward to a pod on a worker fail through each API server | PASS | 18 of 18 calls fail (run k-1). The policy is the cause: 0 of 6 new connections with it, 6 of 6 with no policy, 0 of 6 with it again. NVKE keeps 5 good nodes |
| 2. With the proxy the same calls pass through each of the three API servers, and the kubelet sees its own node | PASS with the proxy server as a DaemonSet. FAIL with the proxy server as a static pod of the request | DaemonSet form (run k-3): 18 of 18 calls, each kubelet saw only its own node address. Static pod form (run k-2): 6 of 18 calls, only through the first node |
| 3. A control plane node that NVKE makes later has the flag and the file, and its API server uses the proxy | PASS with the DaemonSet form | A fourth node and a node that replaces a deleted one. 24 of 24 calls through four API servers, two times. Each new API server had the flag and no proxy server for 50 s and 38 s |
| 4. What still fails with an unreachable worker | Recorded, 27 lines as the design expects and 0 different | Pod traffic between a worker and the control plane nodes, the API Service and name lookup from a pod on a worker. NVKE shows each node as good |

### Deductions of the runbook, section 13

| Number | Deduction | Verdict | Evidence |
|---|---|---|---|
| 1 | kindnet applies the policy to a Kata pod | Yes | The three `reach` looks, 0 of 6, 6 of 6, 0 of 6 |
| 2 | The policy does not stop the NVKE controller and the answers to a worker | Yes | Run k-1 came to 5 good nodes with the policy in place. A kind node reaches port 15005 of each worker in each look |
| 3 | The Service keeps the added port through the base step of a later POST, and port 8132 goes to each ready control plane pod | Yes | The base step of two later POSTs left the port. Each agent has one connection to each proxy server |
| 4 | The API server connects to a socket below `/etc/kubernetes/policies` through the read only mount | Yes | The mount has `readOnly: true`, and the calls pass |
| 5 | The static pod starts on each control plane node | No | It runs on the first node only. On each node that joins, the manifest is gone before the join (section 4) |
| 6 | The proxy server v0.34.0 accepts the flag set | Yes | It starts, `/healthz` is 200, and it serves |
| 7 | The ports are free in a control plane guest and on a worker | Yes | Listener on 8132, health port 8133 answers, each agent pod is ready |
| 8 | NVKE brings the cluster to five good nodes with the flag and with no agent | Yes | Run k-2 in 5 min 45 s. Run k-3 in 5 min 34 s, there also with no proxy server |
| 9 | The agent pod starts on a worker with one network | Yes | 5 of 5 agent pods ready 6 s after the apply |
| 10 | Each agent gets a tunnel to each of the three servers through the one address | Yes | Each agent has 3 connections, each server has 5 tunnels (two minutes after the start) |
| 11 | With `destHost` a kubelet call goes to the agent of that worker | Yes | 6 of 6 and 8 of 8 looks show only the node address of the worker itself |
| 12 | `--sync-forever` of v0.34.0 lets an agent find a fourth server | Yes | With four servers each agent has 4 connections, and each server has 6 tunnels |
| 13 | A PATCH of the control plane count keeps the files of the control plane config | Yes | The fourth node and the replacement node have the egress file with the same checksum, and the flag |
| 14 | The fallback route | Not used | The policy works |

## 2. Runs and times

| Run | Request variant | POST | Result |
|---|---|---|---|
| k-1 | `direct` (no flag, no proxy) | 01:40:12 | 5 good nodes after 5 min 13 s, with the policy. Pass rule 1. Deleted at 02:03:30 |
| k-2 | `proxy` (flag, egress file, static pod manifest) | 02:05:28 | 5 good nodes after 5 min 45 s. The static pod runs on the first node only. Deleted at 02:24:13 |
| k-3 | `proxy-ds` (flag and egress file, the proxy server as a DaemonSet) | 02:25:53 | 5 good nodes after 5 min 34 s. Pass rules 2, 3 and 4. Deleted at 02:57:16 |
| e-1 | The mixed request of phase 3, direct form | 02:59:05 | The cluster that is up at the end (section 11) |

Each test request was posted with no wait for systemd in the pool commands, with the pod image p11 and the fixed simulator. Each worker had one network, the network of the kind nodes, with the addresses `172.29.2.11` and `172.29.2.12`. The control plane nodes had their node addresses `172.28.1.x`.

The each-second call to the shared address and the Ready watch ran in each run.

| Run | Calls with 200 after the first answer | Ready watch |
|---|---|---|
| k-1 | 1242 of 1242 | No Node that was Ready left Ready |
| k-2 | 971 of 971 | The same |
| k-3 | 1713 of 1713, through the fourth node, the node delete and the count change | Only the two control plane nodes that NVKE removed went away |

The delete through the NVKE API removed all in each run. The cluster row was gone after 57.5 s (k-1), 79.7 s (k-2) and 57.8 s (k-3). I did not look for the cause of the longer time of run k-2.

## 3. The unreachable worker, and pass rule 1

The NetworkPolicy `p3-konn-no-way-to-workers` in the namespace of the control plane pods allows each new connection from a control plane pod except to `172.29.2.0/24`.

The three looks of `konn.sh reach` on run k-1. Each look opens a new connection from each of the three control plane pods to port 10250 of each of the two workers.

| Look | Time | Connections with an answer | A kind node to port 15005 of each worker | NVKE |
|---|---|---|---|---|
| With the policy | 01:45:40 | 0 of 6 | Connects | `nodeAgentReady` and `kubernetesReady` for each node |
| With no policy, 10 s after its delete | 01:46:26 | 6 of 6 (HTTP 401 from the kubelet) | Connects | The same |
| With the policy again, 10 s after the apply | 01:46:40 | 0 of 6 | Connects | The same |

So the policy is the cause, and the network plugin of the host cluster applies it to a Kata pod.

Pass rule 1, `konn.sh rule k-1 baseline fail`:

- 18 of 18 calls fail (two workers, three API servers, three kinds of call).
- `exec` says `error: unable to upgrade connection: error dialing backend: dial tcp 172.29.2.12:10250: i/o timeout`.
- `logs` with a time limit of 60 s says `Error from server: Get "https://172.29.2.12:10250/containerLogs/default/p3-t-4/test?tailLines=1": dial tcp 172.29.2.12:10250: i/o timeout`, after 30 s.
- The port forward gets no answer.
- The kubelet of a worker saw no call.
- NVKE kept 5 good nodes for the whole time.

## 4. The static pod form (run k-2)

The request had the flag and two files, the egress selector config and the static pod manifest of the proxy server.

What the first control plane node shows, before any agent:

- The API server runs with `--egress-selector-config-file=/etc/kubernetes/policies/egress-selector-configuration.yaml`.
- The folder `/etc/kubernetes/policies` is mounted into the API server with `readOnly: true`.
- Both files are there with the checksums of this folder. The manifest folder has five files.
- The proxy server container runs. The socket `konnectivity-server.socket` exists. The listener is `*:8132`. `/healthz` is 200 and `/readyz` is 500, because no agent is there.

What each node that joined shows:

- The flag and the egress selector config are there.
- The static pod manifest is absent. The manifest folder has the four files of kubeadm. No proxy server runs, and no socket exists.

The cause is in NVKE. Before each join of a control plane node the controller runs `kubeadm reset` on that node. The reset empties the manifest folder.

- The agent journal of a joined node: `02:08:49.363 executing kubeadm reset`, `args=[reset -f --skip-phases=remove-etcd-member]`, `02:08:49.507 kubeadm reset finished`, then `02:08:50.086 args=[join --config /tmp/kubeadm-join-config.yaml]`. It is the first join of that node.
- The code is `cleanBeforeControlPlaneRejoin` in `controller/internal/temporal/workflows/provision_node.go:576` of the lab commit `5c08484c`. Its comment says that the cleanup has no condition.
- The runbook read the agent code, where a reset runs only after a failed join. The controller adds the reset for each control plane join.

So a static pod that comes as a bootstrap file exists only on the first node. A failed join is not needed for that. One `JoinNode` workflow failed in this run too, and that node got two resets.

The request schema has no command hook that runs after the join. The `infra` objects have three fields, `machineTemplate`, `bootstrapFiles` and `preKubeadmCommands` (`controller/api/openapi.yaml` of the lab commit). The commands run as cloud-init commands, before the reset. So the request has no second way for the manifest.

The rule check in this state, with the agent DaemonSet on each node:

| Through the API server of | Proxy server | Calls that pass | Error text |
|---|---|---|---|
| The first node | Runs (static pod) | 6 of 6. The kubelet sees its own node address | |
| The second node | None | 0 of 6 | `dial unix /etc/kubernetes/policies/konnectivity/konnectivity-server.socket: connect: no such file or directory` |
| The third node | None | 0 of 6 | The same |

- Each agent had one connection, to the one proxy server. A dial that the Service sent to a node with no proxy server ended with `connect: connection refused`, and the agent dialed again each 5 s.

## 5. The DaemonSet form (run k-3)

The coordinator decided the change after the finding of section 4. The request has the flag and the egress selector config only. The proxy server is a DaemonSet `konnectivity-server` in `kube-system` of the new cluster, with a node selector and tolerations for the control plane nodes, the host network, and the same container, flags, user and host paths as the static pod (`manifests/konnectivity-server-ds.yaml.tmpl`). The lab applies it after the cluster is up, like the agent DaemonSet (`konn.sh server k-3 apply`). It needs no NVKE code.

### An API server with the flag before its proxy server runs

Run k-3 came to 5 good nodes with the flag, with no proxy server and with no agent.

- Each API server starts. `/readyz` of each one is 200.
- NVKE needs no call from an API server to a kubelet to make the cluster.
- A kubelet call fails. `logs` says `Error from server: Get "https://172.29.2.12:10250/containerLogs/...": context deadline exceeded: connection error: desc = "transport: Error while dialing: dial unix /etc/kubernetes/policies/konnectivity/konnectivity-server.socket: connect: no such file or directory"`, after 30 s. `exec` says the same after 60 s.
- So the readiness of the API server says nothing about the proxy. The lab Service sends API calls to such a node.

### The start

| Time | Step |
|---|---|
| 02:31:27 | 5 good nodes |
| 02:31:48 | `konn.sh server k-3 apply`. 3 of 3 proxy server pods ready at 02:31:54 |
| 02:31:54 | `konn.sh agent k-3 apply`. 5 of 5 agent pods ready at 02:32:00 |
| 02:32:37 | Each proxy server has a socket, a listener and `/readyz` 200. The servers have 4, 4 and 5 tunnels |
| 02:34:18 | Each server has 5 tunnels, and each agent has 3 connections to `172.29.255.220:8132` |

The direct way stayed closed. `konn.sh reach k-3 proxy` gave 0 of 6.

### Pass rule 2

`konn.sh rule k-3 proxy pass` at 02:33:58:

- 18 of 18 calls pass: `logs`, `exec` and a port forward to the test pod on each of the two workers, through each of the three API servers.
- The kubelet of a worker sees each call from its own node address (`172.29.2.12` for the first worker, `172.29.2.11` for the second). 6 of 6 looks have no other address.

What the parts log:

- A proxy server: `"Connect request from agent"`, `"Agent connected"`, and `"Register backend for agent" agentID="172.29.2.11"`. The identifier is the node address of the agent.
- A proxy server sees an agent from the address of a kind host node, because the Service replaces the source address.
- An API server logs no line for a call that passes. For a call that fails it logs the socket error of section 4.
- An agent with `--sync-forever` dials the shared address again each 5 s. One proxy server logged 43 lines `"Agent connected"` and 76 lines `"Remove connection for agent"` in two and a half minutes, with five agents.

## 6. Pass rule 3, a control plane node that NVKE makes later

### A fourth node

`PATCH` of the control plane count to 4 at 02:34:37. 6 good nodes at 02:37:03.

| Time | Event on the new node `kata-cp1-cp-a5772987` |
|---|---|
| 02:35:35.2 | The API server container starts, with the flag from the `kubeadm-config` ConfigMap |
| 02:35:59 | The kubelet registers the Node |
| 02:36:04 to 02:36:24 | 22 lines of the API server about the absent socket |
| 02:36:25.6 | The proxy server container of the DaemonSet starts. The agent container starts in the same second |
| 02:36:26.9 | The first agent connects to the new proxy server |
| 02:36:48 | The first `logs` call through this API server passes |

- The API server had the flag and no proxy server for 50 s.
- The logs watch (one `logs` call through each API server each 5 s) had 4 failed calls through the new API server, from 02:36:10 to 02:36:42. The first two ended at the time limit of the client. The last two said `Error from server: Get "https://172.29.2.12:10250/...": dial tcp 172...`. At that time the new proxy server had agents, and not yet the agent of that worker, so the call went to another agent.
- The watch had no failed call through the three old API servers.
- The new node has the egress selector config with the same checksum, the flag in its manifest and in its process, a proxy server, the socket and 6 tunnels. It has no static pod manifest.
- Each agent found the fourth server. Each agent has 4 connections, and each of the four servers has 6 tunnels (four agents on control plane nodes, two on workers). The servers have `--server-count=3`.
- `konn.sh rule k-3 four pass`: 24 of 24 calls through the four API servers, 8 of 8 looks with only the own node address.

### A node that replaces another

`DELETE /api/nodes/<ID>` of the first control plane node `kata-cp1-cp-531375ef` at 02:39:05. NVKE made `kata-cp1-cp-41eece20` by itself. 6 good nodes at 02:42:26.

| Time | Event |
|---|---|
| 02:40:13 | One call of the logs watch to the old API server is refused |
| 02:41:15.9 | The API server container of the new node starts |
| 02:41:39 | The kubelet registers the Node |
| 02:41:41 to 02:41:53 | 14 lines of the API server about the absent socket |
| 02:41:54.3 | The proxy server container starts |
| 02:41:55.4 | One line `No agent available` |
| 02:42:01 | The first `logs` call through this API server passes |

- The API server had the flag and no proxy server for 38 s.
- The logs watch had 2 failed calls through the new API server, at 02:41:47 (time limit) and 02:41:55 (`No agent available`).
- `konn.sh rule k-3 replaced pass`: 24 of 24 calls, 8 of 8 looks with only the own node address.

### Back to three

`PATCH` of the count to 3 at 02:43:50. NVKE removed the fourth node. 5 good nodes at 02:45:09. Each server then has 5 tunnels, and each agent has 3 connections.

The logs watch from 02:33:58 to 02:45:21:

| API server | Calls | Failed |
|---|---|---|
| The two nodes that stayed | 119 each | 0 |
| The fourth node | 92 | 4 at its start, 1 refused at its removal |
| The address of the first node, old and new | 104 | 1 refused at the removal of the old node, 2 at the start of the new one |

## 7. Pass rule 4, what still fails

`konn.sh still k-3 proxy` at 02:46, with agents on each node. 27 lines are as the design expects, and 0 are different.

| Check | Result |
|---|---|
| What NVKE shows | Each of the five nodes is good (`joined`, `kubernetesReady`, `nodeAgentReady`, `provisioned`) |
| What Kubernetes shows | Each Node is Ready. The OVN pod of each worker has 4 of 5 containers ready |
| `exec` into a pod on a worker | Works, through the proxy |
| A pod on a worker to a pod on a control plane node, ping and TCP | Fails, 12 of 12 |
| A control plane node to a pod on a worker, TCP | Fails, 6 of 6 |
| A pod on a worker to a pod on the other worker | Works. The workers share one network |
| The API Service from a pod on a worker | Fails, 2 of 2 |
| Name lookup from a pod on a worker | Fails, 2 of 2 |
| The traffic matrix of the lab (`p3ab.sh traffic`) | control plane to control plane 6 of 6, control plane to worker 0 of 6, worker to control plane 0 of 6, worker to worker 2 of 2. Name lookup 3 of 5 nodes |
| The NVKE controller to the node agent of each worker | Works. It does not use the proxy |

The proxy carries a call to a kubelet. It gives the pod network no path.

### The agents on each node, and on the workers only

The design has the agent on the workers only. The coordinator decided to run it on each node. I measured both.

| Call through each API server | Agents on each node | Agents on the workers only |
|---|---|---|
| `logs`, `exec`, port forward to a pod on a worker | Pass | Pass |
| `logs` of a pod on a control plane node | Pass, 3 of 3 | Fail, 3 of 3: `dial tcp 172.28.1.3:10250: i/o timeout` |
| Pod proxy to a pod on a worker | 5 of 24 pass | 36 of 36 pass |
| Service proxy to a pod on a worker | 9 of 24 pass | 36 of 36 pass |
| Pod proxy to a pod on a control plane node | Not measured | Fail, 3 of 3 |

- A failed pod proxy call says `Error from server (ServiceUnavailable): error trying to reach service: dial tcp 10.113.2.4:8080: i/o timeout`.
- The cause. A call to a kubelet goes to the agent of that node (`destHost`). A call to a pod address goes to any agent (`default`). With agents on each node, three of five agents are on a control plane node and cannot reach a pod on a worker.
- The agents on the control plane nodes made no other trouble. The cluster stayed good.
- So in a network where the two sides do not reach each other, no agent placement makes each call work. A webhook or an aggregated API server on a worker is a call to a pod address.

## 8. The open points of the design

| Open point | Answer |
|---|---|
| Can the API server use the socket through the folder that NVKE mounts read only | Yes. The socket folder is below `/etc/kubernetes/policies`. The connect needs no write |
| Does each agent get its three tunnels through the one address | Yes. The lab Service spreads the dials. Each worker agent had three servers 43 s after its start. The last agent on a control plane node had its third server between 43 s and 144 s after its start, with one dial each 5 s |
| What does a failed join do to the static pod | The question is wider. Each join of a control plane node removes the manifest, because NVKE runs `kubeadm reset` before it |
| A new control plane node takes API calls before its proxy server has an agent | Yes. 38 to 50 s with no proxy server, and some seconds more until the agent of the target node is connected. The answers are the socket error, a call through another agent that then fails, or `No agent available` |
| The version | v0.34.0 of both images works with Kubernetes 1.36.4 |

Not answered: if the tunnels stay through a guarded operation of the health gate, and what a later change of the etcd encryption does to the flag.

## 9. Faults and their causes

| Fault | Cause | What I did |
|---|---|---|
| The static pod of the proxy server is absent on each control plane node that joins | NVKE. It runs `kubeadm reset` before each control plane join. This is how NVKE works, and it is a fault only for this prototype | Recorded the evidence. The proxy server became a DaemonSet, by the decision of the coordinator |
| The first POST of run k-2 did not go out | Lab script. The step `port status` of `konn.sh` failed on a Service with no endpoint, and the POST step stopped | Corrected the step and posted again. The first try made no cluster |
| The agent image was only in the worker image | Lab image. The decision for agents on each node came after the preparation | The pod image p11 has both images |
| `konn.sh still` expected a failed `logs` call for a pod on a control plane node | Lab script, the same decision | The step takes the agent placement as a setting, and adds the pod proxy and Service proxy counts |
| The time field of the logs watch has wrong numbers | Lab script | Not corrected. No result uses it |
| One `JoinNode` workflow failed in run k-2, and NVKE ran it again | NVKE, control plane join. The runs c-1 and d-1 of phase 3 had the same | Not looked into |

No fault of the two Konnectivity images, of CAPNICo or of the simulator came up.

## 10. What the prototype shows about Konnectivity in this design

1. The parts work in the kubeadm form of NVKE with no NVKE code. NVKE accepts the API server flag and the config file in the request. A node that joins later gets the flag from the `kubeadm-config` ConfigMap and the file from the control plane config.
2. The proxy server cannot come as a static pod of the request. NVKE removes it on each node that joins. A DaemonSet on the control plane nodes works. A product form needs the proxy server from NVKE itself, in a way that the reset before the join does not remove.
3. The API server reaches the socket through the folder that NVKE mounts read only. The proxy server works with the certificate of the API server and the admin kubeconfig. Both are lab shortcuts.
4. One shared address with one more port is enough for the agents. Each agent finds each proxy server, also a fourth one.
5. An API server with the flag takes calls before its proxy server runs. The cluster comes up and looks good, and each kubelet call through that API server fails. In a rollout each new node has that window, 38 to 50 s in the lab.
6. With the proxy, `logs`, `exec` and port forward reach a worker that the control plane cannot open a connection to. The kubelet sees its own node as the caller.
7. The proxy does not make such a worker a working node. Its pods do not reach the pods on the control plane nodes, the API Service or the name service, and its OVN pod is not fully ready. NVKE and Kubernetes still show a good node.
8. A call to a pod address works only through an agent that reaches the pod. With the control plane nodes as nodes of the cluster, no agent placement gives that for each pod.
9. So the lab result agrees with the design, section 2. In this form a network that lets the pod network work also lets the API server reach the workers directly, and Konnectivity is then not needed. With a network where the two sides do not reach each other it is not enough.

## 11. What changed in the lab, and that it is back

| Change | State at the end |
|---|---|
| NetworkPolicy `p3-konn-no-way-to-workers` in the namespace `d` of the host cluster | Removed at 02:58:48. No NetworkPolicy is in the host cluster |
| Port 8132 on the Service `cp-api` | Removed at 02:58:48. The Service has the one port 6443 |
| The simulator container with one network and the worker image w2 | Removed. The simulator runs again in the step B form, with two networks, the worker image w1 and the fixed binary |
| The clusters of the runs k-1, k-2 and k-3 | Deleted through the NVKE API. No object, no worker container and no simulator instance was left each time |
| The mixed cluster of run d-1 that was up before | Deleted through the NVKE API at the start |
| The storage loop | Ran from 02:34:37 to 02:58:34. Stopped |

What stays:

- The image tags `nvke-node-podvm:bcc4376f-p11` (in Docker and in the three host nodes) and `nvke-node-nico:bcc4376f-w2` (in Docker). p11 is p10 with the proxy server image and the proxy agent image. w2 is w1 with the proxy agent image.
- Three archives in `/root/kata-cp/dl/img` (the two public images and p11), the build contexts in `/root/kata-cp/work`, the scripts in `/root/kata-cp/p3-konn`, and the run folders `k-1`, `k-2`, `k-3` and `konn-build` in `/root/kata-cp/logs/p3`. The runbook, section 16, has the removal of each one.
- The mixed cluster of run e-1 in the direct form: three control plane nodes as pods on p10, two workers with two networks (`172.28.2.11` and `172.28.2.12` on the node network), the request with no wait for systemd, the fixed simulator. It had 5 good nodes at 03:05:01, 5 min 56 s after the POST. Both worker starts have the status `done` and joined at the first attempt. Pod traffic passes on 20 of 20 lines, name lookup on 5 of 5 nodes, and `logs`, `exec` and port forward pass through each API server with no proxy. The each-second call had 302 of 302 good calls after the first answer. The each-second call and the Ready watch of run e-1 run and end by themselves 8 hours after their start.
- The controller is at Helm revision 3, as before this test.
- The disk of the machine has 221 GiB in use and 79 GiB free. Before the test it had 218 GiB in use.
- The kernel modules and the kernel settings look are the same as before the test.

On the second machine itself nothing changed. No firewall command, no Docker setting, no package and no kernel module came from me.

## 12. What is not tested

- Webhooks, aggregated API servers and metrics through the proxy. Only the pod proxy and the Service proxy.
- A rollout of the control plane to another image with the proxy, a certificate renewal, and the health gate with tunnels.
- The etcd encryption with the flag.
- The route variants of the request. The policy worked.
- A restart of a control plane pod of a Machine, which writes an absent bootstrap file again.
- More than one address for the agents, and kube-vip in the place of the lab Service.
- A proxy server with its own certificate and its own kubeconfig, and a proxy server that does not run as root.
- Another version than v0.34.0.
- A worker that is unreachable for a real reason. The policy stops only new connections from a control plane pod to the workers.
- The pass rules 2 and 3 with agents on the workers only. Section 7 has the comparison for single calls.

## 13. Files

Scripts and manifests in this folder:

| File | Content |
|---|---|
| `run/konn.sh` | The lab driver, with the new steps `server` and `gap` |
| `run/agents-workers-only.sh` | The comparison of section 7 |
| `manifests/konnectivity-server-ds.yaml.tmpl` | The proxy server as a DaemonSet |
| `manifests/konnectivity-agent.yaml.tmpl` | The agent on each node |
| `requests/render.sh` | With the variant `proxy-ds` |
| `image/Dockerfile.pod`, `image/build-konn-images.sh` | p11 with both images |

Logs on the workstation are in `/scratch/kata-cp/logs/bigbox/remote-logs/p3/`.

| File | Content |
|---|---|
| `k-1/reach-policy.txt`, `k-1/reach-no-policy.txt`, `k-1/reach-policy-again.txt` | The three looks |
| `k-1/rule-baseline.txt`, `k-1/rule3-baseline.txt`, `k-1/logs-long-timeout.txt` | Pass rule 1 |
| `k-2/facts-before-agent.txt`, `k-2/facts-with-agent.txt`, `k-2/manifest-absent.txt` | The static pod form and the reset before the join |
| `k-2/rule-static-only.txt`, `k-2/flag-no-proxy-server.txt` | The rule check with one proxy server, and the error texts |
| `k-3/facts-before-server.txt`, `k-3/readyz-before-server.txt` | The API servers before the proxy server |
| `k-3/facts-with-agent.txt`, `k-3/facts-rule2.txt`, `k-3/rule-proxy.txt`, `k-3/proxy-server-lines.txt` | Pass rule 2 |
| `k-3/gap-four.txt`, `k-3/facts-four.txt`, `k-3/rule-four.txt` | The fourth node |
| `k-3/gap-replaced.txt`, `k-3/facts-replaced.txt`, `k-3/rule-replaced.txt` | The node that replaces another |
| `k-3/logs-watch.txt`, `k-3/logs-watch-summary.txt` | The logs watch |
| `k-3/still-proxy.txt`, `k-3/traffic-proxy.txt`, `k-3/pod-proxy-error.txt`, `k-3/agents-workers-only.txt` | Pass rule 4 and the agent placement |
| `k-*/after-delete.txt`, `k-*/probe-*-summary.txt`, `k-*/ready-*.txt` | The deletes and the two watches |
| `konn-build/` | The two image builds |
