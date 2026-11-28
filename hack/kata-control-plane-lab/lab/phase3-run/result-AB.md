# Phase 3, steps A and B, result

Date of the run is 2026-11-27. All times are UTC, from `date -u` on the second machine.

This note has the result of step A (one network) and of step B (two networks) of the phase 3 design, with the pass rules 1 to 3. The pass rules 4 to 6 and the reboot try are not part of this run.

## 1. Verdict

### Deductions of step A

| Deduction | Verdict | Evidence |
|---|---|---|
| NVKE accepts the mixed request | Yes | `POST /api/clusters` gave HTTP 201 in three runs (a-1, a-2, b-1). The workflows `ProvisionCluster` and `ProvisionNodePool` completed |
| A later step asks for a `NicoCluster` or fails on the kind | No | The NVKE controller log has 0 lines with `NicoCluster` in each run. The Cluster object has `infrastructureRef` kind `PodVMCluster`. No `NicoCluster` object exists |
| CAPNICo v0.3.0-rc.1 makes an instance for a `NicoMachine` with `siteID` under a `PodVMCluster` | Yes | CAPNICo log line `creating NICo instance` 4 to 6 s after the POST. `NicoMachine` has `ready true`, `instanceID`, `siteName "NICo Containers Site"`. The CAPNICo log has 0 lines of level error |
| The simulator starts the worker container | Yes | The simulator answers `POST .../instance` with 200. The container runs 7 s after the POST |
| The agent gets its identity with the join token | Yes | SPIRE agent journal line `Creating X509-SVID ... spiffe_id="spiffe://kata-cp.nvke.local/host/<node ID>"`, 9 s after the container start |
| The controller reaches port 15005 of the worker | Yes | NVKE shows `nodeAgentReady` for the worker, at `172.29.0.6` in step A and at `172.28.2.11` and `172.28.2.12` in step B |
| `kubeadm join` passes | Yes in run a-2 and in run b-1. No in run a-1 | In run a-1 the worker never came to the join. The cause is a race in the simulator (fault 1). After a change of the lab request the join passed each time |
| The Node gets its provider ID with the NICo controllers of NVKE off | Yes | CAPNICo log line `set workload cluster Node providerID nico://<instance ID>`. The field manager of `spec.providerID` on the Node is `manager` (CAPNICo), 7 s after the join |
| What NVKE shows for the worker | A good node | `joined`, `kubernetesReady`, `nodeAgentReady`, `provisioned`, `provisioningClaimed`, `readyToJoin`. The pool shows `provisioned` |
| The agent runs with the mlx5 rescan off | Yes, on each of the four workers | Process `/usr/local/bin/nvke-agent --secure-server-port 15005 --disable-mlx5-rescan`. Journal line `"msg":"mlx5 rescan is disabled"`. The start settings show `"MLX5Rescan":false` |
| Pod traffic between the worker and the control plane nodes fails with one network | Yes, it fails | 0 of 6 lines pass. Section 3 has the numbers |

### Pass rules of step B

| Pass rule | Verdict | Evidence |
|---|---|---|
| 1. Provisioned, three Ready control plane nodes as pods, two Ready workers from the mock | PASS | NVKE reports 5 good nodes 5 min 22 s after the POST. The cluster and the pool show `provisioned`. Each Node is Ready |
| 2. Pod traffic in each direction and name lookup | PASS | 20 of 20 lines pass (ping 3 of 3, pod TCP 200, Service 200). Name lookup 5 of 5 nodes. API Service 5 of 5 nodes |
| 3. `logs`, `exec` and port forward to a pod on each worker, through each API server | PASS | 18 of 18 checks pass (2 workers, 3 API servers, 3 calls) |
| The each-second call to the shared address | No failed call after the first answer | 629 of 629 calls with 200 from 23:06:43 to 23:17:25, the last look. Before that, 61 calls with no answer while no API server existed. The call still runs |
| The Ready watch | No range | No Node that was Ready left Ready, up to the last look at 23:17:25. The watch still runs |

## 2. Runs and times

