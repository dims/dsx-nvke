# Phase 3, result

The run went from 2026-11-27 22:31 to 2026-11-28 01:16. All times are UTC, from `date -u` on the second machine.

This note has the full result of phase 3: the deductions of step A, and the pass rules 1 to 6 with the reboot try. The detail of steps A and B is in `result-AB.md`. This note repeats their verdicts and adds the pass rules 4 to 6, the reboot try, the final cluster and the lab run of the simulator fix (section 17).

## 1. Verdict

### Deductions of step A

| Deduction | Verdict | Evidence |
|---|---|---|
| NVKE accepts the mixed request | Yes | `POST /api/clusters` gave HTTP 201 in four runs |
| A later step asks for a `NicoCluster` or fails on the kind | No | The NVKE controller log has 0 lines with `NicoCluster`. The Cluster object has `infrastructureRef` kind `PodVMCluster`. No `NicoCluster` object exists |
| CAPNICo v0.3.0-rc.1 makes an instance for a `NicoMachine` with `siteID` under a `PodVMCluster` | Yes | CAPNICo log line `creating NICo instance` 4 to 6 s after the POST. 0 lines of level error |
| The simulator starts the worker container | Yes | The container runs 7 s after the POST |
| The agent gets its identity with the join token | Yes | SPIRE agent journal line `Creating X509-SVID ... spiffe://kata-cp.nvke.local/host/<node ID>` |
| The controller reaches port 15005 of the worker | Yes | NVKE shows `nodeAgentReady` for each worker |
| `kubeadm join` passes | Yes, with the wait for systemd in the lab request. No without it (run a-1) | Fault 1 |
| The Node gets its provider ID with the NICo controllers of NVKE off | Yes | CAPNICo log line `set workload cluster Node providerID nico://<instance ID>` |
| The agent runs with the mlx5 rescan off | Yes, on each of the eight workers of this run | Journal line `"msg":"mlx5 rescan is disabled"` |
| Pod traffic between the worker and the control plane nodes fails with one network | Yes, it fails | 0 of 6 lines pass |

### Pass rules

| Pass rule | Verdict | Evidence |
|---|---|---|
| 1. Provisioned, three Ready control plane nodes as pods, two Ready workers from the mock | PASS | 5 good nodes 5 min 22 s after the POST (run b-1) |
| 2. Pod traffic in each direction and name lookup | PASS | 20 of 20 lines, name lookup 5 of 5 nodes |
| 3. `logs`, `exec` and port forward to a pod on each worker, through each API server | PASS | 18 of 18 checks |
| 4. A worker more and a worker less through the NVKE API | PASS | A new worker is a good node 57 s after the PATCH. Traffic 30 of 30 lines. After a node DELETE nothing of the worker is left (two times) |
| 5. Rollout of the control plane with workers | PASS | 701 of 701 calls with 200. No worker left Ready. No surge node met a full domain |
| 5. Forced certificate renewal with workers | PASS | 627 of 627 calls with 200. No worker left Ready |
| 6. Delete | PASS | The cluster row is gone 57.8 s after the DELETE. No pod, no claim, no Machine, no object of either provider, no instance, no worker container, no SPIRE entry |
| Reboot of a worker, controller as it is | Not complete in 10 minutes | NVKE starts its soft reboot and waits. The container starts again with the same boot ID |
| Reboot of a worker, soft reboot off | Works with the mock | The workflow `RebootNode` completes in 60.6 s. New boot ID, same node address |
| Fixed interface order of a worker | Works | Four workers from the corrected program. In two of them Docker connected the second network first, and one more time at a restart. The names and the first hosts line were right each time |
| The cluster of run c-1 | Came up on a slow disk, deleted for the next test | 5 good nodes, traffic 20 of 20 lines, rule 3 passes. 120 failed calls while it was made, then 1139 of 1156 calls with 200 (fault 4) |
| The simulator fix, with no wait for systemd in the request (run d-1) | PASS | Eight worker starts. Each one joins at the first attempt, the status is `done`, no `NodePreflight` fails on `check_cloud_init_status` (section 17) |
| The each-second call to the shared address, whole life of run b-1 | 1 failed call of 3983 | 3982 calls with 200 after the first answer. The one call with no answer is outside the flows, in a slow disk episode (fault 4) |

## 2. Runs and times

| Run | Form | POST | Result |
|---|---|---|---|
| a-1 | One network, the request of the preparation, one worker | 22:35:21 | The worker stays before the join (fault 1). Deleted at 22:48:10 |
| a-2 | One network, the request with the wait for systemd, one worker | 22:51:23 | 4 good nodes after 5 min 9 s. Deleted at 23:03:03 |
| b-1 | Two networks, two workers | 23:04:35 | 5 good nodes after 5 min 22 s. The pass rules 1 to 5 and the reboot try ran on it. Deleted at 00:16:03 |
| c-1 | Two networks, two workers from the corrected program | 00:17:31 | 5 good nodes after 17 min 6 s (fault 4). Deleted at 00:55:49 |
| d-1 | Two networks, two workers, the fixed simulator, the request with no wait for systemd | 00:59:06 | 5 good nodes after 5 min 36 s. Six refills of a worker. The cluster is up |

Times of the delete through the NVKE API:

| Run | State before | Cluster row gone |
|---|---|---|
| a-1 | One worker that did not join, its provision workflow runs | 57.6 s |
| a-2 | 3 control plane nodes, 1 worker | 46.2 s |
| b-1 | 3 control plane nodes, 2 workers, one reboot workflow that waits | 57.8 s |

## 3. Steps A and B in short

- With one network the worker joins, gets its provider ID and is a good node for NVKE. Pod traffic with the control plane nodes fails in each direction. The tunnel of the worker has an address that the control plane nodes cannot reach.
- With two networks the node address is the tunnel address on each node, and the pass rules 1 to 3 pass.
- NVKE makes the Machine and the `NicoMachine` of a worker by itself. It makes no `MachineDeployment`, no `NicoMachineTemplate` object and no `NicoCluster`.

