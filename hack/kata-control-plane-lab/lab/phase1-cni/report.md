# Phase 1, step 1: OVN-Kubernetes with the userspace datapath in one Kata pod

Date: 2026-11-26, 09:35 to 10:14 local time. A test agent ran the work and returned this report as text. The main session wrote the file. Raw output: `/scratch/kata-cp/logs/phase1-cni/` (folders `k0` to `k4`, `progress.txt`). Scripts: this folder, with the originals in `/scratch/kata-cp/work/phase1-cni/`.

## Answer

Yes. OVN-Kubernetes with the userspace datapath of Open vSwitch gives a working pod network in one NVKE control plane node that runs as a Kata pod (class `kata-clh-runtime-rs-fix-direct`, stock guest kernel 6.18.62). It needs two changes in the node image and one agent setting. It needs no kernel module, no guest kernel change, no NVKE patch and no image build. The full flow passes 4 of 4 times from empty volumes.

So open point 1 of `phase1-design.md` has its answer with option A, and a guest kernel build is not necessary.

## 1. Verdict

Times are seconds after the create of the outer pod. The values in brackets are seconds after the CNI install returned.

| Run | Runtime | Datapath | Result | Node Ready | CoreDNS Ready (a pod on the pod network) |
|---|---|---|---|---|---|
| k0 | Kata, `kata-clh-runtime-rs-fix-direct` | netdev | Fail with the stock units, at the Open vSwitch step of the agent. Pass after two changes by hand in the same pod | 4 s after the CNI install | 6 s after the CNI install |
| k1 | Kata, same class | netdev | Pass, with the node-local-dns step | 42.5 (4.6) | 45.0 (7.1) |
| k2 | Kata, same class | netdev | Pass, with the node-local-dns step | 41.2 (3.4) | 43.0 (5.1) |
| k3 | Kata, same class | netdev | Pass, no node-local-dns step. Extra restart test: pass, with one fault of the test script | 44.7 (6.4) | 46.7 (8.5) |
| k4 | Kata, same class | netdev | Pass, no node-local-dns step. Extra restart test: pass | 41.7 (4.1) | 43.5 (5.8) |
| runc baseline | runc | netdev | Not run (section 4) | | |

In each passing run (k1 to k4):

- The agent answers 11.3 to 11.6 s after the pod create. The Open vSwitch step takes 2.1 to 2.2 s, `kubeadm init` 20.1 to 20.2 s, `/readyz` answers after 26.7 to 26.9 s, and the CNI install returns in 3.1 to 3.2 s.
- The inner Node is Ready, and the two CoreDNS pods are Ready with the addresses 10.113.0.3 and 10.113.0.4.
- A test pod on the pod network gets HTTP 200 from `https://10.112.0.1:443/version` and from `https://kubernetes.default.svc.cluster.local/version`, and it resolves that name in 10 of 10 tries.
- With the node-local-dns step (k0, k1, k2): a Ready pod with the label `dns-role=cluster-dns` exists 1.7 s after the apply, because the step puts the label on the running CoreDNS pods. The node-local-dns pod (not on the host network) is Ready 5.4 to 5.6 s after the apply, of which 4 s are the image pull.
- systemd in the node reports "running" with 0 failed units. The pod cgroup has 5.7 to 6.1 GB in use and no OOM event. `ovs-vswitchd` uses 0.2 to 0.3 percent of one CPU and 19 to 22 MB with no load.
- Open vSwitch state: `br-ex` and `br-int` have the datapath type `netdev`. The bridges and `ovn-k8s-mp0` are TAP devices, and each pod port is a veth.

## 2. What the agent does for OVN on a node, and what differs with netdev

From the NVKE source at `bcc4376f`, confirmed by the agent journal of k0:

