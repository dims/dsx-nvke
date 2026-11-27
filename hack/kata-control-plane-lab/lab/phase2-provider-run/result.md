# Phase 2, steps 4 and 5: the first cluster through NVKE with `cluster-api-provider-podvm` (result)

Machine: `the second test machine`, 2026-11-26 23:00 to 2026-11-27 00:20 UTC.
Provider image: `cluster-api-provider-podvm:cdc368ea`. Node image: `nvke-node-podvm:bcc4376f-p2`. NVKE controller: `nvke-controller:c6d669ef`, no change.
Scripts: `/scratch/kata-cp/work/bigbox/remote/p2-provider/` (the same files are in `/root/kata-cp/p2-provider/` on the machine).
Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/p2s4/` (copy of `/root/kata-cp/logs/p2s4/`, no secrets folder).

## 1. Verdict for the eight points

| Point | Verdict | Main facts |
|---|---|---|
| 1. One request makes the cluster | PASS in run 1 and run 2 | NVKE reports provisioned after 252.5 s and 252.4 s. 3 Ready control plane nodes. The script made no pod, no claim and no Secret copy |
| 2. Pod traffic, name lookup, OVN, etcd, endpoint | PASS in run 1 and run 2 | Pod traffic 6 of 6, name lookup 3 of 3, `ovnkube-node` 5/5 on each node, etcd with kubeadm default flags and 0 rejected peers, endpoint rules pass |
| 3. Objects of the provider | PASS in run 1 and run 2 | Each pod meets 32 rules of the pod table. Addresses `172.28.1.1` to `.3`, hardware addresses `02:00:ac:1c:01:01` to `:03`. Startup probe passed. Provider ID `podvm://d/<pod>` on the Machine, the `PodVMMachine` and the Node. `PodVMCluster` is provisioned with 3 failure domains |
| 4. Times | Recorded | `WaitForCAPIMachineReady` 115.3 to 115.5 s. `NodePreflight` 0.1 s with 1 attempt. Table in section 3 |
| 5. Lost pod | PASS for a joined node and for the first node | New pod 0.1 to 0.2 s after the old pod was gone. Same name, claims, Secret copy, address, hardware address. Shared address: 255 of 255 and 253 of 253 calls. NVKE reported provisioned in each poll. Pod traffic 6 of 6 after each |
| 6. Reboot through NVKE | Not possible for a control plane node. NVKE needs a change, or the test needs a worker | NVKE has no reboot call in its API. The request is a Node label. For a control plane node the workflow ends in 0.2 s with `NotAllowed` and NVKE asks the provider for nothing. Section 6 |
| 7. Delete through the NVKE API, no operator step | PASS, two times | Teardown workflow completed by itself in 24.3 s and 24.4 s. Row gone 34.9 s after the DELETE. Nothing of the cluster is left. Namespace, network attachment and Service stay |
| 8. Run 3 with the same name | PASS | Cluster made again: provisioned after 253.7 s, 3 Ready nodes, addresses `.1` to `.3` again, new node names. Pod traffic 6 of 6 at the second try. The disk of the machine got slow during this run, and the pods lose their Ready state at times. Section 8 |

No fault in the provider code stopped a step. Point 6 is the one point where NVKE itself needs a change.

## 2. Preparation

1. T4 cluster deleted with the operator procedure (`p2-image/test/t4-delete.sh`): row gone 129.5 s after the DELETE, 12.0 s after the operator steps.
2. Provider image: `docker save` on the workstation (30 MB), one copy through the SSH connection, import into the four kind nodes.
3. Install (`p2-provider/install.sh`): `infrastructure-components.yaml` and `nvke-controller-rbac.yaml`, no change. The manager runs with `--leader-elect` and holds the lease `podvm-system/podvm.infrastructure.cluster.x-k8s.io`. The service account of the NVKE controller has `create`, `delete`, `get`, `list`, `patch`, `watch` on the three kinds in `nvke-system`, and `get` on their CRDs. The NVKE controller needed no restart.
4. Storage (`p2-provider/storage.sh`): class `podvm-local-block` (`kubernetes.io/no-provisioner`, `WaitForFirstConsumer`, `Retain`). Twelve local volumes with volume mode Block and no claim reference: six of 20Gi and six of 8Gi, on `/dev/loop60` to `/dev/loop71`.
   - Placement: each of the three workers has two volumes of 20Gi and two of 8Gi, by node affinity. That is two Machine places for each worker. One cluster uses one place on each worker, and one spare place stays on each worker.
   - The scheduler bound the 8Gi claim to an 8Gi volume and the 20Gi claim to a 20Gi volume of the same worker in each run.
   - Between runs, `storage.sh reset` deletes each Released volume, wipes its device and makes the volume again.