`result-AB.md` has the tables.

## 4. The fixed interface order of a worker (lab script)

The fault. Docker 29.1.3 connects the two networks of a container in a random order at each start. A check with four throwaway containers on the machine showed both orders, and one container changed its order at a restart. The entry program of the kind node image takes the first address of the host name (`getent ahostsv4`), keeps it in `/kind/old-ipv4`, and at a restart replaces the old address by the new one in the kubeadm and kubelet files. So a restart could give the kubelet the address of the other network.

What I chose, in `sim/docker-two-nets`:

- The node network (`kata-bb-node`) is `eth0`. The network of the shared address (`kata-bb`) is `eth1`. Each network argument gets `driver-opt=com.docker.network.endpoint.ifname=<name>`.
- The program adds `--add-host <host name>:<node address>`. Docker writes that line into `/etc/hosts` before the lines of the networks. So the first address of the host name is the node address each time.
- Settings `P3_NODE_IFNAME`, `P3_API_IFNAME` and `P3_HOSTS_ENTRY` can switch both parts off. `run-sim.sh` passes them for a new simulator container. The simulator that runs now reads the program at each call, so it uses the defaults.

The reason for `eth0`. In the one network form the node address is on `eth0`. The first worker of run b-1 had this order by chance and passed the rules 1 to 3.

Why the interface name alone is not enough. With the name fixed, Docker still writes the hosts lines in the order of the connect. Throwaway container 8 had `eth1` first and the hosts lines `172.28.2.248 172.29.2.248 172.28.2.248`. The first line is the added one.

Tests:

| Test | Result |
|---|---|
| `sim/test/wrapper-test.sh` with the fake docker, with `sh`, `dash` and the busybox of the simulator image | 62 ok, 0 FAIL, each |
| `sim/test/sim-chain-test.sh`, the real simulator binary with the fake docker | 29 ok, 0 FAIL |
| Four throwaway containers on the machine with both parts, each with one restart | `eth0` is the node network and the first hosts line is the node address, 8 of 8 looks |
| Four workers from the corrected program (runs b-1 and c-1) | `eth0=172.28.2.N`, `eth1=172.29.2.N`, `/kind/old-ipv4` is `172.28.2.N`, each time. In two of them Docker connected `kata-bb` first |
| A real restart of a worker (reboot try 1) | Docker connected the networks in the other order. The names, `/kind/old-ipv4`, the kubelet flags and the tunnel address stayed. The entry program logged `detected IPv4 address: 172.28.2.13` and `detected old IPv4 address: 172.28.2.13` |

The throwaway containers were not privileged, ran `sleep 30` on the two lab networks with free addresses, and are removed.

## 5. Pass rule 4, workers through the NVKE API

Run b-1, with the two first workers from the old program (`kata-cp1-nw-1014`, `kata-cp1-nw-5779`).

| Step | Call | Time | Result |
|---|---|---|---|
| A worker more | `PATCH /api/nodePools/<ID>` with `{"desiredNodeCount":3}`, HTTP 200 | 23:27:27 | Container made at 23:27:31, Node Ready at 23:28:23, 6 good nodes at the look of 23:28:24. That is 57 s |
| A node delete, count 3 | `DELETE /api/nodes/<ID>` of `kata-cp1-nw-5779`, HTTP 202 | 23:29:15 | The Node is gone after 11 s. The simulator gets its DELETE after 13 s. NVKE makes a new node `kata-cp1-nw-3621` by itself in the same 13 s. 6 good nodes after 68 s |
| The count goes down | `PATCH` with `{"desiredNodeCount":2}`, HTTP 200 | 23:31:21 | No node goes. NVKE lists 6 nodes 120 s later |
| A node delete, count 2 | `DELETE /api/nodes/<ID>` of `kata-cp1-nw-1014`, HTTP 202 | 23:33:45 | The Node is gone after 11 s, the simulator gets its DELETE after 13 s, NVKE lists 5 good nodes after 14 s. No new node one minute later |

So NVKE does the same as with pod workers in phase 2. A lower count removes no node. A node delete removes the node, and NVKE fills the pool again when the count asks for it.

The check after each node delete (`gone-check`), two of two times:

- No Node in the new cluster.
- NVKE does not list the node, and `GET /api/nodes/<ID>` gives 404.
- No Machine and no `NicoMachine`.
- The simulator has no instance with that ID. Its log has one `DELETE .../instance/<ID>` with 200.
- No container with that name in Docker, running or stopped.
- No SPIRE entry of the host.
- The address is free. After the first delete the new worker took the address `172.28.2.12` of the old one, 1 s after the simulator removed the old container.

Traffic with the new workers:

| Look | Nodes | Lines that pass | Name lookup |
|---|---|---|---|
| After the worker more | 3 control plane, 3 workers | 30 of 30 (10 of 10 with the new worker) | 6 of 6 |
| After the refill | 3 control plane, 3 workers | 30 of 30 | 6 of 6 |

The new worker had five tunnel ports, and each other node had a tunnel port to `172.28.2.13`.

After these steps both workers of run b-1 (`kata-cp1-nw-2387`, `kata-cp1-nw-3621`) come from the corrected program.

## 6. Pass rule 5, control plane flows with two workers

The storage loop ran from 23:27:24 to 00:35:15.

### Rollout of the control plane from p10 to p9

`PATCH /api/clusters/<ID>` with the machine template of p9 at 23:36:00, HTTP 200.

- Three new control plane nodes with p9, and 5 good nodes, 695.0 s after the PATCH.
- 701 of 701 calls to the shared address got 200 (23:35:54 to 23:47:55).
- No Node that was Ready left Ready. Both workers stayed Ready.
- No surge node met a full domain. The watch for a pending node has 0 lines with `FailureDomainUnavailable` or `Unschedulable`. The workers hold no volume place, so each host node had one free place for the whole time.
- The kubelet of each worker: 0 lines about the lease, 0 lines about the node status, 0 connection errors to the API server. One line of another kind on one worker, a probe of a container that took more than 5 s.