- The controller runs the Open vSwitch step before the node is ready to join, with no end of retries (`controller/internal/temporal/workflows/provision_node.go:236, 404-437`).
- The agent checks the package and runs `systemctl enable --now openvswitch-switch` (`agent/internal/agent/open_vswitch.go:372-381`).
- With `NKE_OVS_DATAPATH_TYPE` set to `system` or `netdev` the agent takes a short path and does not move `eth0` to a bridge (`open_vswitch.go:213-215, 261-304`). It sets `external_ids:ovn-bridge-datapath-type` and makes the bridge `br-ex` with that datapath type.
- Only with `netdev` it also sets `other_config:userspace-tso-enable=true` and restarts `ovs-vswitchd` one time (`open_vswitch.go:283-287, 311-336`). This is the only difference between the two values in the agent.
- With the variable empty (bare metal) the agent moves the interface of the default route to a bridge with netplan or ifupdown (`open_vswitch.go:216-258`).
- The cluster workflow runs `kubeadm init` with no CNI install, then the CNI install, then the DNS install (`controller/internal/temporal/workflows/provision_cluster.go:48-97, 177-200`). `kubeadm init` skips kube-proxy for OVN (`controller/internal/temporal/activities/kubeadm_init.go:113, 156`).
- The CNI install needs the role `controlplane`, a working `ovs-vsctl` and the package `nvke-cni-ovn-charts-2.4.2` (`agent/internal/agent/cni.go:878-913`). It runs `helm upgrade --install ovn-kubernetes /etc/dgx/ovn-kubernetes` with the single node zone values. It runs no apt and imports no image.
- For both datapath values it adds a dummy gateway bridge, the gateway options `--gateway-mode=local --gateway-interface=br-ex --allow-no-uplink`, and no pod host port (`cni.go:78-85, 258-277`).
- The chart has no Open vSwitch pod, so Open vSwitch must run on the node.
- Images: the OVN image comes from a package in the node image, which a unit installs at each boot. In the guest the import takes 5 s. CoreDNS and the control plane images are in the kind base image. Only node-local-dns needs a registry.
- DNS install: NVKE applies node-local-dns, puts the label `dns-role=cluster-dns` on the CoreDNS template and on the running CoreDNS pods, and changes the selector of the `kube-dns` Service when one pod with that label is Ready (`controller/internal/temporal/activities/install_kube_local_dns.go:53-88, 119-124, 167-191, 209-251, 288-304`). So a Ready CoreDNS pod is enough for the check of NVKE.

## 3. What the pod needs that the stock image does not give

Each change is in section 6 of `wrapper.sh` and has its own switch.

| Change | Why |
|---|---|
| A systemd drop-in for `nvke-agent.service` with `Environment=NKE_OVS_DATAPATH_TYPE=netdev` | The image sets the value `system` (`controller/hack/capd-kindest-node/scripts/nvke-agent-container-ovs.conf:9`). NVKE has no API field for it |
| A systemd drop-in for `ovs-vswitchd.service` with an empty `ExecStartPre=` line | The image adds a `modprobe openvswitch` step (`capd-kindest-node/Dockerfile:108-109`). The guest has no module, so the unit fails |
| The device node `/dev/net/tun` (`mknod -m 0666 /dev/net/tun c 10 200`) at each container start | A privileged Kata container does not have it. The userspace datapath makes each internal port as a TAP device. The guest kernel has `CONFIG_TUN=y` |

- One lab step outside the image: the lab approves the kubelet serving certificate request of the node. Without it `kubectl exec` in the inner cluster fails. Under NVKE the controller approves it (`controller/internal/controllers/tenant/csr/controller.go:57`).
- Not changed against gate 1: the two block volumes, `/dev/kmsg`, `ip_forward`, the kernel config file, the cloud-init status file and the plaintext flag.
- Not needed: hugepages, DPDK, `/lib/modules`, a guest kernel option, a larger pod.
- A side effect: with `ovs-vswitchd` active, the unit `nke-container-network.service` now runs in the guest. It writes a netplan file for `eth0` and runs `netplan apply`, with success. In gate 1 and gate 4 this unit never ran in a Kata guest.

## 4. Failures, with causes

