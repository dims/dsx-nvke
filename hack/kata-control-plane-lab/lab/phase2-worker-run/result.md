# Phase 2, step 8: one worker that joins a cluster of the provider (result)

Machine: `the second test machine`, 2026-11-27 03:04 to 04:21 UTC.
Provider: `cluster-api-provider-podvm:bb15b535`. Node image for each node: `nvke-node-podvm:bcc4376f-p5` (agent of commit `f240606c`). NVKE controller: `nvke-controller:c6d669ef`, no change, default settings.
Cluster: `kata-cp1`, NVKE ID `8caca331-bf11-415b-9742-851cbe3b4b45`, the cluster with three p5 control plane nodes that the last task left up.
Scripts: `/scratch/kata-cp/work/bigbox/remote/p2-worker/` (they load `p2-agentfix/run.sh` and the scripts under it). The same files are in `/root/kata-cp/` on the machine.
Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/p2s8/` (copy of `/root/kata-cp/logs/p2s8/`, no secrets folder). Run folder: `w-1`.

Each change of the cluster went through the NVKE API. Two steps were by hand, as the tests ask: the label on the worker Node of the new cluster (W3) and the delete of the worker pod (W4). I wrote no file into a guest. The tunnel facts come from reads only.

## 1. Verdict

| Test | Verdict | Main facts |
|---|---|---|
| Provider `bb15b535` | Installed, the cluster stayed | Manager `v0.24.0-beta.18-8-gbb15b535`, lease since 03:05:19. After two Machine deletes: 0 error lines, 0 lines "failed to remove the finalizer" |
| W1, one worker | PASS | `POST /api/nodePools` with a `PodVMMachineTemplate` manifest. Pod in the worker form of 5a. NVKE joined it as a worker. NVKE good after 87.9 s, Node Ready after 89.2 s, provider ID `podvm://d/kata-cp1-wk-5311` |
| W2, traffic with a worker | PASS | Pod traffic 6 of 6 between the worker and each control plane node (16 of 16 in all). Name lookup and API Service from a pod on the worker. OVN pod 5/5. Tunnels on the fixed addresses. `kubectl logs`, `kubectl exec`, Service proxy and pod proxy through each of the three API servers |
| W3, reboot through NVKE | PASS, after 31 minutes | NVKE tries a soft reboot first. In a pod VM that gives no new boot ID. After its 30 minute limit NVKE set the annotation on the Machine. The provider deleted the pod one time and made it again 5.1 s later. New boot ID. The workflow ended by itself 61 s after the annotation |
| W4, lost worker pod | PASS | New pod 21.8 s after the delete (same name, claims, Secret copy, address). Startup probe passed after 44.6 s, new kubelet heartbeat after 71.6 s. Traffic 6 of 6 again |
| W5, remove the worker through the API | PASS for the node delete and for the pool delete. The count alone removes nothing | `PATCH desiredNodeCount: 0` is accepted and tears nothing down (by design of NVKE). `DELETE /api/nodes/{id}` with the count at 0: gone after 18.3 s. `DELETE /api/nodePools/{id}` with one node: gone after 30.0 s. The provider removed pod, claims and Secret copy each time. The control plane had no change |

The cluster that stays up: three control plane nodes and one worker (`kata-cp1-wk-0495`, pool `workers`).

## 2. Preparation

1. Provider `bb15b535`: `docker save` on the workstation (30 MB), one copy, import into the four kind nodes, `infrastructure-components-bb15b535.yaml` applied. The manifest differs from `2f2841c5` only in the image tag. The three control plane Machines stayed as they were.
2. Storage loop (`p2-replace/storage-loop.sh`) in the background from 03:16 to 04:19.
3. Disk before each test: 0.4 to 1.3 ms (15 measures, section 9). I did not have to wait.

## 3. The worker flow of NVKE (source reading)

Paths are under `/scratch/kata-cp/src/nvke-endpoint/controller/`.