| Run | Form | Request | POST | Result |
|---|---|---|---|---|
| a-1 | Step A, one network | The request of the preparation, one worker | 22:35:21 | 3 good control plane nodes at 22:40:38 (5 min 17 s). The worker stays before the join (fault 1). Deleted at 22:48:10 |
| a-2 | Step A, one network | The request with a wait for systemd as the first pool command, one worker | 22:51:23 | 4 good nodes at 22:56:32 (5 min 9 s). Deleted at 23:03:03 |
| b-1 | Step B, two networks | The same request with two workers | 23:04:35 | 5 good nodes at 23:09:58 (5 min 22 s). The cluster is up |

Times of one worker in run a-2:

- 22:51:23 POST.
- 22:51:28 the simulator makes the instance and the container.
- 22:54:53 the agent runs `kubeadm join --config /tmp/kubeadm-join-config.yaml`.
- 22:55:00 CAPNICo sets the provider ID on the Node.
- 22:55:13 the Node is Ready.

Times of the delete through the NVKE API (first look at pass rule 6):

| Run | State of the worker | Cluster row gone | Simulator | Left on the machine |
|---|---|---|---|---|
| a-1 | Not joined, its provision workflow runs | 57.6 s | `DELETE .../instance` 200, 22 s after the DELETE | No worker container, no instance, no object. NVKE cancelled the provision workflow of the worker by itself |
| a-2 | Joined and Ready | 46.2 s | `DELETE .../instance` 200, 19 s after the DELETE | No worker container, no instance, no object, no Secret with the cluster name, no running workflow |

The each-second call in step A:

| Run | No answer before the first API server | Answer 200 |
|---|---|---|
| a-1 | 62 calls, 22:35:21 to 22:37:29 | 654 of 654 calls, 22:37:32 to 22:48:41 (the delete) |
| a-2 | 62 calls, 22:51:23 to 22:53:27 | 539 of 539 calls, 22:53:30 to 23:02:41 (the stop of the watch) |

## 3. Step A, one network

The worker container has one network, `kata-bb`. Docker gave it `172.29.0.6`. The control plane nodes have `172.28.1.1` to `172.28.1.3` on `kata-bb-node`, which is an internal Docker network.

What the worker reaches:

- `https://172.29.255.220:6443/readyz` (the shared address) answers 200 in 9 ms.
- `https://172.28.1.1:6443`, `.2` and `.3` give no answer in 4 s.

Node address and tunnel address in run a-2:

| Node | Role | Node address | Tunnel address | Tunnel ports to |
|---|---|---|---|---|
| kata-cp1-cp-626085e9 | control plane | 172.28.1.2 | 172.28.1.2 | 172.28.1.1, 172.28.1.3, 172.29.0.6 |
| kata-cp1-cp-a67890f9 | control plane | 172.28.1.1 | 172.28.1.1 | 172.28.1.2, 172.28.1.3, 172.29.0.6 |
| kata-cp1-cp-cdec700d | control plane | 172.28.1.3 | 172.28.1.3 | 172.28.1.1, 172.28.1.2, 172.29.0.6 |
| kata-cp1-nw-2209 | worker | 172.29.0.6 | 172.29.0.6 | 172.28.1.1, 172.28.1.2, 172.28.1.3 |

OVN makes the tunnel ports in each direction. No packet passes, because no route exists between `172.29.0.6` and `172.28.1.x`.

The traffic matrix in run a-2:

| Direction | Lines that pass |
|---|---|
| control plane to control plane | 6 of 6 |
| control plane to worker | 0 of 3 (ping no answer, pod TCP no answer in 3 s, Service no answer in 3 s) |
| worker to control plane | 0 of 3 |

More facts of step A:

- The test pod on the worker does not reach the API Service (`10.112.0.1:443`, no answer in 5 s). Its name lookup ends after 12 s with no answer.
- The OVN pod on the worker shows 4 of 5 containers ready.
- The Node of the worker is Ready, and NVKE shows a good node. So NVKE does not see that the pod network of this worker is broken.
- `logs`, `exec` and a port forward to the pod on the worker pass through each of the three API servers. The API server calls the kubelet at `172.29.0.6`, through the default route of the control plane pod.
- The kubelet of the worker sees these calls from `172.29.0.2`, `172.29.0.4` and `172.29.0.5`. These are the addresses of the kind host nodes. The host node replaces the source address.