1. **Stock units in the Kata guest (k0).** The agent step fails: `modprobe: FATAL: Module openvswitch not found in directory /lib/modules/6.18.62`, then `enable openvswitch-switch: ... A dependency job for openvswitch-switch.service failed`. Deduction: the controller repeats this step with no end, so the cluster stays before `kubeadm init`.
2. **No `/dev/net/tun` (k0, after the fix of 1).** The agent reports success, but the datapath does not exist: `outcome=OUTCOME_CONFIGURED bridge=""`, and `ovs-vswitchd` logs `opening "/dev/net/tun" failed: No such file or directory`, `failed to create datapath ovs-netdev`, `failed to create bridge br-ex`. Cause: `ovs-vsctl` returns 0 when the database change is done, and the agent does not check the bridge (`open_vswitch.go:288-303`). This is a point for NVKE: the step can report "configured" for a bridge that Open vSwitch could not make.
3. **`kubectl exec` in the inner cluster (k0):** `error dialing backend: remote error: tls: internal error`. The kubelet serving request was pending (section 3).
4. **Extra restart test (k3, k4), not a pass rule.** After a stop of the node container, the node, the OVN pods and CoreDNS return, and a new test pod passes the network test in 2 of 2 runs. In k4 `/readyz` answers after 28.2 s, and the pods are Ready after 86.2 s. Two facts:
   - The Open vSwitch system ID changes at each container restart, because `/etc/openvswitch/system-id.conf` is on the root filesystem of the container. The database stays, because it is on the `/var` volume. OVN-Kubernetes followed the new ID. With more than one node this is not tested.
   - In k3 the first container create after the stop failed one time: `The disk could not be added to the VM ... Failed to get Write lock for disk image: /dev/loop25 ... The file is already locked`. The retry of the kubelet passed. In k4 it did not occur. This is a Kata and Cloud Hypervisor point, not a CNI point.
5. **The runc baseline was not run.** OVN-Kubernetes makes an nftables table with masquerade, NAT, redirect, fib and socket matches. On the lab host those kernel modules are not loaded (`nft_masq`, `nft_nat`, `nft_redir`, `nft_fib` and others). A privileged runc pod would make the host kernel load them, and the lab rule is no module load on the host. The Kata result does not need the baseline.
6. **A correction.** The guest kernel has `CONFIG_VXLAN=y`. It has no Open vSwitch and no Geneve.

## 5. Not tested

- Pod traffic between two nodes, and Geneve. With one node Open vSwitch makes no tunnel port. Deduction: with netdev the tunnel is in user space, so it needs no Geneve module.
- The gate 4 address design together with OVN. Facts for the next step: OVN records the pod IP as the tunnel address of the node (`node-encap-ips`). The unit `prepare-container-network` needs exactly one global IPv4 address on `eth0` and gives `eth0` to systemd-networkd, and gate 4 adds the LoadBalancer address as a second address on `eth0`. Deduction: that unit then fails, or networkd removes the second address.
- Throughput, latency and CPU cost of the userspace datapath under load.
- A new pod on the same volumes, a second node, a worker, NetworkPolicy, NodePort, a LoadBalancer Service, IPv6.
- The mTLS mode of the agent, the real NVKE controller, and what the controller does in the failure cases 1 and 2.
- The runc baseline, and the kernel datapath in any form.

## 6. Files, images and cleanup

- Files in this folder: `run.sh`, `wrapper.sh`, the templates, `env-kata.sh`, `env-runc.sh`, `extra-restart.sh`, `client/` (the lab client with the new steps for Open vSwitch and for the CNI), `render/`. The built client and the unpacked chart are only in `/scratch/kata-cp/work/phase1-cni/`.
- Images: the node in the guest pulled `registry.k8s.io/dns/k8s-dns-node-cache:1.26.8` three times, one time in each of k0, k1 and k2, because each run starts from empty volumes. The kind node and the host Docker got no new image.
- Cleanup at the end: the namespace `phase1-cni` and its two PersistentVolumes are gone, the four loop devices 20, 24, 21 and 25 have no filesystem signature, the kind node has no unit and no folder of this test, and the host module list is the same as before.