The gate, node by node. Seconds count from the closed gate.

| Gate closed | Node | Pod not ready | Out of the ready endpoints | Sockets closed | Withdrawal done |
|---|---|---|---|---|---|
| 23:39:08.479 | `5ce6d43e` | 4.5 s | 4.5 s | 4 | 45.7 s |
| 23:42:51.664 | `0564a3d3` | 5.1 s | 5.2 s | 10 | 45.9 s |
| 23:46:08.671 | `c8855665` | 5.0 s | 5.0 s | 6 | 45.8 s |

### Forced certificate renewal

Started as the docs page says, with the operator workflow `RenewK8sCertsV2` (`force: true`) at 23:48:42.

- The workflow completed in 10 min 16 s. Each certificate has a later end date.
- 627 of 627 calls to the shared address got 200 (23:49:01 to 23:59:46).
- No worker left Ready.
- Two control plane nodes were `Unknown` inside their own renewal, for 39 s (`9887183e`) and 77 s (`a631907e`). Phase 2 had the same, 60 s for one node.
- The kubelet of each worker: 0 lines about the lease, 0 lines about the node status, 0 connection errors.

| Gate closed | Node | Pod not ready | Out of the ready endpoints | Sockets closed | Withdrawal done | Gate opened | In the ready endpoints again |
|---|---|---|---|---|---|---|---|
| 23:49:07.144 | `49c3d6f6` | 4.6 s | 4.7 s | 6 | 45.8 s | 110.6 s | 110.9 s |
| 23:51:19.569 | `9887183e` | 5.6 s | 5.6 s | 10 | 45.9 s | 235.9 s | 237.8 s |
| 23:55:26.109 | `a631907e` | 4.4 s | 4.4 s | 8 | 45.9 s | 225.9 s | 227.6 s |

The numbers are the numbers of phase 2. A worker kubelet has its connection to the shared address, and it kept it or made it again with no lease error in both flows.

## 7. The reboot try

NVKE has no reboot call in its REST API. The request is the label `nvke.nvidia.com/reboot` on the Node of the new cluster, as in the worker test of phase 2. NVKE then runs the workflow `RebootNode`.

### Try 1, the controller as it is (soft reboot on)

Worker `kata-cp1-nw-2387`, made by the corrected program. Label at 00:00:44.

| Time | Event |
|---|---|
| 00:00:44.4 | NVKE runs `SoftRebootNode`, then `WaitForNodeReboot`. Labels `reboot-status=InProgress`, `reboot-attempt=1`. NVKE shows `rebooting` |
| 00:01:29 | The Node is `Unknown`. NVKE shows no `nodeAgentReady` and no `kubernetesReady` |
| 00:02:16 | The container ends and Docker starts it again (restart policy `always`, restart count 1). systemd in the container needed 92 s to stop |
| 00:02:27 | The Node is Ready. NVKE shows a good node that is `rebooting` |
| 00:10:48 | End of my watch, 604 s after the label. The workflow is in `WaitForNodeReboot`, attempt 1. NVKE logged `Node has not rebooted yet` 61 times |

- The boot ID is the same before and after (`67bfedd9`), in the container and on the Node. The simulator keeps the boot ID in a file and changes it only at its own reboot call.
- No call reached CAPNICo or the simulator.
- So NVKE cannot see this reboot. With the default setting it waits 30 minutes and then asks the provider. I did not wait for that.
- The pods of the worker: each pod has one restart for each container (coredns 1, node-local-dns 1, the OVN pod 5), and the OVN pod is 5 of 5 again. The test pod (restart policy `Never`) is Failed.
- Traffic after the restart: 20 of 20 lines, name lookup 5 of 5.
- The workflow went on to wait. NVKE cancelled it at the delete of the cluster (section 8).

### Try 2, soft reboot off

One Helm upgrade of the release `nvke-controller` at 00:11:20 added `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` to the list `env` of the chart values (`run/reboot-setting.sh off`, `--reuse-values`). The release went from revision 2 to revision 3. The upgrade took 13 s.

Worker `kata-cp1-nw-3621`, made by the corrected program. Label at 00:12:06.

| Time | Who | Event |
|---|---|---|
| 00:12:06.7 | NVKE | `ApplyCAPIMachineRebootAnnotation`. The Machine gets `nvke.nvidia.com/reboot=2026-11-28T00:12:06Z`. Then `WaitForNodeReboot` |
| 00:12:06 | CAPNICo, simulator | `PATCH .../machine/<machine ID>/power`. The simulator answers 404 |
| 00:12:17 | CAPNICo, simulator | `PATCH .../instance/<instance ID>`, 200. Simulator log `restarted mock instance container`. The container starts again with a new boot ID |
| 00:12:17 | CAPNICo | `NicoMachine` gets `nico.nvidia.com/last-reboot-triggered-timestamp`. `status.reboot` has `path: hard`, `mode: graceful-fallback`, `message: NICo accepted hard reboot fallback` |
| 00:12:20 | Node | Not Ready |
| 00:12:40 | Node | Ready, with the new boot ID `a8497715` (before `32556e57`) |
| 00:13:06.8 | NVKE | `DeleteCAPIMachineRebootAnnotation`. Labels `reboot-status=Completed` and `last-completed-reboot`. The workflow completed, run time 60.6 s |

- The mock has a power route for an instance. It has no route for the power of a machine, so CAPNICo falls back after 11 s.
- The node address is the same. The entry program logged the same address as old and new. The interface names and the kubelet flags are the same.
- Traffic after the reboot: 20 of 20 lines, name lookup 5 of 5.
- No worker was broken by a try, so I removed no worker.