## 4. Step B, two networks

The simulator runs in the step B form. Its Docker program `docker-two-nets` gives each worker `kata-bb-node` with a fixed address and `kata-bb` with the same last number. The log of that program:

```
2026-11-27T23:04:40Z create name=[kata-cp1-nw-1014-31aa7f12] kata-bb-node=172.28.2.11 kata-bb=172.29.2.11 exit=0
2026-11-27T23:04:42Z create name=[kata-cp1-nw-5779-cc4fc8e2] kata-bb-node=172.28.2.12 kata-bb=172.29.2.12 exit=0
```

What step B must show first (runbook, section 9):

| Point | Result |
|---|---|
| The container has `172.28.2.N` on `kata-bb-node` and `172.29.2.N` on `kata-bb` | Yes, for N 11 and 12 |
| The default route is the gateway of `kata-bb`, and the network unit is active | Yes. `default via 172.29.0.1`. `nke-container-network`, `ovs-vswitchd`, `spire-agent`, `nvke-agent`, `kubelet` and `containerd` are active. No failed unit |
| NVKE, the kubelet and the Node have the node address | Yes. NVKE shows `172.28.2.11` and `172.28.2.12`. The kubelet has `--node-ip=172.28.2.11` and `--node-ip=172.28.2.12`. The Node has the same InternalIP |
| The tunnels use the `172.28.x` addresses | Yes, on each of the five nodes |

Node address and tunnel address (pass rule 2):

| Node | Role | Node address | Tunnel address | Pod subnet | Provider ID |
|---|---|---|---|---|---|
| kata-cp1-cp-0564a3d3 | control plane | 172.28.1.3 | 172.28.1.3 | 10.113.0.0/24 | podvm://d/kata-cp1-cp-0564a3d3 |
| kata-cp1-cp-5ce6d43e | control plane | 172.28.1.1 | 172.28.1.1 | 10.113.3.0/24 | podvm://d/kata-cp1-cp-5ce6d43e |
| kata-cp1-cp-c8855665 | control plane | 172.28.1.2 | 172.28.1.2 | 10.113.4.0/24 | podvm://d/kata-cp1-cp-c8855665 |
| kata-cp1-nw-1014 | worker | 172.28.2.11 | 172.28.2.11 | 10.113.2.0/24 | nico://31aa7f12-ebc6-455e-8a94-5bd41581649c |
| kata-cp1-nw-5779 | worker | 172.28.2.12 | 172.28.2.12 | 10.113.1.0/24 | nico://cc4fc8e2-1d14-4775-a8df-d4fd9284ec4f |

Each node has four tunnel ports, one to each other node.

The traffic matrix (pass rule 2):

| Direction | Lines that pass | Pod TCP time |
|---|---|---|
| control plane to control plane | 6 of 6 | 3.6 to 6.3 ms |
| control plane to worker | 6 of 6 | 3.3 to 7.0 ms |
| worker to control plane | 6 of 6 | 3.0 to 3.5 ms |
| worker to worker | 2 of 2 | 2.9 to 3.1 ms |

- The first ping answer comes in 1.8 to 4.9 ms. Each later one comes in 0.13 to 0.72 ms, in each direction.
- The name lookup of `kubernetes.default.svc.cluster.local` gives `10.112.0.1` from the test pod of each of the five nodes.
- The API Service answers 200 from the test pod of each of the five nodes.
- Each pod of the cluster is Running and ready. The OVN pod on each worker shows 5 of 5.
- A call through a tunnel with a worker takes the same time as a call between two control plane nodes.

Pass rule 3, for the test pod on each worker, through `https://172.28.1.3:6443`, `https://172.28.1.1:6443` and `https://172.28.1.2:6443`, one at a time:

| Call | Result |
|---|---|
| `kubectl logs` | 6 of 6. The line of the pod comes back |
| `kubectl exec` | 6 of 6. The answer is `exec in p3-t-4` or `exec in p3-t-5` |
| `kubectl port-forward` to port 8080 of the pod | 6 of 6. HTTP 200 in 4 to 5 ms |

Source address for the Konnectivity note. During an `exec` call the kubelet of the worker has connections on port 10250 from `172.28.1.3`, then also from `172.28.1.1`, then also from `172.28.1.2`. So the kubelet sees the node address of the control plane node whose API server makes the call. No address is replaced on the way. The API servers have `--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname`.

## 5. Kernel modules that the kernel loaded by itself

No module was loaded by hand. The list is the difference to the module list of the preparation. The watch looks each 10 s, so a time is the first look that has the module.

| Module | First seen | What happened then |
|---|---|---|
| `nfnetlink_cttimeout` | 22:52:08, run a-2 | 40 s after the start of the worker container. Not seen in run a-1, where the worker ran for 13 minutes and did not join |
| `geneve` | 22:55:15, run a-2 | 22 s after `kubeadm join` of the worker. OVN made the first tunnel port on the machine kernel |
| `nft_fib`, `nft_fib_inet`, `nft_fib_ipv4`, `nft_fib_ipv6`, `nft_nat`, `nft_redir`, `nft_socket`, `nf_socket_ipv4`, `nf_socket_ipv6` | 22:55:15, run a-2 | The same look. The pods of the worker made nftables rules in the network namespace of the worker |
| `tls` | 22:55:48, run a-2 | 55 s after the join |

- `ip6_udp_tunnel` and `udp_tunnel` were loaded before. `geneve` now uses them.
- The modules stay loaded after the delete of the cluster. Run b-1 added no module.
- No module of the preparation list is gone.

## 6. Faults and their causes

### Fault 1, the simulated cloud-init loses a race with systemd (mock)

In run a-1 the worker did not join. The workflow `ProvisionNode` of the worker stayed in the activity `NodePreflight`, attempt 7 after 8 minutes, with no limit of attempts. The error text:

```
node preflight status "error": check_cloud_init_status: cloud-init error status: status: error
extended_status: error
boot_status_code: enabled-by-generator
detail: nico-containers cloud-init shim; no stage detail is simulated
```

The cause, from the files of the worker:

| Time | Event |
|---|---|
| 22:35:28.687 | Docker starts the container |
| 22:35:29.261 | The simulator writes `/var/lib/nico-containers/cloud-init/runcmd.sh` |
| 22:35:29.321 | The last command `systemctl restart nke-agent.service` fails. `output.log` has `Failed to connect to system scope bus via local transport: No such file or directory` |
| 22:35:29.322 | The script writes `error` into the status file |
| 22:35:29.414 | systemd makes its control socket `/run/systemd/private` |
| 22:35:37 | systemd starts the agent. It gets its identity and answers on port 15005 |

The command ran 0.09 s before systemd was up. Nothing runs the commands again, so the status file says `error` for good, and the agent reports that to NVKE at each preflight.

Where this is in the code (line numbers of the NVKE main branch of this day):

- The simulator starts the commands right after `docker start`, with `docker exec --detach` and with no wait for systemd (`controller/nico-sim/internal/container/service.go:291-299`, `docker.go:136-198`).
- NVKE adds `systemctl restart nke-agent.service` as the last command of the bootstrap data (`controller/internal/clients/capi/bootstrap_userdata.go:150-151`).
- The lab request had the same two pool commands as the e2e tests of NVKE for container nodes (`controller/test/e2e/internal/nvke/request.go:178-202`). So the e2e tests have the same race. I did not measure why they pass.

What I did. I did not change the simulator and wrote no file into the worker. I changed the lab request. The first pre-kubeadm command of the pool now waits for the control socket of systemd, for at most 120 s, and prints how long it waited:

```
n=0; until [ -S /run/systemd/private ] || [ $n -ge 600 ]; do n=$((n+1)); sleep 0.2; done; echo "lab wait for systemd: $n steps of 0.2 s"; [ -S /run/systemd/private ]
```