5. Pod namespace `d` with the network attachment `nodenet` and the Service `cp-api` (`172.29.255.220`, selector: the two Cluster API labels). Made before the request.
6. Address range `172.28.1.0/24`: no pod of the lab cluster had an address of it, and 0 of 254 addresses answered an echo request. The kind nodes had old neighbor entries (state STALE) for `.11` to `.13`, `.21` to `.23`, `.31` to `.33` from earlier tests, none for `.1` to `.3`.
7. Request (`p2-provider/request.json.tmpl`): `infra.cluster` with the `PodVMCluster` spec of the sample, `controlPlaneConfig.infra.machineTemplate` with the image `docker.io/library/nvke-node-podvm:bcc4376f-p2`, pull policy `Never`, 2 CPUs, 6Gi, the class for both volumes, and `controlPlaneEndpoint` `172.29.255.220:6443`. The rest as in block D.

## 3. Times

Seconds. The three activities are from the Temporal history of each node workflow.

| | Block D run 2 | T4 | Run 1 | Run 2 | Run 3 |
|---|---|---|---|---|---|
| Who makes the pods | Script, before the POST | Script, after the POST | Provider | Provider | Provider |
| POST to three pods | before | 38.7 to 40.0 | 36.0 | 41.7 | 36.1 |
| POST to three started containers (startup probe) | none | none | 147.7 | 147.7 | 148.9 |
| `WaitForCAPIMachineReady` | 3.1 (3 attempts) | 3.1 (3 attempts) | 115.4 (15 attempts) | 115.3 (15 attempts) | 115.5 (15 attempts) |
| `NodePreflight` | 30.1 (2 attempts) | 100.2, 221.4, 222.2 (3, 4, 4 attempts) | 0.0 to 0.1 (1 attempt) | 0.1 (1 attempt) | 0.1 (1 attempt) |
| Both steps together | 33.2 | 103.3 to 225.3 | 115.5 | 115.4 | 115.6 |
| POST to provisioned | 176.9 | 239.5 | 252.5 | 252.4 | 253.7 |
| POST to three provisioned nodes | 281.1 | 354.2 | 356.7 | 356.7 | 347.7 |
| POST to three Ready nodes | 281.9 | 378.6 | 361.9 | 375.0 | 358.6 |

What the numbers say:

- The provider and the startup probe work as designed. NVKE gets the address only when the agent answers, and `NodePreflight` passes at the first attempt on each node in each run.
- The start time of a node is now in `WaitForCAPIMachineReady`. Run 1, each node: pod made 3 s after the `PodVMMachine`, container started 11 s later, agent listener 102 to 104 s after the pod was made, address written by the provider 0.3 to 5 s after the listener, seen by NVKE at its next look (5 to 10 s later).
- Against T4 the first node is 10 s slower (147 s against 138 s after the POST), and the other two nodes are 111 s faster. The cluster is provisioned 13 s later than in T4, because NVKE needs only the first node for that.
- Against block D the cluster needs 76 s more. That is the start time of a node (about 105 s with three pods at once), which block D had before the POST.
- The 57 s of the unit `nke-container-cni-images.service` are still the largest part of the node start (finding of step 3).

## 4. Step 4: runs 1 and 2

Script: `p2-provider/run.sh` (`flow`), chain `p2s4-run.sh`. It loads the checks of block D and T4. It makes the namespace, the network attachment and the Service, sends one POST, and then only watches.

