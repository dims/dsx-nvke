# Gate 4, design choice: the etcd peer check with a DNS name

Date: 2026-11-26, 00:26 to 07:20 local time. The main session ran the tests. Raw output: `/scratch/kata-cp/logs/gate4/dns-run-1` to `dns-run-4`, with the files `dns-run-*.out`, `dns-run-2-dns-outage.out` and `dns-run-2-outage.out`. The machine restart test with this option ran in the Lima VM on 2026-11-26 from 07:21 to 07:36 (records in `/scratch/kata-cp/logs/vm-restart/runs/dns-*`).

## The question

The gate 4 design needs the etcd flag `peer-skip-client-san-verification=true` (`report.md`, part 3). etcd compares the source address of a call from a peer with the names in the certificate of that peer. A call to a LoadBalancer IP arrives with another source address, so the check fails. Davanum asked for a test of the option that keeps the check, before the design is final.

## The option

- One headless Service `cp-peer` selects all replicas of the cluster and also publishes a replica that is not ready.
- kubeadm puts the DNS name of that Service in each etcd peer certificate (`etcd.local.peerCertSANs` in the ClusterConfiguration). A replica that joins later gets the same name, so the list does not change with the number of replicas.
- The Service of each replica has `externalTrafficPolicy: Local`. A call from another pod then arrives with the pod IP of the caller as its source. With the policy `Cluster` the source is an address of the host node, and no name can match.
- etcd has no skip flag. It still listens on `0.0.0.0`.

Why it works, from the etcd source (`client/pkg/v3@v3.6.8/transport/listener_tls.go`, `checkCertSAN` and `isHostInDNS`): for a DNS name in the certificate, etcd asks the DNS for the name and accepts the peer when the source address is in the answer. The headless Service gives the pod IPs of the replicas.

In `run.sh`: `ETCD_PEER_DNS=1 ETCD_SAN_SKIP=0 ETP=Local`. The tests ran as a second cluster next to the first one (`INSTANCE=2`: namespace `gate4b`, addresses `172.30.255.220` to `.223`, six other loop devices), with `RUNTIME_CLASS=kata-clh-runtime-rs-fix-direct G1_SKIP=init-cgroup STOP_TIMEOUT=` and `CPU=2`.

## Results

| Test | Result | Runs |
|---|---|---|
| Join of three replicas, checks of steps 3 and 6 | Pass | 3 of 3 (runs 2, 3, 4) |
| Replace of a follower, of the leader and of a bare Pod | Pass | 9 of 9 |
| Restart of a container in place | Pass | 1 of 1 |
| All three pods deleted at the same time | Pass | 1 of 1 |
| Machine restart in the Lima VM: three clean restarts, two power loss runs | Pass, no manual step | 5 of 5 |
| The DNS of the host cluster is down, no other change | The cluster stays healthy | 1 run, 60 s and then 13 minutes |
| The DNS of the host cluster is down, one replica gets a new pod | The member does not return until the DNS is back | 1 run |

Run 1 is not valid. The kind node had 92 percent of its 24 CPUs requested by two clusters with 4 CPUs for each replica, so the third replica got no place. The later runs use 2 CPUs for each replica of the second cluster.

Evidence of the check (`dns-run-2/peercheck-after-join.txt`):

- The etcd manifest has `--peer-client-cert-auth=true`, `--listen-peer-urls=https://0.0.0.0:2380` and no skip flag.
- The peer certificate of each replica: `DNS:cp-a, DNS:cp-peer.gate4b.svc.cluster.local, DNS:localhost, IP Address:172.30.255.221, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1`.
- In each guest the name gives the three pod IPs (`10.244.0.92 10.244.0.93 10.244.0.94`). The resolver of the guest is the DNS of the host cluster (`nameserver 10.96.0.10`), with the search list of the pod and `ndots:5`.
- The etcd logs have 0 lines "rejected connection on peer endpoint" in the three runs, after 9 new pods and one container restart.

Times, against the design with the skip flag:

| Event | With the DNS name | With the skip flag |
|---|---|---|
| Join of a replica | 8.4 to 27.1 s (6 joins) | 8.5 to 22.3 s (`run-1` to `run-3`) |
| Pod delete to `/readyz` of the replaced replica (StatefulSet) | 28.4 to 30.0 s (6 replaces) | About 28 s with the same class |
| All three pods deleted: first etcd call with quorum | 35.0 s | 27.7 s |
| All three pods deleted: three healthy etcd endpoints | 40.9 s | 33.0 s |

- The join time has two groups (about 9 s and about 22 s) in both designs, so the option is not the cause.
- The run with all three pods deleted is one run for each design. The difference of 7 s is not proven as an effect of the option.

## The cost: etcd needs the DNS of the host cluster

The step `dns-outage` set CoreDNS of the host cluster to 0 replicas (`dns-run-2/dns-outage-dns-outage-follower.txt`):

- 60 s with no DNS and no other change: 3 of 3 etcd endpoints healthy.
- Then replica c got a new pod. Its etcd member did not return in 747 s. The two other members kept quorum. The loops had 0 failed calls of 844 on the shared address and 0 of 731 on replicas a and b. The leader and the raft term did not change.
- In that time etcd rejected each new peer connection: 118 lines on cp-a and 82 on cp-b. cp-a also rejected a call from cp-b, which was healthy. Error text: `tls: "10.244.0.93" does not match any of DNSNames ["cp-b" "cp-peer.gate4b.svc.cluster.local" "localhost"] (lookup cp-peer.gate4b.svc.cluster.local on 10.96.0.10:53: ... i/o timeout)`.
- So the two healthy members stayed connected only through the connections that they had before the DNS stopped.
- With CoreDNS back: three healthy etcd endpoints after 4.7 s, and `/readyz` of replica c after 7.3 s. Only the pod IP and the boot ID of replica c differ.

