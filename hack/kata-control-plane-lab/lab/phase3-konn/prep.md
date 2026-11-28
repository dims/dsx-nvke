# Phase 3, Konnectivity prototype: preparation of the lab test

Date: 2026-11-27, 20:02 to 20:31 local time of the workstation (from `date`).

This task was preparation on the workstation only. It touched nothing on the second machine and no file of the lab agent. It ran no cluster and no container. It changed no NVKE source and no simulator source.
The design is `hosted/phase3-konnectivity-design.md` (way L, accepted on 2026-11-27). The reading is `hosted/results/phase3-konnectivity-reading.md`.

How to read this note:

- A sentence with a file reference is a fact from that file. Paths with no root are in the lab tree `/scratch/kata-cp/src/nvke-ctrllab` at `5c08484c`. The lab agent binary comes from `/scratch/kata-cp/src/nvke-agentlab2` at `41e88c4d`. "Kubernetes 1.36.4" means the tag `v1.36.4` of the local Kubernetes checkout, read with `git show`.
- "(deduction)" marks a conclusion that no test has shown. Section 13 has each one that the lab must prove first.
- "(tested here)" marks a fact from a test on the workstation.
- "(lab note)" marks a fact of an earlier lab note.

Folders:

- This folder has the scripts, the two files of the request, the manifests, the image contexts and rendered requests.
- The working copy is `/scratch/kata-cp/work/phase3-konn/remote/p3-konn/`. `ws-sync.sh scripts` copies it to `/root/kata-cp/p3-konn/` on the machine.
- The image archives and the logs of this task are in `/scratch/kata-cp/work/phase3-konn/images/` and `logs/`.
- The scripts build on the phase 3 folder `/root/kata-cp/p3/` as the lab agent left it. They change no file there.

## 1. Short answers

| Question | Answer |
|---|---|
| Which version of the two images | v0.34.0. Kubernetes 1.36.4 pins it for the client inside the API server and names it for both images |
| Are the images pulled | Yes. Two pulls with no login, one after the other. The archives are ready |
| Does v0.34.0 have each flag of the design | Yes. Read from the two programs in the images, with no run |
| Does NVKE accept the flag and the two files | Yes (tested here with the renderer and the request type of the lab commit) |
| Do the files reach a node that replaces another | Yes by the source. Each new control plane node gets them from the config snapshot |
| Can the API server use a socket in the folder that NVKE mounts | The source cannot say it for this folder. The lab check is pass rule 2 itself, and one line of `facts` |
| Does `kubeadm reset` empty the manifest folder | Yes (kubeadm 1.36.4). The lab agent runs it only before a join that follows a failed join |
| Does the network plugin of the host cluster apply a NetworkPolicy | Yes by the source of kindnet. For a Kata pod the source cannot say. The lab check is `konn.sh reach` |
| Is a third image tag needed | No. Pass rule 3 uses a fourth control plane node, not a rollout to another image |

## 2. What is ready and where

| What | Where | Fact |
|---|---|---|
| Proxy server image archive | `/scratch/kata-cp/work/phase3-konn/images/registry.k8s.io_kas-network-proxy_proxy-server_v0.34.0.tar` | 31 MB, sha256 `7a0092fa8023d06d28ae9b94f97d698a7596b9af461b69f37bead67dbfe6f209` |
| Proxy agent image archive | `/scratch/kata-cp/work/phase3-konn/images/registry.k8s.io_kas-network-proxy_proxy-agent_v0.34.0.tar` | 31 MB, sha256 `220fea15192dd846b32eacc0cfbd1a2128a52f723905b6ab163b74e2e3df54d2` |
| The two files of the request | `files/egress-selector-configuration.yaml`, `files/konnectivity-server.yaml` | Checked against the code that reads them |
| Request renderer and four rendered requests | `requests/render.sh`, `requests/examples/` | Rendered, decoded into the request type of NVKE |
| Agent manifest for the new cluster | `manifests/konnectivity-agent.yaml.tmpl` | Strict decode passed |
| NetworkPolicy for the host cluster | `manifests/networkpolicy-cp-egress.yaml.tmpl` | Strict decode passed |
| Image contexts and build script | `image/` | The import step passed a build check against the base image |
| Lab driver and the logs watch | `run/konn.sh`, `run/logs-watch.sh` | Not run on the machine. Three parts tested with made-up data |
| Settings | `env-konn.sh` | |
| Copy script for the workstation | `ws-sync.sh` | Not run |

## 3. The two images

### The version

The version is v0.34.0 for both images.

- Kubernetes 1.36.4 builds its API server with the client library `sigs.k8s.io/apiserver-network-proxy/konnectivity-client v0.34.0` (`go.mod:215` at the tag).
- The same tag names `registry.k8s.io/kas-network-proxy/proxy-server:v0.34.0` and `registry.k8s.io/kas-network-proxy/proxy-agent:v0.34.0` in its own manifests (`cluster/gce/manifests/konnectivity-server.yaml:23`, `cluster/gce/addons/konnectivity-agent/konnectivity-agent-ds.yaml:30`). So this is the pair that the Kubernetes release itself runs with that API server.
- The server and the agent then have one version.
- The README of the proxy project says to use the tag with the same minor number as Kubernetes, which is 0.36 for 1.36 (`README.md:27-40` of v0.37.2 in the module cache). Kubernetes 1.36.4 itself does not follow that rule. I took the version of the Kubernetes tree, because it is the one that the client in the API server is.
- The reading read v0.37.2. The module cache has no source of v0.34.0, so the flag check below is on the programs.

