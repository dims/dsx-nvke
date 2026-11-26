# Gate 4, step 5: cold start (not run), and gate 4 with the fix-direct class

Date 2026-11-26, about 00:45 UTC. Kind node `kata-cp-control-plane`. The agent that ran the tests wrote this report, and the main session saved it.

## Main point

No cold start ran: 0 of 3 runs with the stock class, and 0 of 1 with the fix-direct class. The permission system denied the command `cold-start.sh --stop-the-kind-node` (reason: "Destructive or Unwanted Actions"). The command did not run, and the kind node is as before (started 2026-11-25T20:50:32Z, restart count 0). The agent did not try the stop in another way. Davanum must approve the stop.

Done: the unit install, steps 3, 4 and 6 with the fix-direct class (all pass), the SPIRE point, and one extra test (all three pods deleted at the same time, pass). Not done: the cold start runs and the node checks after a real start.

## 1. The unit is installed

Log: `/scratch/kata-cp/logs/gate4/step5/00-unit-install.txt`.

- `docker cp` of `g4-loop-nodes.service` to `/etc/systemd/system/`, `systemctl daemon-reload`, `systemctl enable`. Result: "enabled", a link in `multi-user.target.wants`, and `systemd-analyze verify` with exit code 0. The file has root:root and mode 644.
- The unit did not run yet. It runs at the next start of the node, before containerd and the kubelet.
- D-Bus at boot, by reading only: the package dbus 1.16.2 is installed, `dbus.socket` is a dependency of `sockets.target`, and both units are active now. The real check needs the stop.
- Removal: `docker exec kata-cp-control-plane systemctl disable g4-loop-nodes.service`, then `rm /etc/systemd/system/g4-loop-nodes.service` in the node.

## 2. The script is ready

- `cold-start.sh` now also records: the pod UID, pod IP and restart count before and after, the sandboxes and containers in crictl, the Kata processes, the loop devices of the kubelet before the stop, on the host during the stop and after the start with their backing file, the containerd and kubelet journals of the new boot, the events, and the time until all pods of the host cluster are ready.
- Node checks after a start, each with OK or FAIL: the address 172.30.0.2, 128 loop device nodes, D-Bus, the runtime handlers compared with the list before the stop, MetalLB (the ServiceL2Status objects, and one ping from the host to each of the four addresses with a check of the neighbor entry, no TCP), `docker port` with 127.0.0.1 only, the SPIRE server pod, and all pods of the host cluster.
- If the API server of the host cluster does not answer 600 s after the start, the script saves `docker logs --tail 100` and `docker inspect`, prints FAIL and stops. It runs no other Docker command.
- Dry runs (all steps but the stop and the start) pass on the stock cluster and on the fix-direct cluster (`step5/dry-run-2`, `step5/dry-run-3-fix-direct`). On the live node all checks give OK: 10 runtime handlers with the four of `/opt/kata-fix`, four MetalLB addresses reachable, `6443/tcp -> 127.0.0.1:38147`, `spire-server-0` 1/1 Running, 17 of 17 pods ready.
- One fact for the test: each loop device of the kubelet has the path `.../volumeDevices/<volume>/<pod UID>` as its backing file. A node restart keeps the pod UID, so the kubelet can find the old loop device again by that path. If it does not, it makes six new ones, and the old ones stay attached in the host kernel.

## 3. Steps 3, 4 and 6 with `kata-clh-runtime-rs-fix-direct`

One run, `step5/fix-direct-run-1`, exit code 0, 8 of 8 `RESULT` lines with PASS.

- Settings: no `init` cgroup step (`G1_SKIP=init-cgroup`), no systemd stop timeout (the node has the default of 90 s), a grace period of 20 s, and all other settings as before. The pod has 6Gi plus 512Mi of overhead (`memory.max` 6979321856).
- Step 3 passes two times: three started members with the LoadBalancer addresses, three healthy endpoints, `/readyz` 200 on .210 to .213, and the node addresses .211 to .213. Step 6 passes two times. The preflight has no warning (exit code 0). `kubectl exec` works with no `init` cgroup, and each check uses it.
- Step 4 passes for the follower, the leader and the bare Pod: a new pod IP, 0 lines "regenerating the certificate", and an identity difference only in the pod IP and the boot ID. The leader moved from cp-a to cp-b.
- Direct I/O is on: cloud-hypervisor has `/dev/loop22` and `/dev/loop26` open with the flags 02140002. `oom_kill` is 0. The pod cgroup has 1.3 to 2.1 GiB.