Meaning:

- An outage of the DNS of the host cluster does not stop a healthy tenant cluster by itself.
- During the outage no member can return after a new pod or a restart, and a connection between two members that breaks stays broken. Two such events at one time cost the quorum until the DNS is back.
- After a start of all replicas at one time (a cold start), etcd cannot form a quorum before that DNS answers with the new pod IPs. The section below has the numbers.
- Each new peer connection costs DNS questions. With `ndots:5` the resolver first asks for the name with each search domain of the pod. One of those domains is the search domain of the machine, so that question goes to the upstream resolver of the host cluster. A short name (`cp-peer`) or a wildcard name in the certificate avoids those questions. Not tested.

## Machine restart in the VM

The VM of `report-vm-restart.md`, with the cluster made again with this option and with the packet filter on. A detached driver on the host ran the five restarts (`vm-restart/drive-dns.sh`). Times are seconds after the kernel boot of the VM. Kata runs with nested virtualization there.

| Event | Clean 1 | Clean 2 | Clean 3 | Power 1 | Power 2 |
|---|---|---|---|---|---|
| API server of the host cluster | 12.3 | 10.3 | 11.2 | 12.1 | 11.7 |
| Containers of the three replicas run | 15.4 | 13.0 | 12.5 | 14.8 | 14.8 |
| CoreDNS pods of the host cluster ready | 18.8 | 34.2 | 33.6 | 51.5 | 33.5 |
| etcd quorum of the inner cluster | 32.0 | 32.6 | 32.1 | 44.9 | 30.9 |
| Three healthy etcd endpoints | 32.6 | 33.2 | 32.6 | 45.1 | 32.4 |
| `/readyz` through the shared address | 35.8 | 38.5 | 36.3 | 53.5 | 34.7 |
| All pods of the host cluster ready | 40.9 | 40.5 | 40.9 | 56.7 | 39.7 |

- All five restarts return with no manual step. For each replica only the pod IP and the boot ID changed.
- With the skip flag and the same filter, the quorum came after 31.6 s (clean) and 27.2 s (power loss). In the eight runs before the filter it came after 16.8 to 33.9 s, and five of them had it before 19 s.
- With the DNS name the quorum never came before 30.9 s. In four of the five boots etcd logged 414 to 617 lines "rejected connection on peer endpoint" on most replicas before the quorum.
- While the two CoreDNS pods started, the DNS first gave no answer, or an answer with three addresses that were the pod IPs of the boot before. etcd accepts a peer only when the DNS has the new pod IPs.
- So the DNS name adds a wait for the DNS of the host cluster after a machine restart. In this VM that is 10 to 15 s against the fast runs with the skip flag.
- A fault of the test: the helper that asked the DNS in the VM did not print the addresses of an answer, only their count. Its bash form with a UDP socket also caused the Defender detections on the host (`defender-detections-2026-11-26.md`), and it is deleted. A later test must use `dig` or a small program.

## The two designs side by side

| Point | Skip flag | DNS name |
|---|---|---|
| etcd peer check | TLS with the etcd CA. etcd does not compare the source address | TLS with the etcd CA, and the source address must be a pod IP of the headless Service |
| New objects | None | One headless Service for each tenant cluster |
| NVKE change | One etcd argument (its name depends on the etcd version) | `peerCertSANs` in the kubeadm config, the headless Service, `externalTrafficPolicy: Local` |
| Dependency of tenant etcd | None on the host cluster DNS | The DNS of the host cluster, at each new peer connection |
| Needs from the network | Nothing more | The source address of a pod must reach the other pod with no change (no masquerade between pods, and a kube-proxy that keeps it for the policy `Local`) |
| Tested | 3 full runs, 3 cold starts, 10 machine restarts in a VM | 3 full runs, 1 run with all pods deleted, 1 DNS outage, 5 machine restarts in a VM |
| etcd quorum after a machine restart in the VM | 16.8 to 33.9 s | 30.9 to 44.9 s |

Davanum chose the skip flag for the design on 2026-11-26.

A third way needs neither: a fixed pod IP from the CNI. The lab cannot test it (`evidence.md`, question 3).

## Not tested

- A host cluster with more than one node. The source address of a call between pods on two nodes depends on the CNI.
- A cold start of the kind node on the lab host with this option (the four approved runs are used).
- A short name or a wildcard name in the certificate.
- The stock class `kata-clh-runtime-rs` with this option.

## Faults of the test

- Run 1: no CPU left for the third replica (above).
- The first count of rejected connections was wrong. The pattern also matched lines for the client endpoint ("connection reset by peer"). `run.sh` now counts only "rejected connection on peer endpoint".
- The step `dns-outage` waits 120 tries, not 120 seconds. Each try takes up to 6 s while a member is down, so the wait was 747 s.
- `run.sh full` with `KEEP=0` ends with exit code 2 after all results are printed. The last summary command looks for a result file of the restart step, which only a run with `KEEP=1` makes.