The files are `requests/cluster-request.json.tmpl` and `requests/pool-request.json.tmpl`. The command goes through the NVKE API as `preKubeadmCommands`, as each other pool command.

The wait in the three workers after the change:

| Worker | Output of the wait | Status file |
|---|---|---|
| a-2, kata-cp1-nw-2209 | `1 steps of 0.2 s` | done |
| b-1, kata-cp1-nw-1014 | `1 steps of 0.2 s` | done |
| b-1, kata-cp1-nw-5779 | `0 steps of 0.2 s` | done |

So the socket was absent in three of four worker starts on this machine.

This fault is a fault of the mock. A real NICo node runs the real cloud-init after the boot, so the race does not exist there. Each pass verdict for a join in this note holds only with the wait in the request.

### Fault 2, small faults of the lab scripts (lab script)

All are in `run/p3ab.sh`, which I wrote for this run. I corrected each one.

- The driver was copied without the execute bit.
- The module comparison used two sort orders. It now sets `LC_ALL=C`.
- The first `logs` check of step A read an empty pod log and said FAIL. The pod had no log line yet. The step now makes one call to the pod first. The run of step B has the corrected check.
- The reach measure of run a-1 used `ping` and `nc`, which the images do not have. I do not use those lines. The numbers of section 3 come from `curl` and from the test pods.
- The timeline shows `not-ready` for each `PodVMMachine`. The lab script reads a field that the kind does not have. No verdict uses it.
- A `local` line used a variable before its value was set.

No fault of the image, of CAPNICo or of NVKE came up in this run.

## 7. Findings for the design

1. NVKE takes the mixed request as it is. It makes the Machine and the `NicoMachine` of a worker by itself. It makes no `MachineDeployment`, no `NicoMachineTemplate` object and no `NicoCluster`. The kinds in `nvke-system` for run b-1 are 1 Cluster, 5 Machines, 1 `PodVMCluster`, 3 `PodVMMachine` and 2 `NicoMachine`.
2. CAPNICo v0.3.0-rc.1 needs no `NicoCluster`. The `NicoMachine` has an owner reference to its Machine, the label of the cluster name, and `siteID` in its spec. CAPNICo sets the provider ID on the Node of the tenant cluster by itself. The NICo controllers of NVKE were off in each run, and no step needed one of them.
3. One network is not enough, as the design said. Section 3 has the numbers. NVKE still shows a good node in that state.
4. Two networks pass the rules 1 to 3. The node address is the tunnel address on each node.
5. Docker does not give the two interfaces a fixed order. In run b-1 the first worker has the node network on `eth0` and `kata-bb` on `eth1`. The second worker has them the other way. The file `/kind/old-ipv4` holds `172.28.2.11` in the first worker and `172.29.2.12` in the second one. The entry program of the kind node image uses that file at a restart of the container. This matters for the reboot try. Docker 29.1.3 is on the machine. If its option for a fixed interface name of a network endpoint works here, `docker-two-nets` can set the order. I did not try that.
6. With two networks the kubelet of a worker sees the real node address of the control plane node. With one network it sees the address of the kind host node.
7. A delete through the NVKE API removes a worker that is stuck before the join. NVKE cancels the provision workflow of that worker by itself.
8. The mock race of fault 1 can hit each user of the container backend on a fast machine.

## 8. What changed on the machine, and how to remove it

| Change | How to remove it |
|---|---|
| Eight old pod image archives removed from `/root/kata-cp/dl/img` (p2, p3, p4, p5, p5-k1355, p6, p7, p8-nogate, 15.5 GB) | Not to restore. The image build can make each one again |
| Kernel modules loaded by the kernel (section 5) | They go at the next start of the machine. `modprobe -r` removes one that has no user. I did not remove one |
| The simulator container `p3-nico-sim` is now in the step B form | `sim/run-sim.sh remove`, after the workers are gone |
| Two privileged worker containers, `kata-cp1-nw-1014-31aa7f12` and `kata-cp1-nw-5779-cc4fc8e2` | `DELETE /api/clusters/<ID>` through the NVKE API. The simulator removes them |
| Cluster `kata-cp1` of run b-1, with three pods in `d` and six volumes | The same DELETE, then `p2-provider/storage.sh reset` |
| Test pods `p3-t-1` to `p3-t-5`, their Services and the ConfigMap `p3-probe` in the namespace `default` of the new cluster | They go with the cluster |
| The each-second call (a unit in the kind node) and the Ready watch (a process on the machine) of run b-1. Both end by themselves 8 hours after their start | `run/p3ab.sh stop-watches b-1` |
| Files under `/root/kata-cp`, in `p3/run`, `p3/requests`, `p3/state`, `logs/p3` and `secrets/d-a-1`, `d-a-2`, `d-b-1` | Remove the folders |