The state I left. The controller has `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` (Helm revision 3). The setting hurt no flow of this run: the delete and the final cluster ran with it. The e2e overlays of NVKE for container nodes set the same value. The way back is `run/reboot-setting.sh on`, or a Helm rollback to revision 2.

## 8. Pass rule 6, delete

`DELETE /api/clusters/<ID>` of run b-1 at 00:16:03. The check ran at 00:17:08.

| Check | Result |
|---|---|
| Cluster row | Gone after 57.8 s. `GET` gives 404. No node row |
| Workflows | `TeardownCluster` completed. 10 `TeardownNode` completed over the life of the run. NVKE cancelled the `RebootNode` workflow of try 1 by itself. 0 workflows run |
| Pods and claims in `d` | None |
| Lab volumes | 12 Available (the storage loop made the six again at 00:16:45) |
| Cluster, Machines | None |
| Objects of the pod provider, in each namespace | None |
| Objects of CAPNICo, in each namespace | None |
| Secrets with the cluster name | None |
| SPIRE entries of hosts | None |
| Instances of the simulator | None. Two `DELETE .../instance/<ID>` with 200, 20 s and 22 s after the DELETE |
| Worker containers in Docker, running or stopped | None |
| Containers on the two lab networks | The four kind nodes, and the simulator on `kata-bb` |
| Docker volumes with no container | 1, an old named volume from before phase 3 |
| Test objects | None. The test pods were in the cluster that is gone |

## 9. The cluster of run c-1

Run c-1, posted at 00:17:31 with two workers. It was the final cluster of the seventh task. I deleted it at 00:55:49 for the test of the simulator fix. The cluster that is up now is run d-1 (section 17).

| Node | Role | Node address | Tunnel address | From |
|---|---|---|---|---|
| kata-cp1-cp-a62c7701 | control plane | 172.28.1.2 | 172.28.1.2 | pod, image p10 |
| kata-cp1-cp-b8493edc | control plane | 172.28.1.3 | 172.28.1.3 | pod, image p10 |
| kata-cp1-cp-edc25a7b | control plane | 172.28.1.1 | 172.28.1.1 | pod, image p10 |
| kata-cp1-nw-6560 | worker | 172.28.2.11 | 172.28.2.11 | mock, corrected program |
| kata-cp1-nw-3078 | worker | 172.28.2.12 | 172.28.2.12 | mock, corrected program |

- 5 good nodes at 00:34:37, 17 min 6 s after the POST. Run b-1 needed 5 min 22 s. The cause is the slow disk of the machine (fault 4).
- Traffic 20 of 20 lines, name lookup 5 of 5, API Service 5 of 5.
- `logs`, `exec` and port forward through each API server: 18 of 18.
- Each worker has `eth0` on the node network, `eth1` on `kata-bb`, the first hosts line and `/kind/old-ipv4` with the node address.
- The request has `etcdEncrypted: false`.
- The test pods `p3-t-1` to `p3-t-5` are in the namespace `default`.
- The each-second call to the shared address had a bad time while the cluster was made. From the first answer at 00:20:44 to 00:34:47, 120 calls got no answer in 2 s or the code 500. In run b-1 that number was 0, and in run d-1 it was 0.
- From 00:34:50, when the three control plane nodes were up, to the stop of the watch at 00:55:48, 1139 of 1156 calls got 200. So the cluster kept losing a call now and then for as long as the disk was slow.
- One `JoinNode` workflow of a control plane node failed at 00:30:48 with `kubeadm join failed: exit status 1`. NVKE ran it again by itself, and that run completed.
- The Ready watch of run c-1 has data only from 00:31:01 (fault 3). It has no range in which a Node that was Ready left Ready.

## 10. Faults and their causes

### Fault 1, the simulated cloud-init loses a race with systemd (mock)

Run a-1. The simulator ran the last cloud-init command, `systemctl restart nke-agent.service` from NVKE, 0.09 s before systemd made its control socket. The status file says `error` for good, and `NodePreflight` of NVKE never passes. `result-AB.md`, section 6, has the times and the code places.

The lab answer is one wait for the control socket of systemd as the first pre-kubeadm command of the pool. The socket was absent at the first look in 3 of the 7 worker starts that have a record (run a-1, run a-2 and the first worker of run b-1). Each join verdict of the sections 1 to 9 holds only with that wait. The fixed simulator then passed eight worker starts with no wait in the request (section 17).

### Fault 2, Docker connects two networks in a random order (lab script)

Section 4. The first form of `docker-two-nets` did not fix the order. Corrected and tested.

### Fault 3, small faults of the lab scripts (lab script)

I corrected each one.

- `run/p3ab.sh`, step `kc`. It took a kubeconfig file that an older run had left. A run folder of phase 2 had the same name, `c-1`. So the Ready watch of the final cluster asked with the wrong certificate and has no data from 00:18:55 to 00:31:01. The step now takes only a file that is newer than the POST. I moved the old file to `kubeconfig-kata-cp1.phase2-run` in the same secrets folder. The each-second call was not hit.
- `run/p3ab.sh`, step `gone-check`. It said FAIL when the refill worker had taken the free address of the deleted worker. It now names the container that holds the address. The check then passed on the same recorded facts.
- `p2-gaps/run.sh`, step `cp-rollout`. Its end rule counted only pods of the pod provider. It now takes the count of NVKE nodes at the start. I changed it before the rollout ran.
- The faults of `result-AB.md`, section 6, fault 2.

### Fault 4, a slow disk of the machine from about 00:14 (lab environment)

