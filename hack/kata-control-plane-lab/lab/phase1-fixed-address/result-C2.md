# Block C2: the control plane on fixed addresses, with stock etcd settings (second machine)

Date: 2026-11-26, 17:34 to 17:53 UTC, on the second test machine. Kata runs with nested virtualization there, so times do not compare with the workstation. Two other tests ran on the machine at the same time (the C1 variants and a first C3 try), so the times are an upper limit. Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/gate4/c2-run-1/`, `c2-run-1.out`, `c2-run-1-rest.out`. Scripts: `/scratch/kata-cp/work/bigbox/remote/gate4/` (`run.sh` with `FIXED=1`), `remote/bin/c2.sh`, `c2-rest.sh`.

## Verdict

Pass, 1 run. Three replicas (kind node image, kubeadm by hand, class `kata-clh-runtime-rs-fix-direct`) on three host nodes, each with a fixed address on the node network as its node address.

| Pass rule | Result |
|---|---|
| Three started etcd members | Pass. Peer URLs `https://172.28.1.11:2380`, `.12`, `.13`. No learner. Three healthy endpoints |
| 0 lines "rejected connection on peer endpoint" | Pass. 0 on each member, after the joins, after the replaces, after each move and after the host loss |
| Three Ready nodes | Pass. `cp-a`, `cp-b`, `cp-c` Ready with the InternalIP `172.28.1.11` to `.13` (kindnet of the kind image as the CNI of the inner cluster) |
| Replace of a follower | Pass. `/readyz` on its address 51.0 s after the delete, three healthy endpoints 51.3 s |
| Replace of the leader | Pass. `/readyz` 41.9 s, three healthy endpoints 42.2 s. The leader moved from `cp-a` to `cp-b` |
| Replace that moves the pod to another host node | Pass, 3 moves (cordon and delete). `/readyz` 41.9 to 45.3 s after the delete, three healthy endpoints 42.3 to 45.7 s |
| Loss of one host node | Pass with one operator step. Three healthy members 30.0 s after the step (110.6 s after the stop) |

What was NOT in the cluster: no etcd patch file, no `peer-skip-client-san-verification`, no listen change, no address on a guest bridge, no LoadBalancer Service, no MetalLB in the path.

- etcd flags are the kubeadm defaults: `--listen-client-urls=https://127.0.0.1:2379,https://172.28.1.11:2379`, `--listen-peer-urls=https://172.28.1.11:2380`. Sockets: `127.0.0.1:2379`, `172.28.1.11:2379`, `172.28.1.11:2380`.
- The endpoint (`controlPlaneEndpoint`) is the address of the first node, `172.28.1.11:6443`, as in the dry run.
- A call from one replica to another has the fixed address as its local address (`reach` step: `local address 172.28.1.11` for calls to `.12` and `.13`).
- Also pass in the same run: steps 3 and 6 of gate 4, the bare Pod replace (47.1 s), a restart in place (42.7 s).

## Numbers (seconds)

- `kubeadm init` 16.2. Join of b 39.3, join of c 39.3.
- Follower replace: old pod gone 21.5, new pod runs 33.8, `/readyz` 51.0, three healthy endpoints 51.3. New pod create to `/readyz` 29.5 (block B: 18.8 to 21.0). This run had no fixed hardware address, so the peers and the node of the caller held a stale neighbor entry (C1). The C3 runs use the fixed hardware address.
- Leader replace (the leader was `cp-a`, which is also the endpoint): `/readyz` 41.9. The endpoint did not answer for 40.8 s (15 of 16 calls). With no shared address the endpoint is down while the first node is replaced.
- Calls to the address of the first node during the follower replace and the bare Pod replace: 0 of 98 failed.

## The move to another host node, and the volumes

- The local volumes of block B pin a pod to one host node (node affinity of each PersistentVolume). With them a pod cannot move. That stays true for a site with local disks.
- What the lab can give: each sparse file of the machine is a loop device that is present in each kind node. So for C2 the two PersistentVolumes of a replica name all three workers in their node affinity (`PV_NODES=all`). This imitates a network block volume that follows the pod. The pod template prefers the home node of the replica and prefers a node with no other replica.
- Move test (`run.sh move`): cordon the host node, delete the pod. The StatefulSet makes the pod again, and the scheduler puts it on another worker. Result in 3 of 3 moves: the fixed address is the same (`172.28.1.13/16` on `net1`), the kubelet of the new node attaches the same two devices, the etcd member list and all certificates are the same, only the pod IP and the boot ID differ.
- Not tested: a real network volume, and the fencing that it needs. In the lab nothing stops two nodes from opening the same device. The tests are safe only because the old guest is gone before the new one starts.

## Loss of one host node

`run.sh host-move follower 75`: `docker stop kata-bb-worker3` (replica c, a follower), the node stays down.

| Event | Seconds after the stop |
|---|---|
| Node `NotReady` | 48.3 |
| State with no step by hand, at 75 s | Node `NotReady`, pod `cp-c-0` still listed as Running on it, 2 of 3 etcd endpoints healthy, quorum stays |
| Operator step: `kubectl taint nodes kata-bb-worker3 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` | 80.7 |
| Old pod object gone | 95.5 (14.8 after the step) |
| New pod runs on `kata-bb-worker2` | 101.1 (20.4 after the step) |
| Three healthy etcd endpoints | 110.6 (30.0 after the step) |
| `/readyz` on `172.28.1.13` | 115.7 (35.0 after the step) |

- Calls to the two other replicas and to the endpoint during the whole time: 0 of 217 failed.
- The moved replica has the same fixed address, the same etcd member ID and the same certificates. 0 refused peer connections.
- After `docker start` the node is Ready again, the taint is removed, and the old node has no sandbox of the namespace.
- Without the operator step nothing moves the pod. Block B shows that case: the pod object goes to Terminating after about 350 s and stays until the node returns.
- The return of the same node with no move (as in B5) was not run again for C2.

## What failed, and why

- First start of the run: `kubeadm init` passed, then `172.28.1.11:6443` did not answer from any node. Cause: the stand-in pods of the C1 variant run had the same addresses at that time. Fault of the test order. Fixed by other addresses for the C1 test.
- The first `full` stopped in its check after the joins with exit code 1. Cause: a new check line used `grep -c`, which ends with code 1 for the count 0, under `set -e`. Fault of the script. The rest of the run (`run.sh rest`) ran on the same cluster after the fix.

## What a site needs for this design

- The fixed interface of C1 for each control plane pod, with a fixed hardware address.
- A shared endpoint in front of the three nodes if the first node must be replaceable with no API gap. The lab has none in block C.
- For a move after a host loss: a volume that can attach on another host, a fence for the old host, and a trigger (the out-of-service taint or a delete of the pod object). NVKE has no such trigger today.

## State after C2

The cluster stays in the namespace `c2` (three StatefulSets, `cp-c` now on `kata-bb-worker2` after the host loss test). Remove: `FIXED=1 PV_NODES=all NS=c2 /root/kata-cp/gate4/run.sh down` with the settings of `bin/env-gate4.sh`.
