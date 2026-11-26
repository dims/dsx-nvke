# Gate 3, paths 2 and 3: host socket and service account token

Date: 2026-11-26, 04:25 to 05:24 UTC. A test agent ran the work and returned this report as text. The main session wrote the file.

Lab: one kind node (`kata-cp-control-plane`), Kubernetes v1.36.4, containerd 2.3.4, host kernel 7.0.0-44. Kata 4.4.0 with Cloud Hypervisor, guest kernel 6.18.62. SPIRE server and agent 1.14.1, SPIFFE CSI driver 0.2.7, node driver registrar v2.15.0. These are the versions that NVKE pins in `cli/internal/bootstrap/manifest/bootstrap-manifest.yaml`, lines 83 to 86. `nvke-agent` v0.24.0-beta.18, NVKE commit `bcc4376f`. The SPIRE server of the test had the trust domain `gate3.lab.test`.

Short answer:

- The host socket path fails with both Cloud Hypervisor classes. `connect()` returns ECONNREFUSED in the guest. Kata issue 8024 is true here.
- The service account token path (the SPIRE node attestor `k8s_psat`) works in the Kata guest, and `nvke-agent` completed authenticated calls on that identity.
- The service account token path has one hard limit. The agent ID comes from the host node, so two such pods on one host node share one identity.

Path 1 (join token) is in `lab/gate1-nvke/report.md`.

## 1. Verdict table

Path 2, host socket. "Folder" means that the volume is the socket folder.

| RuntimeClass | hostPath folder | SPIFFE CSI driver | Runs |
|---|---|---|---|
| runc (baseline) | Pass. 2 SVIDs (`workload/unix-uid-0`, `workload/k8s-pod`) | Pass, the same 2 SVIDs | 3 and 3 |
| `kata-clh-runtime-rs-fix-direct` (class of record) | Fail | Fail | 4 and 3 |
| `kata-clh` (Go runtime) | Fail | Fail | 3 and 3 |
| `kata-clh-runtime-rs` (stock, for information) | Fail | Fail | 1 and 1 |
| `kata-qemu-runtime-rs` | Not testable, the sandbox does not start | Not testable | 1 pod with 5 sandbox tries, 1 pod with 2 tries |
| `kata-qemu` | Not testable, the sandbox does not start | Not testable | 1 pod with 2 tries, 1 pod with 1 try, 1 plain pod with no volume |

- The error of each failed Cloud Hypervisor run is the same, and no result changed between runs.
  - The probe: `connect /spire-agent-socket/spire-agent.sock: FAILED errno=111 (ECONNREFUSED) "connection refused"`.
  - The SPIRE client: `rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial unix /spire-agent-socket/spire-agent.sock: connect: connection refused"`.
- `kata-qemu-runtime-rs`: `vsock: failed to connect to Vsock { vsock_cid: ..., port: 1024 } within 10s (attempts=21), last_err ... ENODEV: No such device`. QEMU ends in 1 second with no message. Its arguments have `memory-backend-file ... mem-path=/dev/shm,size=544M`.
- `kata-qemu`: `Failed to Check if grpc server is working: rpc error: code = DeadlineExceeded desc = timed out connecting to vsock <cid>:1024`. QEMU writes `error: kvm run failed Bad address`. Its arguments have `memory-backend-file,id=dimm1,size=2048M,mem-path=/dev/shm,share=on`.
- `/dev/shm` of the kind node has 64 MB. A QEMU pod with no volume fails in the same way, so the cause is not the socket. The test did not repair QEMU.
- Extra variant: the hostPath is the socket file (`type: Socket`). runc passes (1 run). Both Cloud Hypervisor classes fail at container create with `agent create container ... Input/output error (os error 5)` (2 of 2 each). The cause in the guest agent is not found.

Path 3, projected service account token.

| Case | Result | Runs |
|---|---|---|
| runc, the agent attests and a workload gets an SVID | Pass | 1 |
| Class of record, attest with empty agent data | Pass | 4 of 4 |
| Class of record, container restart | Pass, `SVID loaded` | 2 of 2 |
| Class of record, new pod on the same data | Pass, `SVID loaded` | 2 of 2 |
| Class of record, absence longer than the life of the agent SVID | Pass, the agent attests again with no manual step | 2 of 2 |
| `kata-clh`: attest, container restart, new pod, empty data | Pass | 2, 1, 2, 1 |
| Real `nvke-agent` on this identity, class of record | Pass | 2 node instances. 6 authenticated calls pass, 1 fails (section 4) |
| Two such pods on one host node | Fail, one shared agent identity | 1 run of 165 s |
| QEMU classes | Not tested | 0 |

## 2. The mechanism of the host socket failure

What the test saw:

- In the Kata guest the folder is a `virtiofs` mount. The file is a socket: `type=socket (S_IFSOCK) mode=777 ... ino=2040`, `f_type=0x65735546` (FUSE). The inode number is the same as on the tmpfs of the host.
- `/proc/net/unix` in the container has 40 lines (the sockets of the guest systemd) and no line with `spire`. The pod uses the network namespace of the guest.
- On the node the shim bind mounts the folder into its shared folder: `.../shared/sandboxes/<id>/rw/passthrough/sandbox-b5abbe2a-gate3-agent-sockets` (mountinfo of the shim). virtiofsd serves `.../ro` (`--shared-dir`).
- A host process that opens the same file through the view of virtiofsd (`/proc/<virtiofsd pid>/root/passthrough/.../spire-agent.sock`) connects: `connect ...: OK`, peer PID 9876, the SPIRE agent. So the file is correct. Only the kernel that handles `connect()` differs.
- Reverse test. A process in the pod binds a socket in a shared hostPath folder. A second process in the guest connects. A process on the node sees `S_IFSOCK` on ext4 and gets `errno=111 (ECONNREFUSED)`. This held in 4 of 4, 3 of 3 and 1 of 1 Kata runs. With runc both sides connect (3 of 3).
- The log of the host SPIRE agent has no line for a call from a Kata pod. The connect never leaves the guest.

What the source says (a deduction):

- Linux v6.18, `net/unix/af_unix.c`, `unix_find_bsd()` (lines 1202 to 1250): `kern_path()` at 1236, `err = -ECONNREFUSED` at 1245, the `S_ISSOCK` test at 1247, then `unix_find_socket_byinode()` at 1250. That function (lines 455 to 472) searches `bsd_socket_buckets`, the table of sockets that were bound in this kernel. The guest kernel has its own table, and the socket was bound in the host kernel. So the guest kernel returns ECONNREFUSED by itself. The reading is of the v6.18 tag, not of the exact 6.18.62 source.
- Kata 4.4.0, Rust runtime: each bind mount that is no device and no system path is a shared volume (`src/runtime-rs/crates/resource/src/volume/share_fs_volume.rs`, lines 931 to 936). With a shared filesystem the runtime calls `share_volume` (line 576), which calls `share_to_guest` (`share_fs/utils.rs`, lines 37 to 60) and makes a bind mount (line 49). No code looks at the file type. With no shared filesystem the runtime copies only regular files and folders and warns `Ignoring non-regular file as FS sharing not supported` (lines 461 to 529).
- Kata 4.4.0, Go runtime: `src/runtime/virtcontainers/container.go` lines 476, 497 and 501 pass each bind mount to `ShareFile`. `fs_share_linux.go` makes a bind mount into the shared folder (lines 438 and 450). The copy path excludes sockets (comment at line 366).
- No code in 4.4.0 forwards a Unix socket. The newer checkout (`kata-containers-main`, commit `0f2fbc4` of 2026-11-25) has 0 matches for `vsock_uds_forward`, so PR 13162 is not merged.

## 3. Which statement is true

- Kata issue 8024 is true in this lab. The issue (open, last update 2026-07-31) reports SPIRE with the SPIFFE CSI driver and the same error text.
- The NVKE text is in `deploy/nico/spire/values.yaml`, lines 70 to 81. The same text is in three more values files.
- The NVKE text covers a different step: how the host agent attests a caller that belongs to a Kata pod. It says that container selectors come back empty and that pod selectors still resolve. It does not say how the connection leaves the VM.
- The test checked that step with a model. A process on the node joined the cgroup of the Kata sandbox (the cgroup of the shim, `.../kubelet-kubepods-burstable-pod<uid>.slice/cri-containerd-<sandbox id>.scope`) and called the host agent.
  - With `disable_container_selectors = true`: `PID attested to have selectors ... k8s:sa:sock-test k8s:ns:gate3 ... k8s:pod-uid:3d0151e1-... k8s:pod-name:... k8s:pod-label:gate3-test:sock`, and the caller got the pod SVID (2 of 2).
  - With `false`: `Timed out collecting selectors for PID`, `Workload attestation failed error="context canceled"`, and the client got `DeadlineExceeded`. No SVID at all, also not the unix one (1 of 1).
- So the NVKE text is correct for a caller on the host side in the pod cgroup. PR 13162 makes such a caller, because the shim opens the connection to the host socket. With stock Kata 4.4.0 and Cloud Hypervisor no connection reaches the agent, and the setting has no effect for a Kata workload. Which Kata build the NVKE authors used is not known.

## 4. Path 3: service account token

Setup:

- The pod has a ServiceAccount and a projected token volume (audience `spire-server`).
- The agent in the pod has `NodeAttestor "k8s_psat"` with `cluster` and `token_path`, the disk key manager and the unix workload attestor.
- A node alias entry selects the agent by `k8s_psat:cluster`, `agent_ns`, `agent_sa` and `agent_pod_name`.
- The host ID entry `spiffe://gate3.lab.test/host/<UUID>` has the alias as parent and the selector `unix:uid:0`.

Evidence with the class of record:

- First start: `Node attestation was successful reattestable=true spiffe_id=".../spire/agent/k8s_psat/gate3-pods/4350a4c9-..."`. A root process got `spiffe://gate3.lab.test/host/7b627f50-...`.
- Container restart, and new pod on the same claim: `SVID loaded`, the same serial number on the server, the same host ID.
- Empty agent data (claim deleted): the agent attests again, with a new serial number and the same host ID. No manual step.
- Absence longer than the life of the agent SVID. The test set `agent_ttl = "2m"` on its server and left the pod absent for 215 s and 200 s. Log: `SVID key recovered, but SVID is expired. Generating new keypair`, then `Node attestation was successful`. The same host ID. The join token path fails at this point (`lab/gate1-nvke/report.md`).
- Token in the guest. The token folder is a `virtiofs` mount, not a copy. With a token life of 600 s the kubelet made a new token at 05:08:41, and the guest saw the same `iat` and `exp` as the node. The agent attested again at 05:10:30, after the first token expired at 05:09:46.
- With this attestor each renewal of the agent SVID is a new attestation (`Reattesting node`, about each minute with the 2 minute life). So the SPIRE server needs the TokenReview API of the host cluster at each renewal.

Real `nvke-agent`. The test ran the gate 1 harness (copy in `nvke-harness/`) with the NVKE node image, systemd, the class of record, and the service account token in place of the node join token. The client kept its join token agent.

- Run 1: `GetKubeadmStatus` and `GetSpireAgentStatus` pass with `authenticated peer ... peer_id=spiffe://gate3.lab.test/host/8809e3f9-...`. They pass again after a new pod (`SVID loaded`) and after a delete of the agent data in the node. The three negative tests fail as they must.
- Run 2, from wiped volumes: pass at the first call, and the negative tests are correct.
- The first call of run 1 failed: `authentication handshake failed: unexpected ID "spiffe://gate3.lab.test/host/7b627f50-..."`. That ID belongs to an earlier pod. The limit below is the cause.

The limit: one agent identity for each host node.

- The agent ID is `spire/agent/k8s_psat/<cluster name>/<UID of the host node>`. `4350a4c9-...` is the UID of the kind node. Each such pod on that node gets the same agent ID.
- Sequence case. A new pod attests, and for about 5 seconds the server gives it the entries of the pod that attested before. In run 1 `nvke-agent` fetched `host/7b627f50-...` at 05:19:03 and the correct ID at 05:19:06. The plain pod test showed the same. A workload that fetches in that window holds an SVID of another node for 1 hour.
- Parallel case. With two pods at one time, both workloads got the host ID of the first pod for the full 2 minutes. The agents attested again each 5 seconds (33 and 32 times in 165 s). The server logged `Agent SVID is not active`.
- So the path is safe only with at most one such pod for each host node and cluster name. A pod with the same name on the same node (a StatefulSet replica) has no problem (run 2). This lab has one node, so it cannot run three such replicas.

What a site must supply:

- Server plugin: `NodeAttestor "k8s_psat"` with a `clusters` entry: `service_account_allow_list = ["<namespace>:<ServiceAccount>"]` and `audience` (the test used `spire-server`). `allowed_pod_label_keys` is optional. A server outside the host cluster also needs `kube_config_file` (not tested).
- RBAC for the server on the host cluster: `create` on `tokenreviews`, `get` on `pods` and `nodes`.
- Pod: the ServiceAccount, a projected `serviceAccountToken` volume with the same audience, the trust bundle, and a route to the server port. The token file had mode 0644 and owner root.
- Entries: the node alias and the host ID entry. A caller ID under `/nvke-service/` as before.
- Scheduling: anti affinity, so that two such pods never share a host node. A different cluster name for a host agent DaemonSet (the test used `gate3-host` and `gate3-pods`).
- NVKE change: the agent template has only `joinToken`, `tpm` and `dsxImds` (`controller/internal/clients/capi/capi_spire_agent.conf.tmpl`, lines 13 to 48). A branch for the service account token and the alias entry are new work. The test wrote and tested no NVKE code.

## 5. What is not tested