- 00:14:23. The three etcd members of run b-1 logged `leader failed to send out heartbeat on time ... likely from slow disk` and applies of up to 938 ms. The API servers logged a `/readyz` call that ended after its time limit. One call to the shared address at 00:14:29 got no answer in 2 s. It is the one failed call of 3983.
- 00:24 to 00:35. The I/O pressure of the machine was 22 to 37 % (`some`, the mean of 60 s). The mean time of a write was 23 to 31 ms on the disk and 47 to 126 ms on the loop devices of the lab volumes. The first API server of run c-1 gave 500 for `/readyz` at times.
- I did not find one process that causes it. The writers were the databases of the lab stack, the etcd of the own cluster of the machine, the three guests and, for a short time, the image import of the two new workers. The rollout and the renewal ran before it and have no failed call. Section 17 has the search for the cause.
- The final cluster needed three times as long, and the shared address failed 120 calls while the cluster was made (section 9). The API server of the first control plane node answered `/readyz` with 500 or late in that time.
- 00:42. The mean time of a write is 11 ms on the disk and 21 ms on the etcd volumes, and the I/O pressure is 11 %. No workflow runs.
- The cluster of run c-1 was healthy by NVKE, by its Nodes and by the traffic checks, and it lost about 1 call in 70 until its delete.

No fault of the image, of CAPNICo or of NVKE came up in this run.

## 11. Findings for the design

1. NVKE takes the mixed request as it is and needs no `NicoCluster`. CAPNICo v0.3.0-rc.1 works under a `PodVMCluster` and sets the provider ID of the Node by itself. No step needed a NICo controller of NVKE.
2. One network is not enough. NVKE still shows a good node when the pod network of a worker is broken.
3. Two networks pass the rules 1 to 6. The node address is the tunnel address on each node.
4. A worker from another provider holds no volume place. So a surge node of a control plane rollout finds a free place on each host node, and the capacity signal of phase 2 does not come into play.
5. The control plane flows do not touch the workers. In a rollout and in a forced renewal each call to the shared address got 200, no worker left Ready, and no worker kubelet logged a lease error. The health gate numbers are the numbers of phase 2.
6. The pool rules of NVKE are the same for these workers as for pod workers. A lower count removes no node, a node delete removes it, and NVKE fills the pool again when the count asks for it. A new worker is a good node in about one minute when the control plane is up.
7. A reboot through NVKE works with the mock only when the soft reboot is off. With the default setting NVKE waits 30 minutes for a new boot ID that a restart in place cannot give. Phase 2 showed the same for a pod worker. The e2e overlays of NVKE set `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` for container nodes.
8. The reboot path of CAPNICo with the mock is the hard path. The first call (the power of the machine) gets 404 from the mock.
9. A worker container must have fixed interface names and a fixed first hosts line. Without both, a restart can move the kubelet to the address of the other network. This is a rule for each lab that gives a kind node image two Docker networks.
10. A delete through the NVKE API removes all, also with a worker that is stuck before the join and with a reboot workflow that waits. NVKE cancels those workflows by itself.
11. The mock race of fault 1 can hit each user of the container backend on a fast machine.

## 12. Facts for the Konnectivity decision

The lab cluster has no Konnectivity. The API servers have `--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname` and no egress selector file. The cluster has 0 pods with `konnectivity` in the name. Each connection below is a direct connection.

The address kinds of the lab:

- Node address of a control plane node. It is on the node network (`172.28.1.x` in the lab).
- Node address of a worker. It is on the same node network (`172.28.2.x`).
- Second address of a worker, on the network of the shared address (`172.29.2.x`). The default route of the worker is there.
- The shared address of the API (`172.29.255.220:6443`), a load balancer address on that second network.
- OVN management port of a node, the address `.2` of its pod subnet.

| Connection | Source | Target | Seen in |
|---|---|---|---|
| API server to the kubelet of a worker (`logs`, `exec`, port forward) | Node address of the control plane node whose API server makes the call | Node address of the worker, port 10250 | `ss` in the worker during an `exec`, runs b-1 and c-1. No address is replaced |
| API server to a pod on a worker (pod proxy and Service proxy) | OVN management port of that control plane node | Pod address on the worker, through the tunnel between the two node addresses | The pod log names the source, 12 of 12 calls in run c-1 |
| Kubelet and OVN of a worker to the API server | Second address of the worker | The shared address | `ss` in the worker, run c-1 |
| Pod on a worker to the API Service | The worker (the Service has the node addresses of the three control plane nodes as endpoints) | Node address of a control plane node, port 6443 | 5 of 5 nodes reach the Service, run c-1 |
| Tunnels between the nodes (Geneve, UDP 6081) | Node address | Node address | Tunnel ports of each node, each run with two networks |
| SPIRE agent of a worker to the SPIRE server | Second address of the worker | A kind host node, node port 30081 | `ss` in the worker, run c-1 |
| NVKE controller to the agent of a worker | Not caught. A connection lives only for one call | Node address of the worker, port 15005 | NVKE shows `nodeAgentReady` |
| Clients inside a control plane node (controller manager, scheduler) | Node address of the node | The same node address, port 6443 | `ss` in the node, run c-1 |

With one network (step A) the first row was different. The kubelet of the worker saw the address of the kind host node, because the host node replaced the source address. The call still worked.

What this means for the decision, as facts only:

- The direct path needs the API servers to reach the node address of each worker on port 10250, and the pod network of each worker through the tunnels.
- In this lab both hold because the control plane nodes and the workers share the node network. No call of the API server went through the shared address or through the second network.
- The lab did not test a worker that the control plane nodes cannot reach on its node address.

## 13. Kernel modules and kernel settings

Modules that are loaded now and were not loaded before phase 3 (16):

| Module | How it came |
|---|---|
| `openvswitch`, with `psample`, `nf_conncount`, `nsh` | `modprobe openvswitch` in the preparation, on the word of Davanum |
| `nfnetlink_cttimeout` | The kernel, 40 s after the start of the worker of run a-2 |
| `geneve` | The kernel, at the first tunnel port of a worker (22:55:15) |
| `nft_fib`, `nft_fib_inet`, `nft_fib_ipv4`, `nft_fib_ipv6`, `nft_nat`, `nft_redir`, `nft_socket`, `nf_socket_ipv4`, `nf_socket_ipv6` | The kernel, at the same look, when the pods of the worker made nftables rules in the network namespace of the worker |
| `tls` | The kernel, 55 s after the join of that worker |