What the provider made, run 1 (provider log): the `PodVMMachine` objects came at 23:13:53.9. The provider waited 2.9 s for the owner reference of the Machine, then for each Machine in 0.1 s: address, Secret copy, two claims, pod. NVKE showed the state of the provider in its node condition: "Pod d/... does not run yet", then "Pod d/... runs, the node agent in it does not answer yet".

Pass rule 3, the same in run 1 and run 2 (`provider-final.txt`):

- `PodVMCluster`: `provisioned: true`, condition `Ready=True SpecValid`, failure domains `kata-bb-worker`, `kata-bb-worker2`, `kata-bb-worker3`, each with `controlPlane: true`. The control plane node of the lab cluster has a `NoSchedule` taint and is no domain.
- NVKE gave each Machine one of the three domains, and each pod runs on the host node of its domain:

| Run | Address `.1` | Address `.2` | Address `.3` |
|---|---|---|---|
| 1 | `kata-cp1-cp-f98cf1c9` on `kata-bb-worker` | `kata-cp1-cp-33ecb4e5` on `kata-bb-worker2` | `kata-cp1-cp-28ce5071` on `kata-bb-worker3` |
| 2 | `kata-cp1-cp-af7d450a` on `kata-bb-worker3` | `kata-cp1-cp-79bc523c` on `kata-bb-worker` | `kata-cp1-cp-8ee874a7` on `kata-bb-worker2` |
| 3 | `kata-cp1-cp-922eb785` on `kata-bb-worker2` | `kata-cp1-cp-a5dad918` on `kata-bb-worker` | `kata-cp1-cp-b1811a77` on `kata-bb-worker3` |

- Each pod: 32 rules of the pod table of the README hold (namespace, one container `node`, privileged, image, no command, no arguments, class, limits equal to requests, the two devices, the two claims, the Secret mount, the three variables, one network entry with name, namespace, address and hardware address, the three labels, both probes, no token, no service links, container started).
- The address and the hardware address are the same in the annotation and on `net1` of the guest.
- The provider ID `podvm://d/<pod>` is on the Machine, the `PodVMMachine` and the Node of the new cluster.
- Both claims of a pod are bound to volumes of its host node.
- Names: pod, hostname, NVKE node, agent state file, kubelet, mirror pods and etcd member agree. The three machine IDs differ.

## 5. Step 5, point 5: a lost pod (second cluster)

`run.sh lost-pod`: one `kubectl delete pod` by hand, then only watch.

| Fact | Joined node (host b) | First node (host a) | T4 (script made the pod again) |
|---|---|---|---|
| Old pod gone | 32.1 s | 32.4 s | 22.5 s |
| New pod of the provider | 32.2 s | 32.6 s | 22.6 s |
| Startup probe passed | 84.6 s | 91.1 s | none |
| `/readyz` of the pod | 84.8 s | 91.3 s | 59.5 s |
| New kubelet heartbeat | 85.1 s | 91.6 s | 81.4 s |
| etcd healthy | 85.4 s | 92.1 s | 81.8 s |
| Shared address during the test | 255 of 255 | 253 of 253 | 254 of 254 |
| Own address, failed calls | 36 (65 s) | 26 (35 s) | 26 (36.5 s) |
| `nodeAgentReady` not True in the polls of NVKE | 18 of 24 | 14 of 24 | 13 of 24 |

- The provider logged one line: "Made the pod of the machine". The new pod has the same name, host node, network annotation, claims (same UID), Secret copy (same UID) and machine record. The pod UID and the boot ID of the Node are new.
- The new pod made a repeat run of the bootstrap units: 0 files written, no command, cloud-init answer `done`.
- `status.addresses`, the provider ID and `provisioned` of the `PodVMMachine` did not change. Its Ready condition went to false and back.
- NVKE reported the cluster as provisioned in each poll and started no workflow.
- After each test: pass rule, etcd rule and provider rule pass, pod traffic 6 of 6 with new test pods, name lookup 3 of 3.
- Two differences to T4 come from the pod of the provider: the grace period is 30 s (10 s more until the old pod is gone), and the pod is Ready only after the startup probe. The API server of the node was up earlier, but the pod came behind the shared Service only when the agent answered.