- The host socket and the service account token with QEMU. Both QEMU classes do not start in this kind node.
- Kata PR 13162. The test did not build it.
- The service account token with the stock class `kata-clh-runtime-rs`, `nvke-agent` on it with runc, `kubeadm init` on that identity, a cold start of the host cluster, more than one host node, a SPIRE server outside the cluster, an outage of the host API during an agent renewal, and the default token life.
- The cause of the I/O error in the socket file variant.
- Whether the virtiofsd or hypervisor version changes the path 2 result. The kernel reading says no.

What a test of PR 13162 needs. The facts are from the pull request (open, not a draft, branch `fitzthum:uds-forwarding`, last update 2026-06-26):

- A Kata build from that branch, for the Go shim and the Rust shim, installed as an extra handler.
- A QEMU class that starts. In this lab that means a larger `/dev/shm` in the kind node first. The code takes the guest CID from a `vsock://` agent address and rejects `hvsock://`, which Cloud Hypervisor uses. The tests of the pull request assert that. So it gives no fix for the class of record.
- A runtime setting for the whole class: `[runtime] vsock_uds_forward = ["<port>:<socket path on the host>"]`. One pair only.
- In the pod: `/dev/vsock` and a listener such as `socat VSOCK-LISTEN:<port> UNIX-LISTEN:<path>`. The shim dials the guest. The workload then uses the guest socket path. Parallel connections become one connection, so a test needs two clients and the long gRPC stream of the Workload API.
- On the host the shim is the caller. So the agent needs `disable_container_selectors = true` and pod selectors, as in section 3. The cgroup of the Go shim can be outside the pod cgroup, so check it.

## 6. Files, installs and removal

Files in this folder (copies from `/scratch/kata-cp/work/gate3/`):

- `10-spire-server.yaml`, `20-host-agent.yaml`, `30-sock-pod.yaml.tmpl`, `31-qemu-plain-pod.yaml`, `40-spiffe-csi-driver.yaml`, `50-psat-common.yaml`, `51-psat-pod.yaml.tmpl`
- `lib.sh`, `run-path2.sh`, `run-path2-file.sh`, `sim-host-forwarder.sh`, `p3.sh`, `p3-cycle.sh`, `until-cycle.sh`
- `uds-probe/main.go`, `uds-probe/go.mod` (a static probe: stat, connect, listen). The binary is `/scratch/kata-cp/work/gate3/bin/uds-probe`.
- `nvke-harness/` (a copy of the gate 1 harness. Changed: `run.sh`, `node-pod.yaml.tmpl`. New: `spire-agent-psat.conf.tmpl`, `env-kata-rs-run1.sh`, `env-kata-rs-run2.sh`)

Raw output in `/scratch/kata-cp/logs/gate3/`:

- `00-start-state.txt`, `00-node-images-start.txt`, the install logs `10-`, `20-`, `21-`, `40-`, `41-`, `90-final-spire-state.txt`, `91-cleanup-cluster.txt`, `92-node-images-end.txt`, `99-end-state.txt`
- `path2/` (one folder for each run, `host-side-of-kata-pod.txt`, `qemu-plain-pod.log`, three `sim-host-forwarder-*.txt`)
- `path3/` (status files, `collision-*`, `psat-a-token-rotation-*.txt`, cycle logs)
- `path3-nvke/kata-rs-run1/` and `kata-rs-run2/` (each has a `secrets` folder with a used client join token)
- `upstream/` (`issue-8024.json`, `pr-13162.json`, `pr-13162.diff`, `linux-v6.18-af_unix.c`)

Installed, and how the test removed it:

- Namespaces `gate3`, `gate3-spire`, `gate3-nvke`: `kubectl delete namespace`.
- ClusterRoles and bindings `gate3-spire-server`, `gate3-spire-agent`, and the CSIDriver `csi.spiffe.io`: `kubectl delete`.
- PersistentVolumes `gate3-nvke-nvke-cp-var` and `-etcd` on `/dev/loop21` and `/dev/loop25`: deleted, then `wipefs -a`.
- In the node: `/var/lib/gate3`, `/run/spire`, `/var/lib/kubelet/plugins/csi.spiffe.io`, and the empty `/var/local-path-provisioner`: removed.
- Two pulled images (CSI driver, registrar), one at a time: `crictl rmi`. The image list of the node is equal to the list at the start.
- Four web requests in total, one at a time, with no private name.

End state (`99-end-state.txt`, 05:23 UTC):

- No namespace with the name `gate3`. 17 pods, all Running, the same list as at the start.
- `gate4`: `cp-a-0`, `cp-b-0`, `cp-c-0` are `1/1 Running` with 4 restarts each and the same pod IPs as at the start.
- On the node: 3 Kata shims, 3 Cloud Hypervisor processes, 0 QEMU processes. No CSI mount is left.
- The test did not restart containerd, the kubelet, `kata-deploy` or the node. It restarted only its own SPIRE server container (2 times, for the agent life setting).
