# Gate 1 step 4 and gate 3 with a join token: lab report

Date 2026-11-25. NVKE commit bcc4376f, image `nvke-node:bcc4376f-amd64`, one kind node. The lab files are in `~/notes/hosted/lab/gate1-nvke/` (`run.sh`, `wrapper.sh`, the pod templates, `spire-server.yaml`, `client/`, `render/`, `kubeadm/`, `ttl-test.sh`, `kata-extra-tests.sh`). The raw logs are in `/scratch/kata-cp/logs/gate1-nvke/` (LOGS below). The agent that ran the tests wrote this report, and the main session saved it.

Step A (`kubeadm init` through `nvke-agent`) and step B (an authenticated call from a client that checks the SPIFFE ID of the agent) pass with runc, with `kata-clh-runtime-rs` in 3 of 3 runs, and with `kata-clh` in 1 run. Stock Kata 4.4.0 needed no change for the two steps. A separate memory test killed the hypervisor of a Kata pod (section 5, first item). A Kata setting looks necessary there.

## 1. Result of each run

| Run | Runtime | Agent mode | Result | Pod create to agent port | Pod create to `/readyz` | `crictl stop` to `/readyz` | Folder in LOGS |
|---|---|---|---|---|---|---|---|
| A1 | runc | plaintext (`--disable-mtls`) | Pass, 2 of 2 | 9.2 s, 9.3 s | 19.4 s in run 2 | 7.3 s, 8.5 s | `a1-runc-plaintext-run1`, `-run2` |
| A2 and B | runc | SPIFFE mTLS | Pass, 1 of 1 | 12.3 s | 21.3 s | 9.0 s | `a2-runc-mtls-run1` |
| A3 and B | `kata-clh-runtime-rs` | SPIFFE mTLS | Pass, 3 of 3 | 14.5 s, 14.4 s, 14.5 s | 24.3 s, 23.9 s, 23.8 s | 8.0 s, 10.0 s, 9.0 s | `a3-kata-rs-mtls-run1` to `-run3` |
| A3 and B | `kata-clh` | SPIFFE mTLS | Pass, 1 of 1 | 14.6 s | 23.9 s | 10.8 s | `a3-kata-go-mtls-run1` |

- In each run the client pod called `GetKubeadmStatus`, `ExecuteNodePreflight` with the cloud-init check, `ExecuteKubeadmInit` with `no_cni_install`, a status poll each 10 seconds, `GetKubeconfig` and `GetSpireAgentStatus`. The client reached the agent through the Service on port 15005, and nobody ran `kubeadm init` by hand.
- Each run met the gate 1 rules. `/readyz` through the Service gave `ok (http 200)`, etcdctl gave `is healthy`, and `kubectl get nodes` listed `nvke-cp` as NotReady because the node has no CNI. After `crictl stop` the control plane returned with the same certificates, etcd member and node object.
- For step B, `client-init.txt` of Kata run 1 has the line `msg="authenticated peer" step=init peer_id=spiffe://lab.nvke.test/host/4df35717-5b5f-4f8f-b1b5-e1bc366fca29 peer_addr=10.96.76.130:15005`. The client held `spiffe://lab.nvke.test/nvke-service/lab-client`, and `GetSpireAgentStatus` returned `has_valid_svid=true` with the same host ID.
- The time to `/readyz` of A1 run 1 (29.6 s) is too high, because the script read `/readyz` only after the client poll. The later runs read it each second. Kata runs 2 and 3 ran while a runc pod of other tests started, and their times differ from run 1 by at most 0.5 s.
- A manual `kubeadm.real init phase preflight` with the NVKE configuration and no ignore flag ended with exit code 0. It gave one swap warning with runc, and no warning in the Kata guest with the Kata kernel config in `/boot`.
- Versions: Kubernetes v1.36.4 in the host cluster and in the node, Kata 4.4.0, Cloud Hypervisor v54.1, guest kernel 6.18.62, host kernel 7.0.0-44, containerd 2.3.4, runc 1.4.3, nvke-agent v0.24.0-beta.18, spire-agent and SPIRE server 1.14.1, go-spiffe v2.9.0, grpc-go v1.85.0.

## 2. Differences between the procedure note and the lab

The lab confirmed the call order, the request fields, the `spire-server` commands and the unit table of the procedure. The lab added the points below, which the procedure does not have.