Disk and memory:

| Look | Disk in use | Disk free |
|---|---|---|
| Before the removal of the archives | 225 GiB | 76 GiB |
| After the removal | 211 GiB | 90 GiB |
| Step A cluster up | 215 GiB | 86 GiB |
| Step B cluster up, at the end | 217 GiB | 83 GiB |

221 GB of memory are available at the end. The machine has no swap.

What a privileged worker could change on the machine, and what I saw:

- Docker adds one rule to its own raw table for each container address on `kata-bb`, of the form `-A PREROUTING -d 172.29.2.11/32 ! -i br-katacp -j DROP`. The rule goes with the container. Docker does that for each container, also for the kind nodes and for the simulator.
- The nft tables and the chain names of the root network namespace are the same with one worker, with no worker and with two workers (9 tables, 42 chains, the same checksum of the names). The count leaves out the per Service chains of the own cluster of the machine.
- The root network namespace has no Geneve interface and no Open vSwitch interface.
- The kernel settings that are not per namespace (`vm.overcommit_memory=1`, `kernel.panic=10`, `kernel.panic_on_oops=1`, `vm.panic_on_oom=0` and six more) are the same in the three looks. No look exists from before the first worker of this day, so I cannot say if that worker changed one of them. A kubelet sets the first four, and the kind nodes of the lab have a kubelet since phase 1.
- No firewall command, no Docker setting, no package and no module load came from me.

## 9. What is not tested

- The pass rules 4 to 6 (a worker more, a worker less, a rollout of the control plane with workers, the delete with all checks) and the reboot try.
- A join with the request of the preparation. It failed one time (run a-1) and I did not try it again.
- The cause of `nfnetlink_cttimeout` and of `tls`.
- A restart of a worker container, and with it the effect of the interface order (finding 5).
- A fixed interface name in `docker-two-nets`.
- The encryption of etcd (the request has `etcdEncrypted: false`), and the health gate with workers under load.
- The virtual machine form of the mock, a real NICo, a TPM, a Mellanox device.
- The removal of the kernel modules.
- More than two workers, and two clusters at one time.

## 10. Files

- Lab driver of this run is `run/p3ab.sh` in this folder, with `run/ping.py`, `run/hostfacts.sh` and `run/after-delete.sh`.
- Changed request templates are in `requests/`.
- Logs on the workstation are in `/scratch/kata-cp/logs/bigbox/remote-logs/p3/`, in the folders `a-1`, `a-2` and `b-1`.

| File | Content |
|---|---|
| `a-1/race-evidence.txt` | The times and the files of fault 1 |
| `a-1/after-delete.txt`, `a-2/after-delete.txt` | What is left after each delete |
| `a-2/tunnels-joined.txt`, `a-2/traffic-joined.txt`, `a-2/rule3-joined.txt` | Step A with one network |
| `a-2/provider-id.txt`, `a-2/module-times.txt` | Provider ID writer and module times |
| `b-1/facts-b.txt`, `b-1/tunnels-provisioned.txt` | Step B facts |
| `b-1/traffic-rule2.txt`, `b-1/rule3-rule3.txt` | Pass rules 2 and 3 |
| `b-1/watch-summary-end.txt` | The each-second call and the Ready watch |
| `*/timeline.txt` | One line for each change of the state, one look each 10 s |
| `*/snap-*/` | The objects, the CAPNICo log, the simulator log and the workflow list |
| `*/hostfacts-*.txt` | The read-only facts of the machine |