### The pulls and the archives

| Image | Digest of the tag | Platform manifest in the archive | Program |
|---|---|---|---|
| `registry.k8s.io/kas-network-proxy/proxy-server:v0.34.0` | `sha256:3d59d59ffa7b8acb8ca56af02b88d64551bbfabcbca10c3e413f36402fe406bd` | `sha256:60cbd3e50b55a8276a950f3d2d146eb2d118db3f662ef007e08d7f6c92df216d` | `/proxy-server`, sha256 `ea3a68c5...`, go1.24.7, client-go v0.34.0 |
| `registry.k8s.io/kas-network-proxy/proxy-agent:v0.34.0` | `sha256:8cc86d24691c4145d1c364eb0846e8865f98b5beab1e6e21b96ceb4dff6fce54` | `sha256:34fb761fe0fd0b5581ff3e58f7cf37206c86fe0935927c27e666bf25aa21129d` | `/proxy-agent`, sha256 `c985159f...`, go1.24.7, client-go v0.34.0 |

- Each pull ran one time, at 20:05, with `--platform linux/amd64` and no Docker login. Each took 2 s.
- Each archive comes from `docker save --platform linux/amd64` and has one manifest, linux/amd64.
- Both images run as the user 65532 and have the program as entry point.

### The flags

I took each program out of its archive and searched it for the flag name and for the help text of the flag in the source of v0.37.2. No program ran, and no container started. The result is in `logs/flags-check.txt`. I removed the two programs after the check.

| Need of the design | Flag | In v0.34.0 |
|---|---|---|
| Three servers behind one address | `--server-count` (server) | Yes, with its help text |
| The right agent for a kubelet call | `--proxy-strategies` (server) | Yes. The help text names `default`, `destHost` and `defaultRoute` |
| The agent port | `--agent-port` (server), `--proxy-server-port` (agent) | Yes |
| The Unix socket mode | `--uds-name`, `--server-port`, `--mode`, `--delete-existing-uds-file` (server) | Yes. The help text of the last one says "Default is true" |
| The certificate and the kubeconfig that exist | `--cluster-cert`, `--cluster-key`, `--kubeconfig` (server) | Yes |
| The token of the agent and its audience | `--agent-namespace`, `--agent-service-account`, `--authentication-audience` (server), `--service-account-token-path` (agent) | Yes |
| A server count that changes | `--sync-forever` (agent) | Yes, with its help text |
| The node address of the agent | `--agent-identifiers` (agent) | Yes. The help text has the form `ipv4=1.2.3.4` |
| Health and admin ports | `--health-port`, `--admin-port` (server), `--health-server-port`, `--admin-server-port` (agent) | Yes |
| Timers of the upstream DaemonSet | `--sync-interval`, `--sync-interval-cap`, `--probe-interval`, `--keepalive-time` (agent) | Yes. The help text of `--keepalive-time` is another one than in v0.37.2. The DaemonSet of Kubernetes 1.36.4 uses the flag with this image |

- Two flags of v0.37.2 are not in v0.34.0, `--graceful-shutdown-timeout` and `--backend-dial-timeout`. The prototype does not use them.
- The scripts of Kubernetes 1.36.4 start the v0.34.0 server with the same flags as the prototype, apart from `--server-count` (`cluster/gce/gci/configure-helper.sh:2027-2070` at the tag). The agent port there is 8132, the health port 8133 and the admin port 8134 (`:2110`).
- A default value is not readable from a program with no run. The prototype sets each value that matters.

## 4. The open points of the reading