## 6. Step 5, point 6: the reboot through NVKE

Facts from the source of the running controller (`/scratch/kata-cp/src/nvke-endpoint/controller`):

- `api/openapi.yaml` has no reboot request. The paths for a node are `GET` and `DELETE` of `/nodes/{nodeID}`.
- The request is the label `nvke.nvidia.com/reboot` on the Node of the new cluster. The node remediation controller reads it and starts the workflow `reboot-node-<node ID>` (`internal/controllers/tenant/noderemediation/remediation.go:45-53`, `internal/keys/keys.go:146`).
- For a node of the control plane the workflow stops at its start: "label based reboots are not allowed for control-plane nodes" (`internal/temporal/workflows/reboot_node.go:84-92`). Only after that point it would set the annotation `nvke.nvidia.com/reboot` on the Machine (`:354-382`).

Test in the second cluster (`reboot-b.txt`): label `nvke.nvidia.com/reboot=p2s4-test` on the Node `kata-cp1-cp-79bc523c`.

- The workflow started in less than 1 s, ran 0.2 s and completed. Its activities: `GetNodePoolForNode`, `DeleteCAPIMachineRebootAnnotation`, `LabelNode`, `UpdateNodeConditions`.
- The controller logged the sentence above. The Node got `nvke.nvidia.com/reboot-status=NotAllowed`, and the request label was removed.
- The Machine got no annotation. The provider logged nothing, `status.lastRebootRequest` stayed empty, the pod UID and the boot ID did not change.

So a cluster with control plane Machines only gives the provider no reboot request. The pass rule of point 6 needs a change of NVKE, or a worker Machine of this provider.
What the lost pod test shows for the provider side: a new pod for a Machine gives the Node a new boot ID, which is the signal that the reboot workflow waits for.
I did not set the annotation on the Machine by hand. That is a write on an object of NVKE, and the brief approves no such step.

## 7. Step 5, point 7: delete through the NVKE API

`run.sh delete`: one `DELETE /api/clusters/<id>`, then one look each 10 s. Done for the cluster of run 1 and for the second cluster.

| Fact | Run 1 | Run 2 |
|---|---|---|
| Teardown workflow of the cluster | completed, 24.3 s | completed, 24.4 s |
| Row gone after the DELETE | 34.9 s | 34.9 s |
| With the operator procedure (block D, T4) | 129 s | 129 s |

- Each node workflow: `KubeadmReset` (4.6 s), `DeleteCAPIMachineForNode`, `DeleteNode`. The provider deleted the pod, the two claims and the Secret copy of each Machine, waited until they were gone (about 3 s) and logged "Deleted the objects of the machine and released its address".
- Left: no cluster row, no node row, no pod, no claim, no Secret in `d`, no `PodVMMachine`, no `PodVMCluster`, no Machine, no Cluster, no other object with the cluster name in `nvke-system`, no SPIRE entry.
- Stay: the namespace `d`, the network attachment, the Service `cp-api` (with no endpoint).
- Volumes: the six volumes of the cluster are `Released` and keep their claim reference and their data (ext4 with the labels `podvm-var` and `podvm-etcd`). The six spare volumes are `Available`. A new claim cannot bind a Released volume, so the lab script must make them again. With a storage driver the claim delete would delete the volume.

## 8. Step 5, point 8: run 3 with the same name

After the delete of the second cluster and a `storage.sh reset`, the same request made the cluster again (`run-3`). It is up.

- 3 pods 36.1 s after the POST, provisioned 253.7 s, three provisioned nodes 347.7 s, three Ready nodes 358.6 s.
- The addresses are `.1`, `.2`, `.3` again, with new node names. So the delete freed the addresses and the cluster name.
- Pass rule, endpoint rules, 30 of 30 calls from each guest, etcd rule, provider rule: pass.
- Not passed at the first try (23:51 UTC): the names check (one call of `kubectl` was refused) and the pod traffic measurement (the shared address refused the calls of `kubectl`). Cause: the disk of the machine.
- Second try at 00:15 UTC, with the disk still slow (3.5 ms for each write): names check pass, pod traffic 6 of 6, name lookup 3 of 3, `ovnkube-node` 5/5 on each node, tunnels on the fixed addresses.
- State at the end (00:16 UTC): NVKE reports provisioned and three nodes with all conditions. The pods still lose Ready at times (last changes 00:12 to 00:14).