- The runs b-1, c-1 and d-1 added no module. No module of the list before phase 3 is gone.
- I removed no module and loaded none by hand in this task.

The kernel settings look, the same values in six looks (one worker, no worker, two workers, before the delete of run b-1, run c-1, run d-1):

- Not per namespace: `vm.overcommit_memory=1`, `vm.panic_on_oom=0`, `kernel.panic=10`, `kernel.panic_on_oops=1`, `kernel.keys.root_maxkeys=1000000`, `kernel.keys.root_maxbytes=25000000`, `fs.inotify.max_user_watches=1048576`, `fs.inotify.max_user_instances=8192`, `vm.max_map_count=1048576`, `kernel.pid_max=4194304`.
- Root network namespace: `net.ipv4.ip_forward=1`, `net.ipv4.conf.all.rp_filter=2`, `net.ipv4.conf.all.route_localnet=0`, `net.netfilter.nf_conntrack_max=262144`.
- No look exists from before the first worker, so I cannot say if a worker changed one of them. A kubelet sets the first four, and the kind nodes of the lab have a kubelet since phase 1.
- The nft tables and the chain names of the root network namespace are the same in the six looks (9 tables, 42 chains). The root network namespace has no Geneve interface and no Open vSwitch interface.
- Docker adds one rule to its raw table for each container address on `kata-bb` and removes it with the container.

## 14. What changed on the machine, and how to remove it

| Change | How to remove it |
|---|---|
| Eight old pod image archives removed (15.5 GB) | Not to restore. The image build can make each one again |
| Kernel modules of section 13 | They go at the next start of the machine. `modprobe -r` removes one that has no user |
| Helm release `nvke-controller`, revision 3, with `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` | `run/reboot-setting.sh on`, or `p2-gaps/install-stack.sh rollback 2` |
| The simulator container `p3-nico-sim`, step B form, with the fixed binary (sha256 `d375230039965f5ec747f96bf8ff69ccb65b9a89f2ce068287c201a38150db43`) and the corrected `docker-two-nets`. The binary of before is `sim/nico-sim.before-fix`, with `SHA256SUMS.before-fix` | `sim/run-sim.sh remove`, after the workers are gone |
| Cluster `kata-cp1` of run d-1, three pods in `d`, six volumes, two privileged worker containers | `DELETE /api/clusters/<ID>` through the NVKE API, then `p2-provider/storage.sh reset` |
| The each-second call and the Ready watch of run d-1 | `run/p3ab.sh stop-watches d-1`. They end by themselves 8 hours after their start |
| Lab scripts under `/root/kata-cp`, in `p3/run`, `p3/sim`, `p3/requests`, `p3/env-p3.sh` and `p2-gaps/run.sh` | The notes have each file |
| Logs in `/root/kata-cp/logs/p3` and files in `/root/kata-cp/secrets/d-a-1`, `d-a-2`, `d-b-1`, `d-c-1`, `d-d-1` | Remove the folders. `d-c-1` also has files of phase 2 |

Gone again:

- The storage loop. It ran from 23:27:24 to 00:35:15.
- Eight throwaway containers `p3-ifname-check-1` to `-8`.
- The clusters of the runs a-1, a-2, b-1 and c-1, with eight worker containers, and six more worker containers of the refills of run d-1.

Disk:

| Look | In use | Free |
|---|---|---|
| Before the removal of the archives | 225 GiB | 76 GiB |
| After the removal | 211 GiB | 90 GiB |
| Final cluster up | 218 GiB | 83 GiB |

221 GB of memory are available. The machine has no swap. No firewall command, no Docker setting, no package and no module load came from me.

## 15. What is not tested

- A join with the request of the preparation, after run a-1.
- The fix of the simulator on a machine where systemd needs longer, and its limit of 60 s.
- The 30 minute path of the default reboot setting to its end. I stopped the watch after 10 minutes.
- A reboot of a control plane node. NVKE does not allow it.
- A second restart of the same worker, and a restart of the machine.
- A rollout of the control plane while a worker joins or goes.
- The encryption of etcd with workers (the requests have `etcdEncrypted: false`).
- The health gate with a worker under load, and long-lived clients on a worker.
- A worker that the control plane nodes cannot reach on its node address, and Konnectivity itself.
- The cause of the modules `nfnetlink_cttimeout` and `tls`. The cause of the slow disk is not found (section 17).
- The virtual machine form of the mock, a real NICo, a TPM, a Mellanox device.
- The removal of the kernel modules.
- More than three workers, and two clusters at one time.

## 16. Files

Scripts in this folder:

| File | Content |
|---|---|
| `run/p3ab.sh` | The lab driver of phase 3 |
| `run/reboot-setting.sh` | The soft reboot setting of the lab controller through Helm |
| `run/after-delete.sh`, `run/hostfacts.sh`, `run/io-look.sh`, `run/disk-history.sh`, `run/io-sampler.sh`, `run/ifname-check.sh` | Read-only looks, and the throwaway container check |
| `run/refill-loop.sh` | The worker refills of the simulator fix test |
| `run/p2-gaps-run.sh` | The phase 2 script with the changed end rule of `cp-rollout` |
| `sim/docker-two-nets`, `sim/run-sim.sh`, `sim/test/` | The corrected program, its tests and `result-2026-11-28.txt` |
| `requests/` | The request templates with the wait for systemd |

Logs on the workstation are in `/scratch/kata-cp/logs/bigbox/remote-logs/p3/`.

