# Block D: the real NVKE controller on the fixed address design (second machine)

Date: 2026-11-26, 18:28 to 19:09 UTC, on the second test machine. Kata runs with nested virtualization there, so times do not compare with the workstation. Logs: `/scratch/kata-cp/logs/bigbox/remote-logs/d/` (`d-run-1`, `d-run-2`, `d-chain.out`), `remote-logs/d-stack/`. Scripts: `/scratch/kata-cp/work/bigbox/remote/d/` (`stack/`, `endpoint-run/`, `helper/`, `d-run.sh`, `d-chain.sh`, `stack-image.sh`, `cleanup-bc.sh`, `src/` = the few source files of commit `c6d669ef` that the install reads).

## Verdict

Pass, 2 of 2 runs from empty volumes. The NVKE controller `c6d669ef` in the kind cluster of the second machine made one cluster with three control plane nodes on three Kata pods. No lab client. No NVKE code change. No firewall change.

| Rule | Run 1 | Run 2 |
|---|---|---|
| 1. NVKE reports provisioned | 176.9 s after the POST | 176.9 s |
| 1. Three provisioned nodes in NVKE, three Ready control plane nodes in the new cluster | 291.4 s, 296.0 s | 281.1 s, 281.9 s |
| 2. Pod to pod between the three nodes | 6 of 6 directions | 6 of 6, and 6 of 6 after the replace |
| 2. Name lookup from a pod on each node | 3 of 3 | 3 of 3, and 3 of 3 after the replace |
| 2. OVN pod Ready on each node | `ovnkube-node` 5/5 on each | 5/5 on each |
| 2. Tunnels use the fixed addresses | `node-encap-ips` `172.28.1.21` to `.23`, Geneve packets only between them | the same, also after the replace |
| 3. etcd with stock settings, 0 rejected peer connections | 0 on each of 3 hosts | 0 on each of 3 hosts |
| 4. The endpoint is the shared address `172.29.255.220:6443` | kubeadm config, SAN of each API server certificate, both kubeconfig Secrets, 2 join commands. No kube-vip | the same, also after the replace |

- etcd flags on each host are the kubeadm defaults (`--listen-client-urls=https://127.0.0.1:2379,https://172.28.1.2x:2379`, `--listen-peer-urls=https://172.28.1.2x:2380`). The patches folder has only the two files of NVKE.
- First node: host c (`172.28.1.23`) in both runs.
- The shared address answered first about 95 s after the POST in both runs, and then each call (199 of 199 and 186 of 186 until the end of the flow).

## The replace of the first node (run 2)

Host c, node `kata-cp1-cp-49321df4`, pod delete at 18:57:51.

- Shared address, one call each second from the kind node for 372 s: 366 of 366 answered 200.
- Own address of the node: 25 calls failed, 18:58:12 to 18:58:48.
- Seconds after the delete: old pod gone 22.5, systemd up 35.9, `/readyz` of the new pod 58.5, new kubelet heartbeat 85.8, etcd healthy 86.2.
- NVKE, one poll each 10 s for 360 s: the cluster stayed `provisioned` in each poll. The node had `nodeAgentReady` not True in 4 of 32 polls, and all other conditions True in each poll. NVKE started no workflow.
- After it: the pass rule, the endpoint checks, 3 started etcd members, 0 rejected peers.
- Pod traffic after it: 6 of 6 directions, API Service and name lookup from each node, tunnels on the fixed addresses. The test pod on the replaced node must be made again first (its restart policy is Never): with the old pods the step gave 4 of 9 lines.

## What changed against C3

- The real controller, mTLS, the bootstrap helper, and the form of step 5 for the host pods: the wrapper writes no SPIRE file and no cloud-init status, `/etc/spire-agent` is on the `/var` volume, the label `nvke.lab/host`, the container name `node`.
- A shared LoadBalancer Service `cp-api` (`172.29.255.220`, MetalLB, only ready pods) as `controlPlaneEndpoint`. C3 used the address of the first node.
- Kept from C3: the fixed address and hardware address on `net1`, the class `kata-clh-runtime-rs-fix-direct-ovs`, the stock datapath mode, no etcd patch file, no address on a guest bridge, the two images from files (`pause:3.10.2`, DNS cache), the removed modprobe line.

## What changed against steps 5 and 7

- Step 5 and 7 had one LoadBalancer Service for each host as its node address, the address on a guest bridge, the etcd patch file, the userspace datapath and `/dev/net/tun`. Block D has none of them.
- The inventory address of a host is its fixed address (`172.28.1.21` to `.23`). The controller pod reaches `<fixed address>:15005` through its host node. The agent sees the address of that host node on the node network as the caller (`172.28.0.x`).
- The SPIRE address in `agent.conf` is `172.29.0.3:30081` (the control plane kind node and a NodePort).
- The stack install runs on the machine itself, with no toolbox container (the machine reaches the API port of kind on `127.0.0.1` and the internet). Controller image `c6d669ef` from the first install, with `allowControlPlaneWithoutVIP: false`.
- Each kind node cannot pull, so each image goes through the machine (below).
- Four kind nodes: each host pod has its own host node, the SPIRE agent and the CSI driver run on each node.