The disk of the machine (`logs/p2s4/disk/`, `run-3/disk/`):

- From about 23:45 UTC a write on the virtual disk `vda` took 8 to 30 ms, at 100 to 150 writes each second and less than 1 MB each second. The sysstat record of the machine has 0.43 ms for the same load in the hours before, 12.8 ms for 23:50 to 00:00, and one more slow time from 21:30 to 22:00 UTC, when the lab was idle.
- The etcd of the lab cluster itself, which is on that disk and in no pod of this test, had a WAL fsync time of 171 ms in a sample of 20 s, against 4.1 ms over its life.
- In the guests of run 3 the WAL fsync mean was 70 to 144 ms. etcd logged "leader failed to send out heartbeat on time" and "apply request took too long". `/readyz` of an API server answered in 2 to 4 s or with 500.
- The readiness probe of the pods has a time limit of 1 s and a failure threshold of 1. So the three pods lost Ready again and again, at times all three at once. Then the Service had no endpoint and the shared address refused connections.
- The etcd logs of block D, T4, run 1 and run 2 have 0 to 3 such warnings. Run 3 has 48 to 113 for each node at the time of the first record.
- I found no process of the lab that writes much (0.4 to 0.8 MB each second for the whole machine). So the cause is below the machine (deduction, not verified).

I wanted to delete run 3 through the API to see if the disk comes back, and to make it again. The permission system refused that command, because the brief says to leave run 3 up. I did not look for another way.

## 9. Differences between the pod of the provider and the T4 pod

| Point | T4 pod (my script) | Pod of the provider |
|---|---|---|
| Secret copy | `<machine>-bootstrap-data`, whole Secret mounted | `<machine>-bootstrap`, only the key `value` (`items`) |
| Startup probe | none | TCP 15005, each 2 s, failure threshold 600 |
| Ready state | when `/readyz` answers | when the agent answers and `/readyz` answers |
| Grace period | 20 s | 30 s (default of Kubernetes) |
| Pull policy | default (`IfNotPresent`) | `Never` (from the template) |
| Image name | `nvke-node-podvm:bcc4376f-p2` | `docker.io/library/nvke-node-podvm:bcc4376f-p2` |
| Resources | limits only | limits and requests, equal |
| Placement | by the node affinity of the volumes | required node rule from the failure domain of the Machine (label key of the cluster, or host name), and a preferred rule against pods of the same cluster on one host node |
| Labels | cluster name, control plane, machine name | the same three, and three owner labels (name, namespace, UID of the `PodVMMachine`), also on the claims and the Secret copy |
| Claims | bound by a claim reference on the volume | no claim reference, class with `WaitForFirstConsumer` |
| Address | from the inventory of the request (`.21` to `.23`) | lowest free address of the range (`.1` to `.3`) |
| Provider ID of the Node | `provisioned://kata-cp1/<address>` | `podvm://d/<pod>` |

The same: name, namespace form, one container `node`, privileged, no command, no arguments, class, the two device paths, the mount path, the three variables, the network annotation form, the hardware address rule, the readiness probe values, no token, no service links, no `tty`.
The node image needed no change for the pod of the provider.

## 10. Findings for the provider and for NVKE (no failure of a pass rule)

1. API server warning at each `PodVMMachine`: the finalizer `podvmmachine.infrastructure.cluster.x-k8s.io` has no path ("prefer a domain-qualified finalizer name including a path"). `controllers/machine_controller.go:53`.
2. During a cluster delete the provider logs "Reconciler error ... failed to get tenant Node ... connection refused" (2 lines in run 1, 9 in run 2). `KubeadmReset` stops the API servers before the `PodVMMachine` has its delete time, and the look at the Node returns an error (`controllers/machine_controller.go:597`). The delete went on at once.
3. The startup probe holds back the Ready state of the pod. After a new pod the API server of the node is behind the shared Service 16 to 22 s later than in T4 (53 to 59 s after the new pod, against 37 s).
4. The grace period is not set. A control plane node does not stop by itself in that time, so a lost pod costs the whole 30 s.
5. The readiness probe (time limit 1 s, failure threshold 1, from the lab pod) takes a pod out of the Service at one slow answer. With a slow disk all three pods can be out at once (section 8).
6. NVKE: the reboot request is not allowed for control plane nodes (section 6).
7. NVKE: after a new pod, `nodeAgentReady` stays not True for 140 to 180 s, as in T4. The agent listens about 50 s after the new pod.