| Point | What NVKE does | Source |
|---|---|---|
| Request | `POST /nodePools` with `clusterID`, `name`, `nodeNamePrefix`, `desiredNodeCount` and exactly one of `nico`, `infra`, `launchLayer`. `infra.machineTemplate` is "Arbitrary JSON manifest". Also `infra.bootstrapFiles` and `infra.preKubeadmCommands` | `api/openapi.yaml:604-667`, `:1855-1991`, `:3416-3438` |
| Check | The provider type of the cluster decides. On `infra`: the template must be there, not empty, and a valid manifest of the infrastructure API group | `internal/server/node_pools.go:247-272`, `:274-294`, `:296-323`, `internal/clients/capi/nodepoolvalidate.go:13-19` |
| Memory default | `systemReservedMemory` of a pool is 16Gi when omitted. A pod with 6Gi needs a smaller value in the request (I used 512Mi, as for the control plane) | `api/openapi.yaml:1888-1893` |
| Node rows | The node set controller makes one pending node row for each missing node. Name: `<cluster>-<prefix>-<4 digits>` | `internal/controllers/nodeset/controller.go:126-146`, `:236` |
| Count goes down | No teardown: "delete pending nodes, skip auto-teardown". A node goes with `DELETE /nodes/{id}`, with the pool delete, or with the terminate label | `internal/controllers/nodeset/controller.go:148-158` |
| One workflow | A worker joins inside `ProvisionNode`. A control plane node stops at "ready to join" and the control plane controller joins it with `JoinNode`, one at a time | `internal/controllers/nodescheduling/service.go:79-83`, `internal/temporal/workflows/provision_node.go:89-100`, `join_node.go:25-27` |
| Host steps | The same for both roles: `CreateCAPIInfraMachineForNode`, `WaitForCAPIMachineReady`, `NodePreflight`, `ConfigureOpenVSwitch` (when the CNI is OVN), ready to join | `provision_node.go:64`, `:211-246`, `:404-431` |
| Wait for the pool | Only for a node of a pool: `WaitForParentNodePoolProvisioned` | `provision_node.go:261-265` |
| Join string | NVKE asks a joined control plane node (5 minute cache) and takes the worker string. No `--control-plane`, no certificate key | `internal/temporal/activities/kubeadm_join.go:93-104` |
| Join retries | A worker join has no limit of attempts. The control plane join has one attempt for each workflow run | `provision_node.go:98-100`, `join_node.go:48-51` |
| Taint at the join | A worker gets `nvke.nvidia.com/provisioning:NoSchedule` in its join config. A control plane node gets none from NVKE | `internal/kubeadmconfig/join.go:119-127` |
| Labels | `k8s.ovn.org/zone-name=<node name>` for both roles. The control plane role label comes from kubeadm and NVKE checks it only for a control plane node | `provision_node.go:684-689`, `:315-320` |
| After the join | `LabelNode`, `ApplyNodeMetadata` (labels and taints of the pool), `ConfigureKubeVip` (no effect for a worker), the provisioning taint is removed, the node is marked provisioned | `provision_node.go:300-345` |
| Certificates | The client request is approved by the cluster itself (`AutoApproved`). NVKE approves the kubelet serving request when name and address match the node row (`NKEValidatedNodeIdentity`). The same for both roles | `internal/controllers/tenant/csr/controller.go:47`, `:116`, `:369` |
| CNI | Nothing for one node. The OVN and DNS daemon sets start a pod on the new node | |
| Failure domain | Only the control plane controller gives a Machine a failure domain. A worker Machine has none | `internal/controllers/controlplane/scale.go:103`, `internal/db/nodes.go:34-36` |
| Teardown | Drain, kubeadm reset, delete of the Machine, of the Node and of the node row. Graceful shutdown and etcd member removal only for a control plane node | `internal/temporal/workflows/teardown_node.go:235-270` |
| Pool delete | `TeardownNodePool`: start the teardown of each node, wait, delete the pool row | `internal/server/node_pools.go:436-461`, `internal/temporal/workflows/teardown_node_pool.go:25-60` |
| Reboot | The label `nvke.nvidia.com/reboot` on the Node starts `RebootNode`. Not allowed for a control plane node. First the agent RPC `ScheduleNodeReboot` (the agent runs `reboot`), then a wait for a new boot ID of the Node, at most `NODE_REBOOT_INITIAL_TIMEOUT` (30 minutes). Only then the annotation `nvke.nvidia.com/reboot=<time>` on the Machine | `internal/controllers/tenant/noderemediation/remediation.go:45-53`, `:119-127`, `internal/temporal/workflows/reboot_node.go:84-92`, `:163-212`, `internal/temporal/activities/soft_reboot_node.go:83`, `wait_for_node_reboot.go:80-108`, `capi_node_resources.go:477-492`, `internal/config/config.go:219-237`, agent `agent/internal/agent/node_reboot.go:58` |