- The Service needs `publishNotReadyAddresses: true`. The pod is ready only when `/readyz` answers, so a plain Service has no endpoint for port 15005 before init.
- A new pod has a new IP, and the kind entrypoint of the image then tries to make a new API server certificate from `/kind/kubeadm.conf`. NVKE does not write that file. The first container ends with exit code 1 (`unable to read config from "/kind/kubeadm.conf"`), and the API server then fails with `open /etc/kubernetes/pki/apiserver.crt: no such file or directory`. The control plane does not return in a new pod. Gate 4 needs a fixed node address and also a wrapper step for the address repair of kind, because the pod IP still changes.
- Each node of the image has the machine ID `48ac6baa2aec4fe4bba6e77294e30066`, from `/var/lib/dbus/machine-id` in the image. The `container_uuid` of the gate 1 wrapper has no effect here.
- The agent keeps the init configuration in `/tmp/kubeadm-init-config.yaml`, and the wrapper empties `/tmp` at each start. The journal is in `/run`, so a new container has no log of the old one. The audit log `/var/log/nvke-agent-audit.log` stays.
- `nke-container-cni-images.service` adds about 5 seconds to each start. With the unit left out, the agent port opened after 4.4 s and `/readyz` answered after 13.7 s (`a1-runc-plaintext-skip-cni-images`).
- The kubelet patch must be below the guest memory, as the procedure says. With `systemReserved: 16Gi` in the 8 GiB Kata guest the kubelet gave `invalid Node Allocatable configuration. Resource "memory" has a reservation of 17821597696 but capacity of 8380190720` (`a3-kata-rs-reservation-test`). The lab sends 1Gi and 512Mi. In the runc pod `MemTotal` is the memory of the host, so only a Kata run shows the error.
- The agent runs `swapoff -a` at start. In the runc pod the call goes to the host kernel, and it failed with exit status 32. In the Kata guest it gave no error. A host with a swap partition is not tested.
- The client has 269 lines and makes no reflection query. The render of the kubeadm files needed five Go modules that the module cache did not have. `GetSpireAgentStatus` gives `FailedPrecondition` in the plaintext run, so that run leaves the call out.

## 3. What the pod needs beyond the gate 1 wrapper, and the units that fail

- The wrapper copies `agent.conf` and `initial-trust-bundle.pem` from a Secret to `/etc/spire-agent` at each start, with mode 0644. `/var/lib/spire-agent` is on the `/var` volume.
- The wrapper writes `done` to `/var/lib/nico-containers/cloud-init/status`, so the cloud-init check of the agent passes. The pod hostname is the node name.
- For the plaintext run only, the wrapper adds `--disable-mtls` to `AGENT_ARGS` in `/etc/default/nvke-agent`. For mTLS the image file needs no change and the agent needs no restart.
- The Service has the ports 15005 and 6443 and publishes addresses that are not ready. The Kata pod keeps the gate 1 settings (overlayfs snapshotter, no `/lib/modules`, stop timeout of 10 seconds).
- No new path needs a volume for the two steps. The files that the node wrote outside the volumes are in `newfiles-root.txt` of each run, and the entrypoint, the units or the agent write each of them again at start.
- In the Kata guest `ovs-vswitchd.service` fails with `modprobe: FATAL: Module openvswitch not found in directory /lib/modules/6.18.62`. `nke-container-network.service` then does not start (`Dependency failed`), and systemd reports `degraded`. The two failures are harmless for a node with no OVN. systemd-networkd leaves `eth0` as it is.
- With runc no unit fails, because the host has the Open vSwitch module. `nke-container-network.service` gives `eth0` to systemd-networkd with the same address, and the pod network continues to work.
- With no SPIRE files, `spire-agent.service` restarts each 5 seconds (`could not find config file /etc/spire-agent/agent.conf`). `etcd-data-dir`, `nke-container-cni-images` and the two shims work with runc and with Kata.

## 4. Identity results