## 11. Failures and their causes

1. Run 1, `RESULT provider final: FAIL`: one rule of my check compared the cluster name label with a wrong variable (a name clash in my `jq` program). Fixed, and the check passed for the same objects. The pods were right.
2. `RESULT endpoint after-lost-other: FAIL` and `after-lost-first: FAIL`: one rule of the block D check counts the join commands in the agent journal of this boot and wants two. A new pod has a new journal, so only one is left. The other endpoint rules pass. It is a limit of the check.
3. Run 3, `RESULT names: FAIL` and no traffic file at the first try: refused calls on the shared address while the disk of the machine was slow (section 8). Both passed at the second try.
4. My first form of the address check printed its own text in place of the answers (a quoting fault). Fixed before run 1.
5. One command of mine (delete of run 3) was refused by the permission system (section 8).

## 12. Not tested

- The reboot answer of the provider (NVKE gave no request). The annotation by hand on a Machine.
- A new Machine made by NVKE (replace, scale up, recycle, rollout) and the use of the spare volumes.
- A worker Machine. Two clusters at the same time and the range overlap rule. A full range.
- A pod that cannot be scheduled (no free volume, no host node). The loss of a host node.
- The startup probe after 20 minutes with no answer. A restart of the provider manager or a change of the leader during a flow.
- A run with a healthy disk after 23:45 UTC. Run 3 with a healthy disk.
- The delete of a cluster during its provisioning.
- A storage driver in the place of the lab volumes.

## 13. Changes on the machine and how to remove them

All under `/root/kata-cp` or in the lab cluster `kata-bb`. No firewall rule, no listener on an outside interface, no change of the Docker or containerd configuration or of the network settings, no restart, no database write, no Temporal change.

| Change | Removal |
|---|---|
| Cluster `kata-cp1` of run 3 in NVKE (ID `b854c3bd-26eb-4e40-9310-b2c50c560a39`), 3 pods, 6 claims and 3 Secret copies of the provider in `d`. It stays up | `LOG_DIR=/root/kata-cp/logs/p2s4/run-3 p2-provider/run.sh delete` (one DELETE through the NVKE API) |
| Namespace `d` with the network attachment `nodenet` and the Service `cp-api` | `kubectl delete namespace d`, after the cluster delete |
| Storage class `podvm-local-block` and 12 volumes `podvm-loop60` to `podvm-loop71` | `p2-provider/storage.sh reset` after a cluster delete, `p2-provider/storage.sh down` to remove them |
| Provider: namespace `podvm-system`, three CRDs, RBAC, Deployment, and `ClusterRole` and `ClusterRoleBinding` `nvke-controller-podvm` | `kubectl delete -f` of `p2-provider/install/nvke-controller-rbac.yaml` and `infrastructure-components.yaml` |
| Provider image in the four kind nodes, archive `dl/img/cluster-api-provider-podvm_cdc368ea.tar` (30 MB) | `ctr -n k8s.io images rm` in each node, `unlink` of the archive |
| T4 cluster and its namespace `p2c`: gone (approved operator delete) | Nothing to do |
| The clusters of run 1 and run 2: gone (delete through the API) | Nothing to do |
| Folders `p2-provider`, `logs/p2s4`, `secrets/d-run-1`, `d-run-2`, `d-run-3` (mode 700) | Remove the folders |
| Workstation: `/scratch/kata-cp/tmp/p2s4/cluster-api-provider-podvm_cdc368ea.tar` (30 MB, from `docker save`), scripts, logs, this file | `unlink` of the archive |