What I saw and the source reading did not say: NVKE makes no `PodVMMachineTemplate` object, no MachineDeployment and no KubeadmConfig. It keeps the template in its database and makes one `Machine`, one `PodVMMachine` and one bootstrap Secret for each node. `nvke-system` had no `podvmmachinetemplates` object at any time.

Provider side (`/scratch/kata-cp/src/nvke-podvm/cluster-api-provider-podvm/`): the control plane label of the pod and the readiness probe depend on the label of the Machine (`controllers/machine_resources.go:429-432`, `:467-478`). The two volume devices and the startup probe are for each machine (`:450-465`). With no failure domain the pod has only the preferred spread over host nodes (`:550-553`). Reboot answer: `controllers/machine_controller.go:61-65`, `:402-411`, `:451-490`.

## 4. W1: one worker

Request (`w-1/pool-workers-request.json`): `name: workers`, `nodeNamePrefix: wk`, `desiredNodeCount: 1`, `systemReservedMemory: 512Mi`, `infra.machineTemplate` = the `PodVMMachineTemplate` of the control plane (image p5, 2 CPUs, 6Gi, class `podvm-local-block`, 20Gi and 8Gi). Answer: HTTP 201, pool ID `de8b65ea-064d-4fb6-8a02-c394d841224a`.

| Time (UTC) | Event | After the POST |
|---|---|---|
| 03:16:23 | POST | |
| 03:16:23.78 | `ProvisionNode` workflow starts | 0.5 s |
| 03:16:24.56 | `CreateCAPIInfraMachineForNode` done | |
| 03:16:26.61 | Provider: address `172.28.1.4`, Secret copy, two claims, pod made | 3 s |
| 03:17:02.28 | Provider: the node agent answers, address and provider ID set | 39 s |
| 03:17:10.04 | `WaitForCAPIMachineReady` done (45.5 s) | 47 s |
| 03:17:12.19 | `ConfigureOpenVSwitch` done (2.0 s) | 49 s |
| 03:17:23.14 | `KubeadmJoin` done (10.9 s, first attempt) | 60 s |
| 03:17:23.45 | Workflow completed (59.7 s) | 60 s |
| 03:17:41 | Node Ready in the new cluster | 78 s |
| 03:17:51 | NVKE reports the node as good (seen at 87.9 s, one look each 10 s) | 88 s |
| 03:18:10 | OVN pod on the worker Ready 5/5 (56 s after the Node registered) | 107 s |

A control plane node needed 30 to 51 s for `KubeadmJoin` in the last task. The other two workers of this task: 88.0 s to good, OVN pod Ready 59 s and 75 s after the Node registered.

Pass rules:

- Pod form: no label `cluster.x-k8s.io/control-plane`, no readiness probe, startup probe TCP 15005 (each 2 s, 600 failures), image p5, two volume devices, grace 20 s, the network annotation with `172.28.1.4/16` and `02:00:ac:1c:01:04`. The pod is not behind the shared Service `cp-api`.
- NVKE has the node with `controlPlane: false` and each condition of a good node.
- Node `kata-cp1-wk-5311`: Ready, provider ID `podvm://d/kata-cp1-wk-5311`, InternalIP `172.28.1.4`, no role label, no taint.

Record:

| Point | Worker | Control plane node |
|---|---|---|
| Machine labels | `cluster.x-k8s.io/cluster-name` | plus `cluster.x-k8s.io/control-plane` |
| Failure domain | none | the host node name |
| Host node | `kata-bb-worker` (the second pod of the cluster there) | one for each host node |
| Volumes | `podvm-loop60` (var), `podvm-loop69` (etcd) | the same kinds |
| Join command of the agent | `kubeadm join 172.29.255.220:6443 --token <redacted> --discovery-token-ca-cert-hash sha256:...` | plus `--control-plane --certificate-key <redacted>` |
| Join config | taint `nvke.nvidia.com/provisioning:NoSchedule` | `controlPlane:` section, `taints: null` |
| Node labels | `k8s.ovn.org/zone-name` and the kubelet defaults | plus the role label and `exclude-from-external-load-balancers` |
| Node taints | none at the end | `node-role.kubernetes.io/control-plane:NoSchedule` |
| Certificates | client request `AutoApproved`, serving request `csr-cnwzr` approved by NVKE 1 s after the Node registered | the same |
| `/etc/kubernetes` | `kubelet.conf`, `pki/ca.crt`, empty `manifests` | plus `admin.conf`, four static pods, the other files |
| `/var/lib/etcd` | mounted from `/dev/podvm-etcd` (7.8 GB, 2 MB used), empty | 134 MB used |
| Containers | OVN (5), `node-cache` | plus the control plane |
| Workflows | `ProvisionNodePool` (0.1 s) and one `ProvisionNode` with the join inside | `ProvisionNode`, then `JoinNode` |