| Number (seconds) | Stock class, stop timeout 10 s (3 runs) | fix-direct, no stop timeout (1 run) |
|---|---|---|
| `kubeadm init` | 8.1 to 8.9 | 8.0 |
| Join of B, join of C | 22.0 to 22.3, 8.5 to 22.0 | 21.4, 8.6 |
| Pod delete until the pod is gone | 11.0 to 11.9 | 21.0 to 21.5 |
| Follower replace, delete to `/readyz` | 19.9 to 20.2 | 28.7 |
| Leader replace, delete to `/readyz` | 18.4 to 20.5 | 28.3 |
| Bare Pod, delete to `/readyz` (with a 5 s wait of the script) | 23.2 to 23.4 | 34.2 |
| New pod create to `/readyz` | 7.4 to 8.7 | 7.4 and 7.5 |
| Container stop in place | 11.2 to the new container (power-off, exit code 130) | `crictl stop --timeout 20` returns after 20.2, exit code 137, new container 21.4, `/readyz` 26.6, no identity difference |
| Failed calls of the shared address in the replaces | 3 of 193 | 0 of 96 |

- What differs, and why: each delete and each stop takes the grace period of 20 s, not 11 s. With no stop timeout, systemd in the node waits 90 s for kube-apiserver, which does not exit while etcd is down. The grace period ends first, and the runtime kills the container. That kill now works (exit code 137; with stock Kata the stop took 91 s). So the replace is about 8 s slower than with the stock class and the 10 s timeout. etcd still gets its stop signal at the start. A shorter grace period, or the stop timeout together with the fix, makes it faster. Not tested.
- Over the whole run the shared address had 2 failed calls of 243, both "500" from an API server in shutdown: one 1.1 s after the `crictl stop` (the pod stays an endpoint until its probe fails), and one in the owner change.

## 4. Extra test: all three pods deleted at the same time

Fix-direct cluster, one run, `step5/fix-direct-outage-1`, pass. It is not a cold start.

- `kubectl delete pod cp-a-0 cp-b-0 cp-c-0`. etcd loses quorum, and each replica returns with a new pod IP.
- Seconds after the delete: old pods gone 21.9, three new pods running 25.3, first etcdctl call with quorum 27.7, `/readyz` of each replica 30.3, `/readyz` of the shared address 31.6, three healthy etcd endpoints 33.0. From new pods to all API servers is about 8 s.
- The etcd member IDs and the checksums of all certificates are the same on all three replicas. 0 lines "regenerating the certificate". Steps 3 and 6 pass after it.
- It shows that the inner cluster returns with no manual step when all pod IPs change at the same time. It does not test the host side: the kubelet, containerd, the dead sandboxes, the loop devices, the unit, D-Bus and MetalLB after a start. The stop is also clean for etcd here, and a cold start kills the guests.

## 5. The SPIRE point (reading only)

- The note in `lab/gate1-nvke/report.md` says: a node whose pod is absent for longer than the life of its agent identity cannot get its identity back, because the join token is used. Port 15005 of `nvke-agent` stays closed.
- For a cold start of more than one hour (the SPIRE default life): etcd and the API servers return, because kubeadm certificates do not use SPIRE. But NVKE can reach no control plane node until each node gets a new join token and its `spire-agent` starts again. If the SPIRE server stops with the same host, the limit can be shorter than one hour, because no agent can renew during the outage. That last sentence is a reading and is not tested.

## 6. State after the work

- Up and healthy: the namespace `gate4` with the class `kata-clh-runtime-rs-fix-direct`. StatefulSets cp-a, cp-b and cp-c, pods 1/1 with 0 restarts, no `init` cgroup step, no stop timeout, the four Services on .210 to .213, 6 claims and 6 PersistentVolumes. The limits are 3 times 6Gi plus 512Mi.
- The stock cluster is removed. It comes back in about 90 s with the steps below.
- Kind node: the unit is installed and enabled. Nothing else changed there.
- `/scratch/kata-cp/gate4-secrets` has the bootstrap token (2 h) and the certificate key of the cluster that is up. No secret is in the notes or in this report.
- Changed files in `~/notes/hosted/lab/gate4`: `cold-start.sh`, `run.sh` (new steps `restart` and `outage`, variables `G1_SKIP` and `KEEP`), `podspec.inc`. `report.md` describes the older `cold-start.sh`.
- Logs: `/scratch/kata-cp/logs/gate4/step5/`.
- Remove the cluster: `LOG_DIR=/scratch/kata-cp/logs/gate4/step5/fix-direct-run-1 ~/notes/hosted/lab/gate4/run.sh down`, then the same with `wipe`.

## How to continue, when Davanum approves the stop

- Cold start of the cluster that is up (fix-direct): `LOG_DIR=/scratch/kata-cp/logs/gate4/step5/cold-start-fix-direct-1 ~/notes/hosted/lab/gate4/cold-start.sh --stop-the-kind-node`. One run needs about 5 minutes.
- Stock cluster for three runs: in `~/notes/hosted/lab/gate4`, with one `LOG_DIR` for all steps: `run.sh down`, `wipe`, `services`, `node-up a`, `init`, `node-up b`, `join b`, `node-up c`, `join c`. The defaults are the stock class with the `init` cgroup and the 10 s stop timeout. Then run `cold-start.sh` three times, each with its own `LOG_DIR`.
- One risk for `run.sh wipe` after a cold start: it waits until no loop device of gate4 is attached. If old loop devices stay in the host kernel, the wipe stops with an error, and somebody must detach them first.