| File | Content |
|---|---|
| `prep7/ifname-check.txt` | The check of the interface name option on the machine |
| `b-1/timeline.txt` | One line for each change of the state, with each API call of pass rule 4 |
| `b-1/gone-del-5779.txt`, `b-1/gone-del-1014.txt` | What is left of a deleted worker |
| `b-1/traffic-scale-3.txt`, `b-1/traffic-refill.txt` | Traffic with a new worker |
| `b-1/cp-rollout-r1.out`, `b-1/gate-report-rollout-r1.txt` | The rollout |
| `b-1/t1-renew.out`, `b-1/g1-renew.txt`, `b-1/gate-report-renew.txt` | The forced renewal |
| `b-1/kubelet-errors-rollout-r1.txt`, `b-1/kubelet-errors-renew.txt` | The kubelet of each worker in both flows |
| `b-1/reboot-soft.txt`, `b-1/reboot-hard.txt`, `b-1/reboot-facts-*.txt` | The two reboot tries |
| `b-1/reboot-setting-off.txt` | The Helm upgrade |
| `b-1/probe-b-1-summary.txt`, `b-1/probe-one-miss.txt` | The each-second call of the whole run, and the one failed call |
| `b-1/delete.out`, `b-1/after-delete.txt` | Pass rule 6 |
| `c-1/konn-final.txt`, `c-1/rule3-final.txt`, `c-1/tunnels-final.txt` | The connections of the direct path |
| `c-1/modules-final.txt`, `c-1/hostfacts-final.txt` | Kernel modules and kernel settings with run c-1 up |
| `d-1/starts.txt`, `d-1/refill-loop.out`, `d-1/gone-refill-*.txt` | The eight worker starts of the simulator fix test |
| `d-1/cluster-request-nowait.json`, `d-1/cluster-request.json`, `d-1/posted-request.txt` | The posted request with no wait, the request with the wait, and the name of the posted file |
| `d-1/disk-history-before.txt`, `d-1/disk-history-after.txt`, `d-1/io-pressure.txt`, `d-1/disk-*.txt` | The disk history of the machine and the looks |
| `d-1/traffic-final.txt`, `d-1/rule3-final.txt`, `d-1/modules-final.txt`, `d-1/hostfacts-final.txt` | The checks at the end |

## 17. The lab run of the simulator fix

### Verdict

PASS. Eight worker starts with the fixed simulator and with no wait for systemd in the request. Each start joins at the first attempt, the status of the simulated cloud-init is `done`, and no `NodePreflight` fails on `check_cloud_init_status`.

### What ran

- The simulator binary with the fix, sha256 `d375230039965f5ec747f96bf8ff69ccb65b9a89f2ce068287c201a38150db43`. The checksum is the same on the workstation, in the lab folder and inside the container (`sha256sum /sim/nico-sim`). `SHA256SUMS` of the lab folder has the new line for the binary and the old line for the seed file. The binary of before is beside it as `nico-sim.before-fix`.
- The simulator container, started again at 00:58 in the step B form, with the corrected `docker-two-nets`.
- The posted file is `d-1/cluster-request-nowait.json`. It is the mixed request with two workers. Its pool commands are `mkdir -p /run/cluster-api` and `echo success > /run/cluster-api/bootstrap-success.complete`, the two commands of the preparation and of the e2e request of NVKE. The request with the wait is beside it as `d-1/cluster-request.json`, and it was not posted. The templates in `requests/` keep the wait. The driver makes the file with no wait from the rendered request (`REQUEST_FORM=nowait run/p3ab.sh post d-1 2`).
- POST at 00:59:06, HTTP 201. 5 good nodes at 01:04:42, 5 min 36 s after the POST.
- Six refills from 01:05:25 to 01:12:39 (`run/refill-loop.sh`). Each time the loop deleted the oldest worker with `DELETE /api/nodes/<ID>` while the pool count was 2, and NVKE made a new worker by itself. Each new worker was a good node 68 s after the DELETE. The check of what is left of the old worker passed 6 of 6 times.

### The worker starts

Times after the plus sign count from the start of the container.

| Worker | Container start | Runner written | Control socket of systemd | Line of the simulator | First command | Status | `KubeadmJoin` |
|---|---|---|---|---|---|---|---|
| kata-cp1-nw-8304 | 00:59:14.614 | +0.609 s | +0.751 s | `checks=2 waited=165ms` | +0.805 s | done | attempt 1 |
| kata-cp1-nw-9034 | 00:59:16.364 | +0.669 s | +0.453 s | `checks=1 waited=43ms` | +0.757 s | done | attempt 1 |
| kata-cp1-nw-6559 | 01:05:32.726 | +0.685 s | +0.487 s | `checks=1 waited=50ms` | +0.768 s | done | attempt 1 |
| kata-cp1-nw-6677 | 01:06:45.316 | +0.672 s | +0.784 s | `checks=2 waited=165ms` | +0.870 s | done | attempt 1 |
| kata-cp1-nw-2481 | 01:08:01.223 | +0.695 s | +0.452 s | `checks=1 waited=49ms` | +0.792 s | done | attempt 1 |
| kata-cp1-nw-5150 | 01:09:13.272 | +0.685 s | +0.463 s | `checks=1 waited=33ms` | +0.749 s | done | attempt 1 |
| kata-cp1-nw-8550 | 01:10:30.024 | +0.666 s | +0.529 s | `checks=1 waited=30ms` | +0.737 s | done | attempt 1 |
| kata-cp1-nw-8052 | 01:11:40.237 | +0.703 s | +0.457 s | `checks=1 waited=31ms` | +0.766 s | done | attempt 1 |