The first W1 record printed FAIL. It read the OVN pod 41 s after the Node registered, when the pod was 0/5. That was a fault of my check. The check waits for the pod now (at most 3 minutes). The second record is PASS.

## 5. W2: traffic with the worker

Test pods `p1-t-a` to `p1-t-d`, one on each node, with one Service each (`w-1/w2-w2.txt`, `traffic-w2.txt`, `tunnels-w2.txt`).

- Pod to pod: each of the 6 lines between the worker and a control plane node passes (ping 3 of 3, TCP to the pod, TCP to the Service). All 16 lines of the matrix pass.
- From the pod on the worker: name lookup of `kubernetes.default.svc.cluster.local` and the API Service `10.112.0.1:443` pass.
- OVN pod on the worker: 5/5. Node subnet `10.113.0.0/24`, zone = the node name.
- Tunnels: the tunnel address of the worker is `172.28.1.4`. It has one tunnel port to `172.28.1.1`, `.2` and `.3`. Each control plane node has one tunnel port to `172.28.1.4`. The tunnel flows in the datapath right after the calls have only the fixed addresses as outer source and destination. (The line "outer addresses that are not in the node range: [6081]" in the log is the port number, a fault of my pattern.)

Calls of an API server to the pod `p1-t-d` on the worker. I called each API server by its own address, so I know which one served the call.

| Through | `kubectl logs` | `kubectl exec` | Service proxy | Pod proxy | Source that the pod saw for the proxy calls |
|---|---|---|---|---|---|
| API server of `kata-cp1-cp-43a3c6ef` (`172.28.1.1`) | ok | ok | ok | ok | `10.113.4.2` |
| API server of `kata-cp1-cp-5f019555` (`172.28.1.2`) | ok | ok | ok | ok | `10.113.5.2` |
| API server of `kata-cp1-cp-9b859b18` (`172.28.1.3`) | ok | ok | ok | ok | `10.113.2.2` |
| Shared address `172.29.255.220:6443` | ok | ok | ok | ok | `10.113.5.2` and `10.113.2.2` in W2 |

- The source address is the address of that control plane node on the pod network (address `.2` of its node subnet). So the proxy calls go from the API server through the pod network and the tunnel to the pod on the worker. For the shared address the source tells which API server served the proxy call.
- `logs` and `exec` go to the kubelet of the worker at its InternalIP `172.28.1.4` (`--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname`). They need the serving certificate that NVKE approved.
- Service proxy path: `/api/v1/namespaces/default/services/p1-t-d:80/proxy/ping.py`. Pod proxy path: `/api/v1/namespaces/default/pods/p1-t-d:8080/proxy/ping.py`.

The same checks passed after W4, after W3, with two workers (25 of 25 lines) and at the end.

## 6. W3: the reboot of the worker through NVKE

Request: `kubectl label node kata-cp1-wk-5311 nvke.nvidia.com/reboot=p2s8-test` with the admin kubeconfig of the new cluster, at 03:24:56.

| Time (UTC) | Event |
|---|---|
| 03:24:56.45 | NVKE starts `reboot-node-07dc0400-...` (0.4 s after the label). Labels on the Node: `reboot-started`, `reboot-status=InProgress`, `reboot-attempt=1` |
| 03:24:56.70 | `SoftRebootNode`: the agent takes the request in 0.02 s |
| 03:24:56.74 | `WaitForNodeReboot` starts. NVKE logs "Node has not rebooted yet" each 10 s |
| 03:25:52 | Node Ready is Unknown |
| 03:26:28 | The container of the worker pod ends with exit code 130. The kubelet of the lab cluster starts a new container in the same pod at once (restart count 1, same pod UID, same VM) |
| 03:26:51 | Node Ready again. Boot ID `26bd94de`, the same as before. Kernel uptime goes on |
| 03:54:56.74 | `WaitForNodeReboot` fails at its 30 minute limit |
| 03:54:57.07 | `ApplyCAPIMachineRebootAnnotation`: `nvke.nvidia.com/reboot=2026-11-27T03:54:56Z` on the Machine |
| 03:54:57.07 | Provider: "Deleting the pod for a reboot request" (one line). `status.lastRebootRequest` gets the value |
| 03:55:02.17 | Provider: "Made the pod of the machine", 5.1 s after the delete |
| 03:55:05 | One failed sandbox start (Multus got no answer from the API server of the lab cluster in time, see the disk note). The kubelet tried again |
| 03:55:26 | Container started |
| 03:55:36 | The Node has the new boot ID `c7850966` |
| 03:55:58.12 | `WaitForNodeReboot` done (it looks each 60 s on this path) |
| 03:55:58.33 | Annotation removed, labels `reboot-status=Completed` and `last-completed-reboot`, workflow completed |
| 03:56:09 | Node Ready |