| Point of the reading | Answer | Source, and the lab check where the source cannot say |
|---|---|---|
| Which flags of v0.37.2 are in v0.34.0 | Each flag of the prototype | Section 3 |
| Do `bootstrapFiles` of the control plane reach a node that replaces another | Yes | Each control plane node gets its payload from the config snapshot: `ControlPlaneConfigNodeContext` calls `ApplyControlPlaneConfigPayloads`, which copies `BootstrapFiles` and `PreKubeadmCommands` (`controller/internal/nodes/context.go:60-93`, `controller/internal/clients/capi/controlplaneconfig.go:16-33`). `renderBootstrapUserData` writes them for each Machine (`controller/internal/clients/capi/bootstrap_userdata.go:101-109`, `:150-151`). The lab check is `konn.sh facts` on the new node |
| Does the flag reach a node that joins later | Yes | The extra arguments go into the init document only (`controller/internal/temporal/activities/kubeadm_init.go:129`). kubeadm stores it in the ConfigMap, and a join builds the API server manifest from the ConfigMap (lab note, `results/phase2-encryption-join-fix.md`). The API has no way to change the arguments later (`UpdateClusterControlPlaneConfig` has no `apiServer`) |
| Does a PATCH of the machine template drop the files | No | "omitted leaves the stored value alone" (`controller/api/openapi.yaml:3701-3708`) |
| Does `kubeadm reset` empty the manifest folder | Yes | `dirsToClean` starts with the manifest folder, and `CleanDir` removes each file in it (`cmd/kubeadm/app/cmd/phases/reset/cleanupnode.go:57`, `:121`, `:151-160`, `:185` in Kubernetes 1.36.4). `/etc/kubernetes/policies` is not in the list |
| When does the lab agent run `kubeadm reset` on a joining node | Only before a join on a node whose last join failed | `agent/internal/agent/agent.go:644-648`, `:725-735` at `41e88c4d`. A first join runs no reset. After a failed join the static pod manifest is gone, and the flag and the config file stay. That node then has an API server with no proxy server. `konn.sh facts` shows the manifest folder of each node |
| Does `kubeadm init` or `kubeadm join` refuse a manifest folder that is not empty | No | Both check only the four manifest files of kubeadm (`cmd/kubeadm/app/preflight/checks.go:981-984`, `:1083-1090` in Kubernetes 1.36.4) |
| The order of the kubelet start and the files of kubeadm | The certificate and `admin.conf` exist before the kubelet starts | The phase order is certs, kubeconfig, etcd, control plane, kubelet start for `init` (`cmd/kubeadm/app/cmd/init.go:157-163`) and control plane prepare before kubelet start for `join` (`cmd/kubeadm/app/cmd/join.go:222-229`) |
| Can the API server use a socket in a folder that is mounted read only | The source cannot say it for the NVKE folder | NVKE mounts `/etc/kubernetes/policies` into the API server as a folder, read only, with `DirectoryOrCreate` (`controller/internal/kubeadmconfig/init.go:269-275`, and the render check below). The example of the proxy project mounts its socket folder read only (`examples/kind/kind.config` of v0.37.2). The scripts of Kubernetes 1.36.4 mount it with `readOnly: false` (`cluster/gce/gci/configure-kubeapiserver.sh:329`). A connect to a socket needs no write to the filesystem (general knowledge). The lab check is pass rule 2, and the line "lines of the API server about the socket" of `konn.sh facts` |
| Does kindnet of the kind version of the lab apply a NetworkPolicy | Yes | Section 9 |
| Does it apply it to a Kata pod | The source cannot say | The lab check is `konn.sh reach` (section 9) |
| Does MetalLB give one address to two Services | Not needed | The prototype adds a port to the one Service that exists |
| Does an open tunnel stay when a pod leaves the Service | Not settled | General knowledge of kube-proxy. `konn.sh facts` counts the tunnels of each server |
| Does the proxy server keep working after a certificate renewal | Not settled, and left out by the design | |

The render check (tested here). I ran the renderer of the lab commit with the flag, for Kubernetes 1.36.4, in a temporary copy of the commit. The log is `logs/nvke-render-check.txt`.

- `ValidateExtraArgs` accepts `egress-selector-config-file`. It refuses a flag that NVKE sets, for example `audit-policy-file`.
- The `ClusterConfiguration` (v1beta4) has the flag with the value of the request, and three volumes: `audit-logs`, `audit-policies` (`/etc/kubernetes/policies`, read only) and `oidc-auth-config`.
- The files that NVKE itself sends to the agent before `kubeadm init` are two patch files, `/etc/kubernetes/policies/audit-policy.yaml` and `/etc/kubernetes/oidc/auth-config.yaml`. The agent writes each file by its path and removes nothing else in the folder (`agent/internal/agent/kubeadm_prerequisite_files.go:43-59`).

## 5. The request

`requests/render.sh <variant> <out folder> [workers]` makes the request. It calls the render script of phase 3 as it is at that moment (`/root/kata-cp/p3/requests/render.sh cluster`) and adds to its output. So a change of the lab templates comes through.

| Variant | What it adds to the request of phase 3 | Use |
|---|---|---|
| `direct` | Nothing | Pass rule 1. The API server calls a kubelet directly |
| `proxy` | The flag and the two files | Pass rules 2 to 4 |
| `direct-route`, `proxy-route` | The same, and one command for each control plane node | Only when the NetworkPolicy has no effect on a Kata pod (section 9) |

The additions of `proxy`:

- `controlPlaneConfig.apiServer.extraArgs["egress-selector-config-file"]` is `/etc/kubernetes/policies/egress-selector-configuration.yaml`.
- `controlPlaneConfig.infra.bootstrapFiles` has two entries, each with `path`, `owner` (`root:root`), `permissions` and `content`. The first is the egress selector config (mode 0644, 959 characters). The second is `/etc/kubernetes/manifests/konnectivity-server.yaml` (mode 0600, 2878 characters).

The checks of the keys (tested here, `logs/files-check.txt`):