## What NVKE sees

- The request with `"controlPlaneEndpoint": "172.29.255.220:6443"`, no `controlPlaneVIP`: HTTP 201. GET returns the field. A PATCH with the field gives HTTP 400.
- `NodePreflight` attempt 1 fails in each run ("failed to get agent version"), and the retry passes. The agent of a host answers 130 to 210 s after the pod create on this machine.
- Run 1: the first `JoinNode` run of the third node failed in `KubeadmJoin` with "failed to get etcd mirror Pod for node ...". It is the race of step 5. The retry of NVKE passed. Run 2 did not have it.
- No step failed by a timeout.
- The kube-vip step ran 4 times in each run with an empty result.
- Delete of run 1: API delete, then the two operator steps on the 3 `ProvisionedMachine` objects and the 3 host claims of that cluster. The row was gone 129.0 s after the DELETE and 11.5 s after the operator steps. The empty check passed.

## Failures and their causes

1. Stack install, images. A kind node cannot pull. First way (`ctr` pull on the machine, export, import in each node): 13 of 17 images. `mirror.gcr.io` refused one pull with a quota answer ("toomanyrequests"), and a later try passed. The export of the 3 cert-manager images failed ("content digest not found"): containerd of the machine did not fetch a layer that another of its namespaces already has. Third way: skopeo in a throwaway container with the host network copies the image to a file.
2. A fault of my install step: it did not see a failed image load, so step 06 reported PASS with 4 images missing. `temporal-web` then was in `ImagePullBackOff`. Fixed, images loaded, the pod ran.
3. `check.sh` reports 66 passes and 1 failure: it expects `allowControlPlaneWithoutVIP: true`, the setting of step 3. Block D sets `false` on purpose.
4. `delete.sh` printed one error for a file in a `secrets` folder that this copy keeps in another place. No effect on the delete.
5. Traffic after the replace, first measurement: 4 of 9 lines, because the old test pod on the replaced node does not start again. With new test pods: 9 of 9.

## Not tested

- More than two runs. A replace of a node that is not the first node. A host node loss with the controller in place.
- The firewall rule for the lab bridge. It was not added: the images went through the machine.
- A restart of a kind node with the stack installed (a kind node with two Docker networks can take the wrong node address, see result-C3.md).
- Workers, an upgrade, a certificate rotation, a cluster delete with no operator step.

## State

The cluster of run 2 is up: namespace `d` (3 StatefulSets, `cp-api`), NVKE cluster `kata-cp1` (ID in `d-run-2/cluster-id.txt`), provisioned, 3 nodes. The NVKE stack runs in its 10 namespaces, plus `nvke-lab-bootstrap-helper`.

Changes on the machine for block D, with removal:

| Change | Removal |
|---|---|
| NVKE cluster `kata-cp1` and the host pods in the namespace `d` | `LOG_DIR=/root/kata-cp/logs/d/d-run-2 CLUSTER_NAME=kata-cp1 /root/kata-cp/d/endpoint-run/delete.sh all` |
| The NVKE stack (namespaces `postgres`, `temporal`, `spire-server`, `cert-manager`, `capi-system`, `capi-kubeadm-bootstrap-system`, `capi-kubeadm-control-plane-system`, `provisioned-system`, `nvke-controller`, `nvke-system`), the helper namespace, one NodePort 30081 on the kind nodes | `/root/kata-cp/d/stack/uninstall.sh all` after the cluster delete, `kubectl delete namespace nvke-lab-bootstrap-helper`. Or delete the kind cluster |
| `clusterctl` v1.13.6 in `/root/kata-cp/bin` (checksum of the source pin) | remove the file |
| Docker images `nvke-controller:c6d669ef`, `cluster-api-provider-provisioned:bcc4376f`, `nvke-lab-bootstrap-helper:dev`, `quay.io/skopeo/stable:latest` | `docker rmi` for each |
| 18 more images in the containerd namespace `kata-lab` of the machine, files in `/root/kata-cp/dl/img/stack` | `ctr -n kata-lab images rm`, remove the folder |
| Secrets made on the machine: `/root/kata-cp/d/stack/secrets` (database password, kubeconfig copy), `/root/kata-cp/secrets/d-*` (mode 700) | go with `/root/kata-cp` |
| No firewall rule, no kernel module, no change to Docker or containerd configuration | |