- Run time of the workflow: 31 min 1.9 s. From the annotation to the end: 61.3 s.
- Pass rules: workflow started and completed by itself, annotation set, one pod delete by the provider, new pod UID, same pod name, host node, address, hardware address, claims and Secret copy, new boot ID, Node Ready, control plane with no change. Pod traffic after it: 6 of 6.
- Pods on the worker: the daemon set pods keep their pod objects and get new containers (node-local-dns 1, 2, 3 restarts, OVN 5, 10, 15 over the lost pod, the soft reboot and the hard reboot). A pod with restart policy Never (my test pod) goes to Unknown and then Failed.
- Shared address in the 32 minutes: 1879 calls, 1877 with 200. One call with no answer at 03:54:42 and one 500 at 03:54:45. Both are before the hard reboot and fall in a slow disk episode of the machine: etcd of the new cluster logged "leader failed to send out heartbeat on time ... likely from slow disk" and applies of 600 to 850 ms from 03:54:30 to 03:54:36, and etcd of the lab cluster logged slow applies in the same seconds. The disk was at 0.5 ms four minutes later.

The finding of W3: a soft reboot in a pod VM is a restart in place of the container. The VM and its kernel stay, so the boot ID of the Node does not change, and NVKE cannot see the reboot. With the default settings each reboot request costs two node restarts and 30 minutes. NVKE has a setting for such a provider: `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` "for any backend where the in-guest reboot path can never produce a real, detectable boot change" (`internal/config/config.go:232-237`). I did not change the controller, so the direct path is not tested. A second way is the annotation `nvke.nvidia.com/reboot-complete-timestamp` on the Machine, which the wait also accepts (`wait_for_node_reboot.go:95-103`). The provider does not set it.

## 7. W4: a lost worker pod

Delete of the pod `kata-cp1-wk-5311` at 03:20:31 (`w-1/lost-pod-d.txt`).

| After the delete | Time |
|---|---|
| Old pod gone | 21.7 s |
| New pod of the provider | 21.8 s |
| systemd up | 35.0 s |
| Startup probe passed, pod Ready | 44.6 s |
| New kubelet heartbeat | 71.6 s |

- Same pod name, host node, address, hardware address, claims, Secret copy and machine record. New pod UID, new boot ID. Two repeat runs of the bootstrap units, no first run.
- NVKE: no workflow. In 12 polls (one each 10 s) the node was without `kubernetesReady` 3 times and without `nodeAgentReady` 1 time. It had both again at the end. The cluster stayed provisioned.
- Shared address: 133 of 133 calls. Control plane: no change.
- After it: pod traffic 6 of 6, name lookup, OVN pod 5/5, the API server calls of W2.

## 8. W5: remove the worker through the NVKE API

| Step | Request | Result |
|---|---|---|
| Count to zero | `PATCH /api/nodePools/<id>` with `desiredNodeCount: 0` at 04:02:07 | HTTP 200. The pool shows 0. NVKE logs "Updated current node set desired count". No teardown in 6 minutes. By design (`internal/controllers/nodeset/controller.go:148-158`). I stopped the step |
| W5a, node delete with the count at 0 | `DELETE /api/nodes/07dc0400-...` at 04:09:10 | HTTP 202. `TeardownNode` 04:09:10.83 to 04:09:19.35 (8.5 s: drain 5.1 s, kubeadm reset 2.5 s, Machine, Node, row). Node gone, 3 good nodes after 18.3 s. No new node in the next 60 s |
| Count to one | `PATCH` with `desiredNodeCount: 1` at 04:10:55 | New worker `kata-cp1-wk-0495`, address `.4` again, host node `kata-bb-worker3`. 4 good nodes after 88.0 s. W1 checks pass |
| W5b, pool delete with one node | `DELETE /api/nodePools/c9114ba1-...` (pool `workers-b`, node `kata-cp1-wk-6343`) at 04:17:11 | HTTP 202. `TeardownNodePool` 04:17:14.48 to 04:17:34.66 (20.2 s), with `TeardownNode` 7.7 s. Node gone and `GET` of the pool 404 after 30 s. The worker of the other pool stayed |
| Name again | `POST` of a pool `workers-b` with `desiredNodeCount: 0` | HTTP 201, no node. A `POST` with a name that exists gives 400: "A node pool already exists with the name" |
| Empty pool delete | `DELETE` of that pool | 404 after 6.9 s |