- Each of the four rendered requests decodes into `api.CreateClusterRequest` of the lab commit with unknown fields refused, and passes `ValidateExtraArgs`.
- `ControlPlaneComponentConfig.extraArgs` is a map of strings (`controller/api/openapi.yaml:1219-1236`). A flag name has no leading `--` (`controller/internal/kubeadmconfig/extra_args.go:75-80`).
- A file has at most 10240 characters and a path of at most 512 (`CloudInitFile`, `controller/api/openapi.yaml:1774-1801`). The create handler refuses only the two SPIRE paths and a path that is there two times (`controller/internal/server/node_pools.go:226-245`).
- The pod image needs `owner` and `permissions` in each file, so the request sets both.
- The cloud-config text that NVKE makes from the two files passes through the bootstrap program of the pod image, and both files come out byte for byte with their modes. I built a copy of that program from `p2-image/bootstrap` and ran it against a test folder.
- The egress selector config passes the reader and the checks of the API server library (`k8s.io/apiserver` v0.37.2 of the module cache, the version that the lab controller is built with. The reading found no difference of that package between 1.36.4 and its checkout).

The next table says what NVKE does with the two parts.

| Moment | The flag | The two files |
|---|---|---|
| First node | NVKE puts it into the `ClusterConfiguration` of `kubeadm init`. kubeadm writes it into the API server manifest and stores the document in the ConfigMap | The bootstrap data of the Machine has them. The pod image writes them before the SPIRE agent and the NVKE agent start |
| A join of a control plane node | kubeadm reads the ConfigMap and writes the same manifest | The same, from the config snapshot of the node |
| A node that replaces another, a rollout, a higher count | The same as a join | The same as a join |
| A join after a failed join on the same node | The same | The config file stays. `kubeadm reset` removes the static pod manifest (section 4) |
| A new pod of the same Machine | The manifest is on the volume of the Machine | The files phase of the pod image writes only a file that is absent (`p2-image/bootstrap/main.go:9-11`), so a manifest that a reset removed comes back at the next start of the pod |

The worker pool of the request is the pool of phase 3 with no change. The one network of a worker is a setting of the simulator (section 9).

## 6. The proxy server static pod

The file is `files/konnectivity-server.yaml`. A strict decode into the Pod type passes (tested here).

| Setting | Value | Reason |
|---|---|---|
| Host network | Yes | The agents reach port 8132 on the pod address of the control plane pod, through the lab Service |
| Image | `registry.k8s.io/kas-network-proxy/proxy-server:v0.34.0`, `IfNotPresent` | It is in the containerd store of the pod image p11 |
| User | 0 | The image runs as 65532. The key of the API server and `admin.conf` are files of root with mode 0600. The example of the proxy project does the same |
| `--uds-name`, `--server-port=0`, `--mode=grpc` | `/etc/kubernetes/policies/konnectivity/konnectivity-server.socket` | The Unix socket for the API server, in a folder below the folder that NVKE mounts |
| `--agent-port`, `--health-port`, `--admin-port` | 8132, 8133, 8134 | The numbers of the scripts of Kubernetes 1.36.4. The NVKE source uses none of them (reading) |
| `--cluster-cert`, `--cluster-key` | `apiserver.crt` and its key | The certificate that exists. It has the host of `controlPlaneEndpoint` (reading) |
| `--kubeconfig` | `/etc/kubernetes/admin.conf` | For the TokenReview. A lab shortcut |
| `--agent-namespace`, `--agent-service-account`, `--authentication-audience` | `kube-system`, `konnectivity-agent`, `system:konnectivity-server` | The token form |
| `--server-count` | 3 | Section below |
| `--proxy-strategies` | `destHost,default` | A kubelet call goes to the agent of that node. A call to a pod address goes to any agent |
| Volumes | `/etc/kubernetes` read only, and the socket folder read and write with `DirectoryOrCreate` | The form of the example of the proxy project. A folder mount keeps working when a file in it is replaced |
| Liveness probe | `/healthz` on `127.0.0.1:8133` | `/readyz` answers only with an agent (reading, v0.37.2), so it is not a probe |

A fourth control plane node, as in a rollout or a higher count:

- Each server tells each agent the count of its flag, which is 3 (reading).
- An agent with `--sync-forever` dials the shared address again at each sync interval (5 s), also when it has three servers. It keeps a connection to a server that it does not know and closes one to a server that it knows (`pkg/agent/clientset.go:248-311` of v0.37.2). So it finds the fourth server after some tries, each with a chance of one in four (deduction, about 20 s as a mean).
- Without `--sync-forever` an agent with three servers stops, and the fourth server gets no agent until an old server goes away (`clientset.go:295-297`).
- Until an agent has found the new server, the API server of that node answers each `cluster` call with "No agent available" (reading). The pod is ready as soon as its API server answers `/readyz`, so the lab Service already sends API calls to it. `konn.sh logs-watch` shows that window.
- When an old node goes away, its tunnels close, and each agent has three servers again.
- Each extra dial is one TLS connection and one TokenReview. That is fine for two workers.

## 7. The agent

The file is `manifests/konnectivity-agent.yaml.tmpl`, a ServiceAccount and a DaemonSet for the new cluster. A strict decode of both passes (tested here).