- The join token path works with runc and with the two Cloud Hypervisor shims. The node has its own SPIRE agent, the client pod has its own SPIRE agent, and no socket of the host is in use.
- A wrong expected agent ID fails in the client with `authentication handshake failed: unexpected ID "spiffe://lab.nvke.test/host/<node UUID>"`.
- A client with the ID `spiffe://lab.nvke.test/other-service/lab-client` fails with `remote error: tls: bad certificate`, because the agent refuses it. A plaintext client against the mTLS port also fails. All three tests failed in each mTLS run, as required (`negative.txt`). The agent writes no log line for a refused call.
- After a container restart the SPIRE agent loads its SVID from `/var/lib/spire-agent` (`msg="SVID loaded"`). The key file and the agent serial number on the server stay the same, the agent port opens again, and the client call passes. The node needs no new join token.
- After a new pod on the same volumes the identity result is the same, with runc and with both shims (`spire-3-after-new-pod.txt`). Only the control plane fails there, because of the new address.
- A used token with an empty data folder fails with `failed to attest: join token does not exist or has already been used`. So a node with a new `/var` needs a new token.
- A node that is absent for longer than the life of its agent SVID loses the identity. With `agent_ttl = "2m"` and 197 seconds with no pod, the agent logged `SVID key recovered, but SVID is expired` and then the used token error, and port 15005 stayed closed (`b-runc-agent-svid-expiry`, runc only). The SPIRE default life is 1 hour, and the NVKE repository has no setting for it that the agent found.
- The repair worked in the running pod. A new join token in `agent.conf` and a restart of `spire-agent` gave the node the same host ID, and the agent port opened with no restart of `nvke-agent`.
- A site must supply a SPIRE server address that the pod can reach, the trust bundle, and one join token for each node with the alternate ID `join-token-spire-agent/host-id/<node UUID>`. It must also supply an entry for `spiffe://<td>/host/<node UUID>` under that ID, a caller ID under `/nvke-service/`, and a way to give a node a new token after a long absence.
- The ID of a join token agent has the token in it, so the SPIRE logs and `spire-server agent list` show used tokens. The lab scripts mask them.

## 5. Failures on the way, with causes

- Kata memory test with `kata-clh-runtime-rs` (`a3-kata-rs-extra-tests/oom-evidence.txt`). The test read 10 GiB from the `/var` device in the guest to fill its page cache. The kernel log gave `memory: usage 8521728kB, limit 8521728kB` and `Memory cgroup out of memory: Killed process 977893 (cloud-hyperviso) ... shmem-rss:8364148kB`. The pod cgroup had `oom_kill 1`, and the kubelet made a new sandbox with a new IP. The limit is the 8Gi of the pod plus the 130Mi overhead of the RuntimeClass. The guest has 8Gi plus 32Mi, so about 98Mi stay for the hypervisor side. That cause is a reading of the numbers and is not proven. The fill was forced. It is not tested how soon a normal node reaches that state, or whether a larger overhead prevents the kill. Before the fill the cgroup had 6.7 to 7.6 GB in use in each run with the Rust runtime, with no OOM event. With `kata-clh` the pod cgroup read `memory.current 0`, so its hypervisor is not in that cgroup, and the fill test did not run with it.
- Section 2 describes the failure of a new pod with a new IP. It is not fixed here, because the pod IP as node address is temporary.
- `kubectl apply` refused the ConfigMap with the host kernel config (`metadata.annotations: Too long: may not be more than 262144 bytes`). The script now uses `kubectl create`.
- The first render failed with `module lookup disabled by GOPROXY=off`. The agent downloaded the five modules one at a time.

## 6. State after the work, and how to remove it

- The namespace `gate1-nvke-spire` with the SPIRE server stays for the next gate 3 tests. Remove it with `kubectl delete namespace gate1-nvke-spire`. All other namespaces, pods and volumes of this work are gone, and the four loop devices (var-1, etcd-1, var-2, etcd-2) have no filesystem signature.
- The kind node has the images `nvke-node:bcc4376f-amd64` and `ghcr.io/spiffe/spire-server:1.14.1` (`crictl rmi`) and the folder `/var/lib/gate1-nvke` with the client binary (`rm -r`).
- `/scratch/kata-cp` has `bin/nvke-lab-client`, `tmp/go-build` (1.3 GB build cache), `tmp/gate1-nvke` and LOGS. Each run folder in LOGS has a `secrets` folder with used join tokens and kubeconfigs of deleted clusters. The Go module cache of the user has five more modules.
- Not tested: the QEMU shims, the other gate 3 paths, the NVKE controller transport, the approval of the kubelet serving certificate, a request with no `init_config`, the sentinel preflight, and the boot ID file of nico-sim.