For each delete: no pod, no claim, no Secret copy, no `PodVMMachine`, no `Machine`, no bootstrap Secret and no Node were left. The storage loop made the two volumes free again. The provider logged 0 error lines and 0 lines with the finalizer fault. The control plane had no change (same pods, restart counts, claims, etcd members, boot IDs, endpoints of `cp-api`). The shared address answered each call with 200 (83, 91, 35 and 12 calls).

How the second pool came to be: my pool delete step died before it sent the DELETE (a jq variable of my script had the name of one that the loaded script uses). The chain then asked for the pool `workers` again, got the 400 above, and took its second name. So the cluster had two workers for 4 minutes. I used that state for the record in section 10 and deleted the second pool as W5b.

## 9. Disk values

Write time of `vda` over 10 s, from `/proc/diskstats`.

| Before | Write time |
|---|---|
| W1, node pool (03:16) | 0.8 ms |
| W2 (03:19) | 1.3 ms |
| W4 (03:20) | 0.8 ms |
| W3 (03:24) | 0.7 ms |
| After W3 (03:58) | 0.5 ms |
| W5, count to zero (04:01) | 1.3 ms |
| W5a (04:09) | 1.2 ms |
| Count to one (04:10) | 0.7 ms |
| Second pool by the lab fault (04:13) | 0.4 to 0.7 ms |
| Two workers, traffic (04:15) | 0.6 ms |
| W5b (04:17) | 0.8 ms |
| Empty pool (04:18) | 0.5 to 0.7 ms |
| End (04:20) | 0.6 ms |

One slow episode in between, at about 03:54:30, seen in the etcd logs and not in a measure (section 6).

## 10. Findings

1. **The etcd volume of a worker.** The provider makes the claim `<name>-etcd` for each machine, and the image formats it and mounts it at `/var/lib/etcd`. On the worker it is empty (2 MB of 7.8 GB). The cost is one volume of the etcd size on the host node for each worker, here 8Gi and one of the six etcd volumes of the lab. Nothing failed with the volume. A worker with no etcd volume is not possible today: the API of the provider refuses it (server side dry run of a `PodVMMachine` with no `volumes.etcd`: "spec.volumes.etcd: Required value", nothing was written), and the entry point of the image stops when `/dev/podvm-etcd` is not a block device (`p2-image/podvm-entrypoint:74-79`, `:99-107`). I did not change the provider.
2. **Storage.** A worker takes one Machine place (one var volume and one etcd volume) on its host node. The first worker ran on `kata-bb-worker`, the later ones on `kata-bb-worker3` and `kata-bb-worker2`. A worker Machine has no failure domain, so the scheduler is free: it spreads the pods of the cluster (preferred) and needs a host node with two free volumes. Two workers at one time ran on two different host nodes. A second worker needs one more free place. The lab has six places, so three control plane nodes and three workers fill it.
3. **Workers and a control plane rollout.** In the rollout of the last task each surge pod ran on the host node of the node that NVKE replaced next. With a worker on the second place of a host node, a surge pod for that host node has no volume. I did not test it. With local volumes each host node needs places for its control plane node, one surge and its workers.
4. **Reboot.** Section 6: the soft reboot gives no new boot ID, 30 minutes with the default settings.
5. **Count of a pool.** A lower `desiredNodeCount` removes no node (section 8).
6. **Open vSwitch system ID.** The file `/etc/openvswitch/system-id.conf` is not on a volume, and the database of Open vSwitch is (`/var/lib/openvswitch/conf.db`). So each new pod and each restart in place gives the node a new OVN chassis ID (`8e9e1f17` at the first start, `abe6d668` after the lost pod, `96dec24e` after the soft reboot, `1fa7f324` after the hard reboot). The old chassis row stays in the southbound database of the node itself, with a tunnel port to its own address and 0 packets. I saw it 2.5 and 3.5 minutes after a new pod, and it was gone 6 minutes after, with no restart in between. Pod traffic passed in that time. The image is the same for a control plane node, so I expect the same there. I checked it only on the worker.
7. **Journal.** The journal of the guest is in memory. After a restart in place and after a new pod the journal starts new, so the lines of the agent about the reboot request were gone.
8. **Node image for a worker.** The worker needs nothing different to join and to run: the same image, the same bootstrap units, the same Open vSwitch step. It carries what only a control plane node uses (the etcd mount). The memory default of a node pool (16Gi system reserved) does not fit a 6Gi pod, so the request must set it.
9. **Provider `bb15b535`.** After the two Machine deletes of this task the line "failed to remove the finalizer ... not found" did not come again.