- The base is the DaemonSet of Kubernetes 1.36.4 (`cluster/gce/addons/konnectivity-agent/konnectivity-agent-ds.yaml`).
- The changes are the host network, a node affinity for nodes with no control plane label, a toleration for each taint, `--sync-forever=true`, and the pull policy `IfNotPresent`.
- It dials `172.29.255.220:8132`. It checks the server certificate with the CA file of its service account volume.
- The token comes from a projected volume with the audience `system:konnectivity-server`.
- `--agent-identifiers=ipv4=$(HOST_IP)` gives the node address of the worker, which is the address that the API server asks for.
- For RBAC, the proxy server makes the TokenReview with `admin.conf`, which has that right. So the ServiceAccount is the only object beside the DaemonSet. The upstream binding of the user `system:konnectivity-server` to `system:auth-delegator` is for a server with a kubeconfig of its own.

How the lab applies it. NVKE has no step for it in this prototype. `konn.sh agent <run> apply` fetches the kubeconfig of the new cluster with the lab step `p3ab.sh kc`, fills the address and the port into the template, and runs `kubectl apply` against the shared address. Before that step the cluster has no agent, and each `cluster` call fails (reading).

## 8. The shared address

The lab Service is `cp-api` in the namespace `d`, a LoadBalancer with one port, 6443 (`p2-provider/api-service.yaml.tmpl`). `konn.sh port add` adds one entry with a JSON patch: name `konnectivity`, port 8132, target port 8132, TCP. `konn.sh port remove` takes it away, after a test that the entry has that port.

- The base step of the lab applies the Service file again at each POST. A `kubectl apply` removes only what an earlier apply set, so the added port stays (deduction).
- The first port has a name already, which a Service with two ports needs.
- MetalLB in layer 2 mode answers for the address, not for a port (general knowledge). kube-proxy in each kind node makes the rules for each port of the address. The Service has `allocateLoadBalancerNodePorts: false`, so no node port is involved.
- The traffic policy must be `Cluster`. It is the default of the lab scripts (`d/endpoint-run/run.sh:45`). With `Cluster` the kind node that holds the address sends a new connection to any ready pod and replaces the source address. With `Local` an agent reaches only the servers on one kind node, and the fallback route of section 9 does not work. `konn.sh port status` prints the value.
- A pod has one readiness. It is the probe program of the pod provider, which reads the gate file and `/readyz` of the local API server (reading). So port 8132 goes to a pod when its API server is ready. It says nothing about the proxy server.
- A proxy server that does not run on a ready pod gives a refused connection to an agent, and the agent dials again.

## 9. The unreachable worker

### One network for a worker

`konn.sh sim start` starts the simulator container again with the command of step B of the lab and these changes. `konn.sh sim diff` prints the difference against the lab command of that moment.

| Setting | Step B of the lab | This test |
|---|---|---|
| `NICO_CONTAINERS_NODE_NETWORK` | `kata-bb-node` | `kata-bb` |
| `P3_NODE_NET` | `kata-bb-node` | `kata-bb` |
| `P3_NODE_IP_PREFIX` | `172.28.2` | `172.29.2` |
| `P3_API_NET`, `P3_API_IP_PREFIX`, `P3_API_IFNAME` | `kata-bb`, `172.29.2`, `eth1` | Empty, not set, not set |
| `P3_FORBIDDEN_PREFIXES` | Not set | `172.29.0 172.29.255`, the range that Docker gives out on `kata-bb` and the range of MetalLB |
| `NICO_CONTAINERS_NODE_IMAGE` | `nvke-node-nico:bcc4376f-w1` | `nvke-node-nico:bcc4376f-w2` |

- The program `docker-two-nets` has no change. With these settings and its own fake docker it makes one network argument, `name=kata-bb,ip=172.29.2.11,driver-opt=com.docker.network.endpoint.ifname=eth0`, and the hosts line. The second worker gets `.12`. It refuses the prefix `172.29.0` (tested here).
- The simulator has `172.29.2.5`, and the workers start at `.11`.
- `konn.sh sim start` refuses to start while a simulator container or a worker container exists.

### The NetworkPolicy

`konn.sh policy apply` makes `p3-konn-no-way-to-workers` in the namespace `d`. It selects each pod with the label `cluster.x-k8s.io/control-plane`, has the type `Egress`, and allows `0.0.0.0/0` except `172.29.2.0/24`.

- The simulator is in the same block. No control plane pod calls it.
- The NVKE controller is in another namespace, so the policy does not select it.

What the source says about the network plugin:

- The host cluster uses kindnet of kind v0.33.0 (lab note). Its manifest gives kindnet the right to list and watch `networkpolicies` (`pkg/build/nodeimage/const_cni.go:54-60` of kind v0.33.0 in the module cache).
- kindnet runs the controller of `sigs.k8s.io/kube-network-policies` with an nftables table of the name `kindnet-network-policies` and a packet queue (`images/kindnetd/cmd/kindnetd/main.go:221-244` of the local kind checkout, which is near v0.32).
- The controller has `FailOpen: true`. If it does not run, each packet passes. A policy with no effect looks the same as no policy.
- The source of the policy library is not in the module cache. So I could not read how it finds the packets of a pod, and a Kata pod is not shown.

The first lab check is `konn.sh reach <run> <label>`. From each control plane pod it opens a new connection to port 10250 of each worker. From the kind node of the NVKE controller it opens one to port 15005 of each worker.