- The full line of the simulator is `INF systemd is ready for cloud-init commands component=nico-containers container_id=<ID> checks=<n> waited=<time>`. The log has 8 such lines and no error line.
- "First command" is the time of the output file of the runner. The runner makes that file right before its first command. The file is empty in each start, and each runner has three commands.
- The time from the container start to the first command is 0.737 to 0.870 s.
- In two of the eight starts (`8304` and `6677`) systemd made its control socket after the simulator had written the runner, at +0.751 s and +0.784 s. The simulator made two checks, waited 165 ms, and ran the commands after the socket. With the old simulator these two starts had the conditions of the fault of run a-1.
- In the six other starts the socket was there before the runner was written. The simulator made one check of 30 to 50 ms.
- `NodePreflight` is at attempt 2 in the workflow of each worker. The first attempt failed with `failed to get agent version ... dial tcp <node address>:15005: connect: connection refused`. That is the call before the agent listens, and run a-1 had the same line. The NVKE controller log has 0 lines with `check_cloud_init_status` since the POST.
- The agent journal has the line `mlx5 rescan is disabled` in each of the eight workers.

### The other checks of run d-1

| Check | Result |
|---|---|
| The each-second call to the shared address | 63 calls with no answer before the first API server, then 784 of 784 calls with 200 (01:01:18 to 01:14:45) |
| The Ready watch | No range. The six deleted workers show as gone |
| Pod traffic | 20 of 20 lines, name lookup 5 of 5 nodes, API Service 5 of 5 nodes |
| Pass rule 3 | 18 of 18 checks |
| The two workers at the end | `eth0` on the node network, `/kind/old-ipv4` with the node address, no failed unit |

Seen beside the test. One `JoinNode` workflow of a control plane node failed 1.8 s after its start, at 01:03:01, with `failed to get etcd mirror Pod for node kata-cp1-cp-c5d1a913: pods "etcd-kata-cp1-cp-c5d1a913" not found`. NVKE ran the workflow again by itself and that run completed. Run c-1 had one failed `JoinNode` too, with another text. The runs a-2 and b-1 had none. It is in the control plane join of NVKE, not in the worker path. I did not look for its cause.

### The cluster that is up

Run d-1. Three control plane nodes as pods on p10, and two workers, `kata-cp1-nw-8550` at `172.28.2.11` and `kata-cp1-nw-8052` at `172.28.2.12`. It runs from the request with no wait for systemd and with the fixed simulator. The controller is at Helm revision 3. The each-second call and the Ready watch of run d-1 run, and they end by themselves 8 hours after their start.

### The disk

The machine keeps a history of its disk (sysstat, one line for each 10 minutes). The disk is a virtual disk.

| Window, end (UTC) | What ran | Requests each second | MB written each second | Time for a request | Busy | I/O pressure |
|---|---|---|---|---|---|---|
| 21:00 | Before phase 3 started | 132 | 0.5 | 0.5 ms | 5 % | 0.1 % |
| 23:10 | Run b-1 was made | 272 | 23.0 | 3.6 ms | 12 % | 0.6 % |
| 23:50 | Rollout | 264 | 8.5 | 3.3 ms | 20 % | 2.3 % |
| 00:00 | Renewal | 156 | 0.6 | 2.3 ms | 18 % | 2.7 % |
| 00:10 | Reboot try 1 | 150 | 1.8 | 3.9 ms | 21 % | 6.2 % |
| 00:20 | Reboot try 2, delete, start of run c-1 | 192 | 12.6 | 7.3 ms | 23 % | 4.4 % |
| 00:30 | Run c-1 was made | 140 | 10.1 | 21.6 ms | 56 % | 23.9 % |
| 00:40 | Run c-1 idle | 153 | 3.1 | 12.9 ms | 45 % | 19.0 % |
| 00:50 | Run c-1 idle | 131 | 0.5 | 5.5 ms | 27 % | 8.1 % |
| 01:00 | Delete of run c-1, start of run d-1 | 140 | 7.2 | 6.0 ms | 24 % | 7.3 % |
| 01:10 | Run d-1 was made, the refills | 340 | 35.3 | 5.6 ms | 21 % | 2.6 % |

Looks of 10 s:

| Look | Writes each second on the disk | Time for a write on the disk | Writes each second on one etcd volume | Time for a write on an etcd volume | I/O pressure |
|---|---|---|---|---|---|
| 00:45, run c-1 idle | 134 | 7 ms | 31 | 11 to 12 ms | 8 % |
| 00:58, no tenant cluster | 59 | 2 ms | none | none | 0.01 % |
| 01:15, run d-1 idle | 162 | 1 ms | 28 to 29 | 2 ms | 0.3 % |

The disk before and during the test:

- I did not start the test at 00:52. The I/O pressure was 9 to 16 % then, with run c-1 idle.
- After the delete of run c-1 the pressure fell under 1 % within one minute. I started the test on that state.
- From the POST to the end of the refills the pressure (mean of 10 s, 82 looks) was 1.8 % in the mean and 9.5 % at the most. At the eight worker starts it was 0.0 to 4.9 %.

The search for the cause of the slow time, about 10 minutes:

- The lab did not write more. In the worst window the disk had fewer requests and less data than when run b-1 was made, and each request took six times as long. With run c-1 idle and with run d-1 idle the write rate is the same, and a write took 5 to 7 times as long in the time of run c-1.
- Not the storage loop. For a released volume it runs `wipefs -a`, which writes a few blocks. It ran from 23:27 to 00:35, also through the rollout with 701 of 701 good calls.
- Not the journal of the machine. It has 4816 lines in 30 minutes of the slow time and 3599 lines in 30 minutes of the good time, 159 MB in all.
- Not a job of the machine. The hourly cron job ran at 00:17, and `apt-daily` ran for 31 s at 00:33.
- Not one heavy process. PostgreSQL of the lab stack and the etcd of the own cluster of the machine write at the same rate now, in the good time. No workflow ran in the idle time of run c-1.
- Docker. The removal of a worker removes a volume of 2.6 GB with 26582 files. The kernel logged one line at 00:16:25, `xfs_reclaim_worker [xfs] hogged CPU for >10000us 11 times`, 2 s after the simulator removed two workers. That is one line, and the same removal ran six times in the refills with no slow time.
- What I cannot rule out: the disk below the machine, and something inside run c-1 that I did not see. The pressure fell at the delete of run c-1.

I found no cause.