## 11. Failures and their causes

No test failed at its pass rules. What went wrong:

1. W1, first record: FAIL from my check of the OVN pod, read too early. Corrected, PASS.
2. W5, count to zero: NVKE accepts the request and removes nothing, by design. I used the node delete and the pool delete.
3. W5, lab fault: my pool delete step died on a variable name of my own script before it sent a request. The chain made a second pool. Corrected. No harm to the control plane, and the second worker gave the record for two workers.
4. W3: 30 minutes before the Machine annotation, by the default settings of NVKE.
5. W3: two calls to the shared address that were not 200 and one failed sandbox start of the new worker pod, in a slow disk episode of the machine at about 03:54:30 to 03:55:05.

## 12. Not tested

- The reboot with `NODE_REBOOT_SOFT_REBOOT_ENABLED=false` (a change of the controller settings).
- A worker with no etcd volume (the provider and the image refuse it).
- A control plane rollout or replace while a worker holds the second place of a host node.
- A change of the machine template of a pool (a worker rollout), `maxSurge` and `recycleBudget` of a pool, `nodeLabels` and `nodeTaints`, `bootstrapFiles` and `preKubeadmCommands`.
- The terminate label on a Node.
- The old chassis row on a control plane node after a new pod.
- More than two workers. A host node with a worker and no control plane node.
- `kubectl port-forward` and `kubectl attach`. A workload other than the test pods.

## 13. Changes on the machine and how to remove them

All under `/root/kata-cp` or in the lab cluster. No firewall rule, no listener on an outside interface, no change of the Docker or containerd configuration or of the network settings, no restart, no database write, no Temporal change, no write on an NVKE or Cluster API object of the management side except through the NVKE API. One server side dry run of a `PodVMMachine` wrote nothing. Machine checks at the end are unchanged (disk 201 GB of 300 GB).

| Change | Removal |
|---|---|
| Cluster `kata-cp1`: three control plane nodes and the pool `workers` (`de8b65ea-064d-4fb6-8a02-c394d841224a`) with the worker `kata-cp1-wk-0495` (address `.4`, host node `kata-bb-worker3`). It stays up | Pool: `LOG_DIR=/root/kata-cp/logs/p2s8/w-1 p2-worker/run.sh pool-delete <label>`. Cluster: `LOG_DIR=/root/kata-cp/logs/p2s6b/fix-1 p2-agentfix/run.sh delete`, then `p2-provider/storage.sh reset` |
| In the new cluster, namespace `default`: test pods and Services `p1-t-a` to `p1-t-d`, ConfigMap `p1-probe` | They go with the cluster |
| Provider Deployment with the image `bb15b535`, the image in the four kind nodes, archive `dl/img/cluster-api-provider-podvm_bb15b535.tar` (30 MB) | `kubectl delete -f` of the two manifests in `p2-worker/install/`, `ctr -n k8s.io images rm` in each node, `unlink` of the archive |
| Worker `kata-cp1-wk-5311`, pool `workers-b` with `kata-cp1-wk-6343`, the empty pool `workers-b`: gone, deleted through the NVKE API | Nothing to do |
| The storage loop: stopped. 8 volumes Bound, 4 Available | Nothing to do |
| Folders `p2-worker`, `logs/p2s8`, `secrets/d-w-1` (mode 700: workflow histories) | Remove the folders |
| Workstation: scripts, logs, this file. The image archive that I made for the copy is removed again | Nothing to do |