1. With the policy, no connection from a control plane pod gets an answer.
2. After `konn.sh policy delete`, each one gets an answer. So the policy is the cause.
3. After `konn.sh policy apply`, none gets an answer again.
4. In each of the three looks the kind node reaches port 15005, and NVKE shows `nodeAgentReady`.

The policy stops only a new connection. An API server can hold a connection to a kubelet that it opened before. So the policy is there before the POST, and between look 2 and look 3 nobody runs `logs` or `exec`.

### The fallback

If look 1 shows answers, the policy has no effect on a Kata pod. Then the variants `direct-route` and `proxy-route` add one command for each control plane node, `ip route replace blackhole 172.29.2.0/24`, in `controlPlaneConfig.infra.preKubeadmCommands`.

- The route is in the Kata guest only.
- It needs the traffic policy `Cluster`. Then a connection that a worker opens to the shared address arrives with the address of a kind node, and the answer does not meet the route (reading).
- The pod image runs the commands one time for a Machine, so a new pod of the same Machine has no route (lab note).
- `konn.sh reach` prints the routes of each control plane pod to the block.

## 10. The image contexts

| Tag | From | Change | Where it must be |
|---|---|---|---|
| `nvke-node-podvm:bcc4376f-p11` | `nvke-node-podvm:bcc4376f-p10` | The proxy server image in the containerd store | In the three host nodes |
| `nvke-node-nico:bcc4376f-w2` | `nvke-node-nico:bcc4376f-w1` | The proxy agent image in the containerd store | In Docker of the machine |

- `image/build-konn-images.sh` builds both on the machine with `docker build --network none`, checks the archive checksums, and loads p11 into the host nodes in the way of `p2-gaps/image/build-encfix.sh`.
- `image/import-images.sh` is the import step. It is the step of `p2-image/Dockerfile` and of the worker image of phase 3: containerd runs in the build container, `ctr images import --no-unpack`, a check of the image name, containerd stops.
- A build check on the workstation passed at 20:18 in 4 s (tested here). It ran the import step with both archives against the base image `nvke-node:bcc4376f-amd64`, which has the containerd of both images (2.3.4), with the legacy builder and no network. Both images were in the store under their names. I removed the check image.
- The two real builds are not done. The images p10 and w1 are on the machine only.
- A third tag is not needed and not prepared. Davanum allowed two tags.

## 11. The checks for the four pass rules

`K` is `/root/kata-cp/p3-konn/run/konn.sh`. `P3AB` is `/root/kata-cp/p3/run/p3ab.sh`.

| Pass rule | Check | What it must show |
|---|---|---|
| 1. With the policy and no proxy the calls fail | `$K rule <run> baseline fail` on a cluster of the variant `direct` | Each `logs`, `exec` and port forward through each API server fails. The step runs the lab check `rule3` and counts its lines |
| 2. With the proxy they pass, and the kubelet sees its own node | `$K rule <run> proxy pass` on a cluster of the variant `proxy` | Each check is ok, and each list "the kubelet of the worker sees the call from" has only the node address of that worker |
| 3. A node that NVKE makes later has the flag, the file and a proxy in use | `$K cp-count <run> 4`, then `$K facts`, `$K rule <run> four pass`, and the logs watch | The new node has the flag in its manifest and in its API server process, both files, a proxy container, the socket and tunnels. The calls pass through each of the four API servers |
| 4. What still fails | `$K still <run> <label>` | A list with "as expected" or "DIFFERENT" for each line |

The watch for a proxy server with no agent is `$K logs-watch <run> start 5`. It runs `kubectl logs` of the test pod on the first worker through each API server each 5 s, and reads the list of the control plane nodes again in each round. `$K logs-watch <run> stop` ends it and prints one line for each time range with the same answer for each API server.

What `still` expects, from the design and the reading:

- Pod traffic between a pod on a worker and a pod on a control plane node fails, in both directions.
- The API Service and a name lookup from a pod on a worker fail.
- `logs` of a pod on a control plane node fails through each API server. This is new with the proxy. Each kubelet call goes through an agent, the agents are on the workers, and a worker does not reach a control plane node (reading, section 5).
- `exec` into a pod on a worker works.
- NVKE and Kubernetes show each node as good.

The last point on control plane pods matters for the lab scripts. The step `traffic` of `p3ab.sh` runs `kubectl exec` in the test pod of each node, also on a control plane node. With the proxy that part fails. `tpods` and `rule3` do not need it.

Tests of the driver on the workstation (tested here, with made-up data and stand-in programs):

- The verdict of `rule`, against five made-up outputs in the form of `rule3`. It gave PASS for 18 failed checks with the expectation `fail`, PASS for 18 good checks with the own address, and FAIL for good checks from another address and for good checks with the expectation `fail`.
- `logs-watch.sh` with a stand-in `kubectl`, and the summary. A fourth node appeared, answered "No agent available" four times and then ok. The summary showed that range.
- `sim command` and `sim diff`.

Each other step of `konn.sh` ran nowhere. `bash -n` and `shellcheck` pass.

## 12. The order of work on the machine

Each change of this section is in the list that Davanum allowed: the two image tags, the delete of the mixed cluster, one NetworkPolicy, one more port on the lab Service. The simulator container starts again with other settings. It is the container of phase 3.
`K` and `P3AB` are as above. `G` is `/root/kata-cp/p2-gaps`, `L` is `/root/kata-cp/logs/p3`.

### On the workstation

The commands run from `/scratch/kata-cp/work/phase3-konn/remote/p3-konn/`.

```
./ws-sync.sh scripts
./ws-sync.sh images
```

### Step 0, reads only

```
$K port status
$K policy status
$K sim diff
docker image inspect nvke-node-podvm:bcc4376f-p10 nvke-node-nico:bcc4376f-w1 --format '{{.RepoTags}} {{.Id}}'
df -h /root
```

What to look for:

- The traffic policy of the Service is `Cluster`, and it has one port.
- No NetworkPolicy is in the host cluster.
- `sim diff` shows only the lines of section 9.

### Step 1, the two image tags

```
/root/kata-cp/p3-konn/image/build-konn-images.sh all
```

### Step 2, the mixed cluster that is up goes away through the NVKE API

`<run>` is the run folder of that cluster.

```
$P3AB stop-watches <run>
LOG_DIR=$L/<run> $G/run.sh delete >$L/<run>/delete.out 2>&1
/root/kata-cp/p2-provider/storage.sh reset
bash /root/kata-cp/p3/run/after-delete.sh <run>
```

### Step 3, the simulator with one network, and the policy

```
/root/kata-cp/p3/sim/run-sim.sh remove
$K sim start
$K policy apply
```

### Step 4, the cluster with no proxy (pass rule 1)

```
$K post k-1 direct 2
$P3AB watch k-1 1500 5
$P3AB kc k-1
$P3AB tpods k-1
$K reach k-1 policy
$K policy delete
$K reach k-1 no-policy
$K policy apply
$K reach k-1 policy-again
$K rule k-1 baseline fail
```

- `reach` must give 0 of 6, then 6 of 6, then 0 of 6.
- If the first `reach` gives answers, stop here. Delete the cluster (step 5), run `$K policy delete`, and use the variant `direct-route` in this step and `proxy-route` in step 6.
- `rule` takes some minutes, because each of the 18 calls runs into its time limit.

### Step 5, that cluster goes away

```
$P3AB stop-watches k-1
LOG_DIR=$L/k-1 $G/run.sh delete >$L/k-1/delete.out 2>&1
/root/kata-cp/p2-provider/storage.sh reset
bash /root/kata-cp/p3/run/after-delete.sh k-1
```

### Step 6, the cluster with the proxy (pass rule 2)

```
$K post k-2 proxy 2
$P3AB watch k-2 1500 5
$P3AB kc k-2
$K facts k-2 before-agent
$K agent k-2 apply
$K facts k-2 with-agent
$P3AB tpods k-2
$K reach k-2 proxy
$K rule k-2 proxy pass
$K logs-watch k-2 start 5
```

- `post` adds the port 8132 to the Service before the POST.
- `facts` must show for each control plane node the flag, both files with the checksums of this folder, a running proxy container, the socket, a listener on 8132, and after the agent two tunnels.
- `reach` must still give 0 of 6. The direct way stays closed.

### Step 7, a fourth control plane node (pass rule 3)

```
$K cp-count k-2 4
$P3AB watch k-2 900 6
$K facts k-2 four
$K rule k-2 four pass
$P3AB node-delete k-2 <name of an old control plane node> cp-delete
$P3AB watch k-2 900 6 <name of that node>
$K facts k-2 replaced
$K rule k-2 replaced pass
$K cp-count k-2 3
$P3AB watch k-2 600 5
$K logs-watch k-2 stop
```

- The lab storage has six Machine places, and three are free, because a worker of the simulator holds none.
- With four nodes NVKE takes a delete of a control plane node and makes a new one (lab note, `lab/phase2-replace-run/result.md`, section 4). That new node is the node that replaces another.
- The summary of the logs watch shows how long a new node answered "No agent available".

### Step 8, what still fails (pass rule 4)

```
$K still k-2 proxy
$P3AB snap k-2 end
```

### Step 9, the way back to the direct form

```
$P3AB stop-watches k-2
LOG_DIR=$L/k-2 $G/run.sh delete >$L/k-2/delete.out 2>&1
/root/kata-cp/p2-provider/storage.sh reset
bash /root/kata-cp/p3/run/after-delete.sh k-2
$K policy delete
$K port remove
/root/kata-cp/p3/sim/run-sim.sh remove
/root/kata-cp/p3/sim/run-sim.sh start b
$K port status
$K policy status
```

After it the lab is in the form of phase 3 with no cluster. A new mixed cluster is `$P3AB post <run> 2` of the lab, with the pod image p10 or p11. The two new tags stay. They differ from p10 and w1 by one image in the store.

## 13. Deductions that the lab must prove first

1. kindnet applies the policy to a Kata pod. Step 4, the three `reach` looks.
2. The policy does not stop the NVKE controller and the answers to a worker. Step 4, the cluster comes up with the policy in place.
3. The Service keeps the added port through the base step of a later POST, and kube-proxy sends port 8132 to each ready control plane pod. `$K port status`, and the tunnel count of `facts`.
4. The API server connects to a socket in a folder below `/etc/kubernetes/policies` through the read only mount. Pass rule 2.
5. The static pod starts on each control plane node: the image is in the store of p11, the kubelet accepts the manifest of the bootstrap data, and the proxy server runs as root with the certificate and `admin.conf`. `facts`.
6. The proxy server of v0.34.0 accepts the flag set of the prototype. I read the checks of v0.37.2 only (`cmd/server/app/options/options.go:266-335`). `facts`, the proxy container and its last lines.
7. The ports 8132 to 8134 are free in a control plane guest, and 8093 and 8094 on a worker.
8. NVKE brings the cluster to five good nodes with the flag and with no agent yet. No step of NVKE needs a call from the API server to a kubelet (deduction from the reading).
9. The agent pod starts on a worker with one network: the image is in the store of w2, and the kubelet gets the token through the shared address.
10. Each agent gets a tunnel to each of the three servers through the one address. `facts` shows the tunnel count of each server and the connections of each agent.
11. With `destHost` the call for a kubelet goes to the agent of that worker, and the kubelet sees its own node address. Pass rule 2, with two workers.
12. `--sync-forever` of v0.34.0 works as in v0.37.2, so an agent finds a fourth server. Step 7.
13. A PATCH of the control plane count keeps the files and the commands of the control plane config. Step 7, `facts` on the new node.
14. With the fallback route, the answers of a control plane node to a worker pass, because the traffic policy is `Cluster`. Only if the fallback is used.

## 14. Open points

1. A join that fails leaves a control plane node with the flag, the config file and no proxy server, after the reset of the next try. A product form needs the manifest in the file list of the join request (reading, variant N).
2. Before the agent DaemonSet is applied, and before the first worker joins, each `cluster` call fails.
3. `logs` and `exec` for a pod on a control plane node fail in this form. A second agent DaemonSet on the control plane nodes would repair it. It is not in the design.
4. The proxy server uses `admin.conf` and runs as root with the whole `/etc/kubernetes` folder, read only. It is a lab shortcut.
5. A tenant with admin rights can make a token for the agent service account and connect an agent of its own (reading).
6. The NetworkPolicy block has the address of the simulator.
7. The lab step `traffic` cannot run as it is on a cluster with the proxy (section 11).
8. `rule` reads the output form of the lab step `rule3`. If the lab agent changes that form, the verdict of `rule` needs the same change. The file `rule3-<label>.txt` stays the evidence.
9. I did not read the source of v0.34.0 of the proxy project, and not the source of the policy library of kindnet.

## 15. Points to decide

1. The version. v0.34.0 is the version of the Kubernetes 1.36.4 tree. The README rule of the proxy project gives 0.36. The archives are v0.34.0.
2. The fallback. If the NetworkPolicy has no effect on a Kata pod, the route command needs two more clusters with the `route` variants. It is in the design. Say if the lab may go on with it without a new word.
3. Pass rule 3 with a fourth node and a node delete (prepared), or with a rollout to a second pod image tag. The rollout needs a third image tag, which is not in the list that Davanum allowed.
4. If a mixed cluster must be up at the end, and with which pod image.
5. The agent on the workers only, as the design says. Then `logs` for a pod on a control plane node fails during the test.

## 16. Changes on the machine and how to remove them

From this task nothing is there. The table is for the test.

| Change | Removal |
|---|---|
| `/root/kata-cp/p3-konn`, and run folders `k-1`, `k-2` in `/root/kata-cp/logs/p3` | Remove the folders |
| Two archives in `/root/kata-cp/dl/img/`, and the archive of p11 that `img-load.sh` makes | `unlink` |
| Images `nvke-node-podvm:bcc4376f-p11` (Docker and the three host nodes) and `nvke-node-nico:bcc4376f-w2` (Docker) | `docker rmi`, `ctr -n k8s.io images rm` in each node |
| Build contexts `/root/kata-cp/work/p3konn-pod-image-ctx` and `p3konn-worker-image-ctx` | Remove the folders |
| The NetworkPolicy `p3-konn-no-way-to-workers` in `d` | `$K policy delete` |
| The port 8132 of the Service `cp-api` | `$K port remove` |
| The simulator container with the one network settings | `run-sim.sh remove`, then `run-sim.sh start b` |
| The clusters of the test, with the agent DaemonSet inside | The delete through the NVKE API |

## 17. What I did not do, and what failed

- No command ran on the second machine. Each fact about it comes from the lab notes.
- The two real image builds are not done. The base tags are on the machine only.
- `konn.sh`, `build-konn-images.sh` and `ws-sync.sh` did not run on the machine. A fault that only a run shows is possible, most of all in the steps `facts`, `reach` and `still`, which run commands in a guest.
- No proxy server and no agent ran. The flag check is a search in the two programs.
- I did not download the source of v0.34.0. The task allowed two image pulls and nothing else.
- The first run of the file check did not compile, because I wrote a field name of the request type wrong. I corrected it and ran it again.
- The first form of `konn.sh` had a syntax fault in one line (a column list with no quotes). `bash -n` found it.
- For the two checks with NVKE code I made a temporary copy of five folders of the lab commit with `git archive`. It had no file with the bash network socket device path form. I removed it after the checks.
