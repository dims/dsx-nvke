# Phase 3 source reading for a Konnectivity prototype

State on 2026-11-27 at 19:54 EST. The reading started at 19:27 EST. I read source and notes only. I changed no code, and I ran no cluster, no container and no test. I ran one read-only Docker command on the workstation, an image list. In the source checkouts I ran only git commands that read (log, describe, status, tag list, show, diff and grep).

Davanum chose a Konnectivity prototype for later, with a short design first and his word before any code. This note is the base of that design. The direct path works in the lab (`lab/phase3-run/result-AB.md`, sections 4 and 7).

The marks of this note:

- A statement with a file reference comes from the source at that place.
- "(deduction)" is on a statement that I conclude and that no source states.
- "(general knowledge)" is on a statement that I know and did not read in a source here.
- "(lab note)" is on a fact of an earlier lab note.

What I read, with the short names that the references use:

- `$R` is the NVKE checkout `/home/dsrinivas/go/src/github.com/nvidia/nvke` at `d625fcfa`. `$C` is `$R/controller/internal`. `$A` is `$R/agent/internal/agent`.
- `$E` is the lab branch with `controlPlaneEndpoint`, `/scratch/kata-cp/src/nvke-endpoint` at `c6d669ef`.
- `$P` is the pod provider, `/scratch/kata-cp/src/nvke-podvm/cluster-api-provider-podvm` at `d2880014`.
- `$K` is the Kubernetes checkout `/home/dsrinivas/go/src/k8s.io/kubernetes` at `057137c2889`. `git describe` gives `v1.38.0-alpha.2-199-g057137c2889`, the branch is master, and the last commit is of 2026-10-13. `$KS` is `$K/staging/src/k8s.io/apiserver/pkg`. Line numbers are the lines of this checkout.
- The lab cluster runs Kubernetes 1.36.4. The tag `v1.36.4` is in the checkout. The egress selector package, its flag code and the kubelet client have no difference between the tag and the checkout. The tag has the same 13 use sites of the three names.
- `$X` is `sigs.k8s.io/apiserver-network-proxy` at `v0.37.2` in the Go module cache. It is the full module with the server and the agent, not only the client library. Four files have short names of their own. `$XO` is `$X/cmd/server/app/options/options.go`, the flags of the server. `$XM` is `$X/cmd/server/app/server.go`, the start of the server. `$XP` is `$X/pkg/server/server.go`, the proxy code. `$XAO` is `$X/cmd/agent/app/options/options.go`, the flags of the agent. Kubernetes 1.36.4 pins `v0.34.0` of the client and of the two images (`go.mod:215` and `cluster/gce/manifests/konnectivity-server.yaml:23` at the tag). I did not read `v0.34.0`.
- `$L` is `/home/dsrinivas/notes/hosted/lab`.

I did not read `/home/dsrinivas/notes/hosted/context/`. I made no web search and no download.

## Summary

- The API server has three named kinds of outgoing connections. They are `cluster`, `controlplane` and `etcd`. Only `cluster` needs the proxy. It holds each call to a kubelet, to a pod, to a Service and to a node port.
- kubeadm has no code for Konnectivity. A kubeadm cluster gets it through one API server flag, one volume and one file, plus a proxy server and an agent that somebody else installs.
- NVKE can put the flag, the volume, the config file and a static pod manifest onto each control plane node with code paths that exist today. The node agent needs no change for a prototype (deduction).
- A variant with no NVKE code exists for the lab. The request can carry the flag and the files (deduction, not tested).
- The agents need a second port on the shared address. The lab Service gets one more port. The request needs no new field for a prototype.
- Konnectivity repairs only the calls from the API server to the nodes. With an unreachable worker the pod network between that worker and the control plane nodes stays broken, and a pod on the worker does not reach the API Service (lab note and deduction).
- Konnectivity does not carry the calls of the NVKE controller to port 15005 of a node.
- For the test, a worker on `kata-bb` alone and one NetworkPolicy in the host cluster make an unreachable worker with no change on the machine (deduction, the first lab step must check it).

## 1. What goes through the egress selector

### The three names

- The names are `controlplane`, `etcd` and `cluster` (`$KS/server/egressselector/egress_selector.go:61-68`, `:82-93`, and `config.go:36`).
- Each name gets one connection kind from the config file. The kinds are `Direct`, `HTTPConnect` over a Unix socket or over TCP with TLS, and `GRPC` over a Unix socket only (`egress_selector.go:316-369`).
- With no flag the API server has no selector and each caller uses its normal dialer (`egress_selector.go:374-378`, `$K/cmd/kube-apiserver/app/server.go:265`).
- A name that the file does not list gets no dialer, and the caller then connects directly (`egress_selector.go:408-415`, `$K/pkg/kubelet/client/kubelet_client.go:107-109`).

### What is in the `cluster` set

| Call | Where the source picks `cluster` |
|---|---|
| The kubelet client of the API server | `$K/pkg/kubelet/client/kubelet_client.go:99-110` |
| Pod logs | `$K/pkg/registry/core/pod/strategy.go:632-695`, with the kubelet transport |
| Pod exec, attach and port forward | `pod/strategy.go:757-857`, wired in `$K/pkg/registry/core/pod/storage/storage.go:124-128` |
| The `proxy` subresource of a pod and of a Service | `$K/cmd/kube-apiserver/app/server.go:268-277`, used in `pod/rest/subresources.go:81` and `$K/pkg/registry/core/service/proxy.go:71` |
| The `proxy` subresource of a node | `$K/pkg/registry/core/node/strategy.go:264-293`. The kubelet port uses the kubelet transport (`:282-289`). Another port uses the proxy transport (`:292`) |
| An admission webhook that names a Service | `$KS/util/webhook/authentication.go:75-97`, the lookup is at `:86` |
| An aggregated API server | `$K/staging/src/k8s.io/kube-aggregator/pkg/apiserver/apiserver.go:237-248` |
| An OIDC issuer, only when the authentication config asks for `cluster` | `$K/staging/src/k8s.io/apiserver/plugin/pkg/authenticator/token/oidc/oidc.go:327-335` |

- Kubelet metrics have no call of their own in the API server. A caller reads them through the node proxy, which is in the table (deduction).
- A metrics server is an aggregated API, so the call of the API server to it is in the table. Its own calls to the kubelets start in its pod and do not use the selector (general knowledge).
- A conversion webhook of a CRD that names a Service uses the same resolver (deduction).

### What does not go through `cluster`

- An admission webhook that names a URL uses `controlplane` (`$KS/util/webhook/authentication.go:52-73`, the lookup is at `:63`).
- The authentication webhook, the authorization webhook, the audit webhook, the tracing exporter and the call to a peer API server use `controlplane` (`$K/pkg/kubeapiserver/options/authentication.go:737-744`, `$K/pkg/controlplane/apiserver/config.go:265-271`, `$KS/server/options/audit.go:309-315`, `$KS/server/options/tracing.go:101-104`, `$K/pkg/controlplane/apiserver/peer.go:75-85`).
- The etcd client uses `etcd` (`$KS/storage/storagebackend/factory/etcd3.go:301-308`).
- An OIDC issuer with no `egressSelectorType` uses the normal dialer (`oidc.go:327-330`). NVKE does not set that field. A search of `$C/kubeadmconfig` finds nothing.
- The upstream examples give `controlplane` and `etcd` the kind `Direct` (`$K/cluster/gce/gci/configure-helper.sh:1027-1032`).
- Nothing that comes in to the API server uses the selector. That holds for the kubelets, the controllers, `kubectl` and the NVKE controller (deduction).
- The selector is in the API server only. The controller manager and the scheduler have no selector (deduction from the search of `$K`).

### What the API server needs

- One flag, `--egress-selector-config-file` (`$KS/server/options/egress_selector.go:51-52`).
- The file must exist at the start, or the API server stops (`options/egress_selector.go:88-90`). The file is decoded in strict mode and then checked (`config.go:57`, `:72-116`).
- The file is an `EgressSelectorConfiguration` of `apiserver.k8s.io/v1beta1` (`$KS/apis/apiserver/v1beta1/types.go:26-125`, example in `configure-helper.sh:1018-1032`).
- For a Unix socket the file names the socket path. The API server dials the socket at each call (`egress_selector.go:202-209`, `:217-241`). So the socket can come after the API server start (deduction).
- For TCP the file names a URL, a CA file, a client certificate and a client key. The three files must exist at the start (`config.go:207-246`).
- The API server pod needs a volume for the file and for the socket. The upstream kind example mounts the socket folder read-only (`$X/examples/kind/kind.config:13-27`).
- The target of a call does not change. The API server still asks for the InternalIP of the Node with the kubelet port, and it still checks the kubelet certificate (`$K/cmd/kubeadm/app/phases/controlplane/manifests.go:201`, `$C/kubeadmconfig/init.go:251`) (deduction).

## 2. The parts of a setup

### The proxy server

- Upstream runs it beside each API server. The Google Compute Engine scripts run it as a static pod with the host network (`$K/cluster/gce/manifests/konnectivity-server.yaml:1-67`). The kind example runs it as a DaemonSet with the host network on the control plane nodes (`$X/examples/kind/konnectivity-server.yaml:30-126`).
- The API server talks to it over a Unix socket in a shared host folder, with `--uds-name` and `--server-port=0` (`configure-helper.sh:1943`, `:1956`). The other form is a TCP port with TLS in both directions. Without a socket name the server needs a CA for its clients (`$XO:273-290`).
- The mode is `grpc` or `http-connect` (`$XO:270-272`). The API server supports `GRPC` only over a socket (`egress_selector.go:351-363`).
- It listens for agents on the agent port. The default is 8091 (`$XO:412`). The Google Compute Engine scripts use 8132 for the agents, 8133 for the health port and 8134 for the admin port (`configure-helper.sh:1932-1934`, `:1977-1979`, `:2022`).
- It shows its certificate to the agents from `--cluster-cert` and `--cluster-key` (`$XM:501-510`). It reads the pair one time at its start (`$XM:408-412`).
- The health port answers `/healthz` always and `/readyz` only with one agent or more (`$XM:569-589`, `$X/pkg/server/readiness_manager.go:28-33`).

### The agent

- It runs on the nodes and dials out to one host and one port, `--proxy-server-host` and `--proxy-server-port` (`$XAO:129-130`).
- It checks the server certificate with `--ca-cert`. The examples give it the CA file of the service account volume, which is the cluster CA (`$K/cluster/gce/addons/konnectivity-agent/konnectivity-agent-ds.yaml:35`).
- It proves its identity with a service account token from a projected volume with the audience `system:konnectivity-server` (`konnectivity-agent-ds.yaml:43`, `:77-82`).
- The server checks the token with a TokenReview for that audience, and then checks the namespace and the name of the service account (`$XP:970-1012`). The flags are `--agent-namespace`, `--agent-service-account`, `--authentication-audience` and `--kubeconfig` (`$XO:160-166`). The first three must be set together, and a client CA for agents is then not allowed (`$XO:321-335`).
- The upstream DaemonSet has no host network (`konnectivity-agent-ds.yaml:20-32`). The pod example of the proxy module has it (`$X/examples/kubernetes/konnectivity-agent.yaml:16`).

### How the server picks an agent

- The server tries its strategies in order (`$XP:291-305`). The names are `default`, `destHost` and `defaultRoute` (`$XO:167`).
- `default` picks a random agent (`$X/pkg/server/backend_manager.go:362-365`).
- `destHost` picks the agent whose identifier is the host of the call. The port is removed first (`$XP:279-285`, `$X/pkg/server/desthost_backend_manager.go:72-100`). The agent gives its identifiers with `--agent-identifiers`, for example `ipv4=<node address>` (`konnectivity-agent-ds.yaml:44`).
- `defaultRoute` picks a random agent among those that say `default-route=true` (`$X/pkg/server/default_route_backend_manager.go:39-51`).
- With no agent the server answers "No agent available" (`backend_manager.go:577-579`).
- The agent opens the connection to the target from its own network namespace. So an agent must be able to reach the target (deduction).

### Certificates and RBAC objects

| Path | Socket and token form | TCP and certificate form |
|---|---|---|
| API server to proxy server | Nothing | A server certificate and a CA for the proxy server, a client certificate for the API server (`configure-helper.sh:1044-1048`, `:1947-1949`) |
| Agent to proxy server | The server certificate of `--cluster-cert`. The examples use `apiserver.crt` (`$X/examples/kind/konnectivity-server.yaml:72-73`). The agent has a token | A client certificate for each agent and a CA for them (`configure-helper.sh:1950`, `:2939-2942`) |
| Proxy server to the API | A kubeconfig. The Google scripts make a user `system:konnectivity-server` with a token (`configure-helper.sh:854-856`). The kind example uses `admin.conf` (`konnectivity-server.yaml:82`) | The same |

- The RBAC objects of the token form are one ServiceAccount `konnectivity-agent` in `kube-system` (`$K/cluster/gce/addons/konnectivity-agent/konnectivity-agent-rbac.yaml`) and one ClusterRoleBinding of the user `system:konnectivity-server` to `system:auth-delegator` (`konnectivity-rbac.yaml:1-15`).
- With the lease count the agent also needs read rights on Leases (`$X/examples/kind-multinode/templates/k8s/konnectivity-agent-ds.yaml:1-25`).

### How many servers and agents for three API servers

- Three proxy servers, one beside each API server. A socket is local to its node (deduction).
- One agent on each node that the API servers must reach.
- Each agent needs a connection to each of the three servers. A server picks only among the agents that connected to it (deduction from `backend_manager.go`).
- The server tells each agent its ID and the server count in the answer (`$XP:1074`). The count is the flag `--server-count`, default 1 (`$XO:159`, `:424`).
- The agent dials the same address again until it has as many different servers as the count (`$X/pkg/agent/clientset.go:282-323`). A second connection to a known server is closed, and the agent tries again after the sync interval (`clientset.go:254-260`, `:305-308`).
- So the one address must spread the connections over the servers (deduction).
- `--sync-forever` makes the agent dial on each sync also after it has all servers, for a count that changes (`$XAO:147`, `clientset.go:295`).
- The newer way is a Lease for each server. The server has `--enable-lease-controller`, and the agent counts the Leases with `--count-server-leases` (`$XO:172-174`, `$XAO:149-155`, `$X/pkg/agent/server_counter.go:44-80`).

## 3. How NVKE would install each part

### The kubeadm ClusterConfiguration and the flags and volumes of a feature

- kubeadm has no Konnectivity code. A search of `$K/cmd/kubeadm` for `konnectivity`, `egress-selector` and `egressselector` finds nothing. The kind example uses `apiServer.extraArgs` and `apiServer.extraVolumes` (`$X/examples/kind/kind.config:13-27`).
- NVKE renders the ClusterConfiguration in `clusterConfiguration` (`$C/kubeadmconfig/init.go:241-334`). The base flags are at `:244-260` and the base volumes at `:261-276`.
- Etcd encryption on the controller side is two flags and one volume behind a switch (`init.go:290-295`, `$C/kubeadmconfig/render.go:419-421`, `:464-476`). The switch comes from the cluster record (`$C/temporal/activities/kubeadm_init.go:114`).
- OIDC on the controller side is one flag, one volume and one rendered file (`init.go:300-303`, `:137-146`, `render.go:481-489`).
- The volume of each of the two is a folder, not a file. The comment says that a file mount breaks when the file is replaced (`render.go:464-467`). A socket has the same need (deduction).
- NVKE keeps a list of the flags that it sets and refuses the same flag from an operator (`$C/kubeadmconfig/extra_args.go:42-66`, `:140-142`). A test fails when the list and the renderer differ (`extra_args.go:41`).
- An operator can give other API server flags in `controlPlaneConfig.apiServer.extraArgs` (`$R/controller/api/openapi.yaml:1191-1205`, `extra_args.go:118-146`). `egress-selector-config-file` is not in the list today, so NVKE accepts it. The API has no field for a volume.
- For Kubernetes 1.31 and later NVKE converts the document to `v1beta4`, with the flags and the volumes (`$C/kubeadmconfig/v1beta4.go:17-24`, `:68-72`).

The agent side of the two examples:

- For encryption at create, the agent writes the encryption config from the key of the request before `kubeadm init` and before a control plane join (`$A/agent.go:888-895`, `:643-652`).
- For encryption that is turned on later, the agent edits the local manifest with `sed` and then writes the ConfigMap (lab note, `results/phase2-encryption-join-fix.md`, sections 1 and 2).
- For OIDC that is turned on later, the controller runs a rollout over the control plane nodes. For each node it calls `PatchAPIServerManifest` with files, a volume patch and a flag (`$C/rollout/operations/oidc/operation.go:380-391`, `$R/agent/pkg/agent/proto/node_agent.proto:340-363`, `:399-421`). After the last node it merges the settings into the ConfigMap (`$C/temporal/workflows/enable_oidc.go:71-90`, `$C/kubeadmconfig/configmap.go:69-139`).

The lab finding and what it means here:

- `kubeadm join` builds the API server manifest of a new control plane node from the `kubeadm-config` ConfigMap. The join request carries no API server settings (lab note, same file, question 2).
- A cluster that has the settings from its creation has them in the ConfigMap, because kubeadm stores the init document (lab note, same file, question 3).
- So a Konnectivity switch at create needs only the renderer. A switch for a cluster that exists needs a rollout and a merge into the ConfigMap, in the form of `MergeEncryptionIntoClusterConfiguration` (`configmap.go:219-273`) (deduction).
- On `d625fcfa` the agent function for encryption that is turned on later still replaces the volume list and loses the other settings of `apiServer` in the ConfigMap (`$A/etcd_encryption_at_rest.go:903-924`, and the lab note). The fix is on a local lab branch only. Without the fix that flow would also remove the egress selector flag and its volume from the ConfigMap (deduction).

### How a file gets onto each control plane node

- At create, the renderer returns files beside the kubeadm document (`init.go:128-146`, `$C/kubeadmconfig/artifacts.go:6-23`). The audit policy is the plain example (`$C/kubeadmconfig/audit_policy.go:10-20`).
- The controller puts the files into the init request (`$C/temporal/activities/kubeadm_init.go:142`). The agent writes them before it runs kubeadm (`$A/agent.go:856`, `$A/kubeadm_prerequisite_files.go:43-59`).
- At a later join of a control plane node, the join renderer returns the patch and the audit policy again, and the OIDC file when needed (`$C/kubeadmconfig/join.go:202-218`). The controller puts them into the join request (`$C/temporal/activities/kubeadm_join.go:143`), and the agent writes them before the join (`$A/agent.go:634`).
- The agent accepts each absolute path with no symbolic link on the way. It has no list of allowed folders (`kubeadm_prerequisite_files.go:116-130`, `:183-206`).
- An agent that is too old for request files gets them through a runbook (`$C/temporal/activities/kubeadm_patches.go:22-53`).
- For a node that is in the cluster, `PatchAPIServerManifest` takes files too, with no folder limit (`node_agent.proto:412-416`).
- A request on the `infra` path can also carry files and commands for the control plane nodes, as `bootstrapFiles` and `preKubeadmCommands` (`openapi.yaml:3641-3663`, `$C/clients/capi/bootstrap_userdata.go:101-109`, `:150-151`). The pod image of the lab writes such files and runs such commands (lab note, `$L/phase2-node-image/result.md:11`, `:69`).

So the egress selector config needs one more entry in the two file lists, `init.go:130-134` and `join.go:203-207` (deduction).

### Where the proxy server can run

A static pod on each control plane node:

- kubeadm allows other manifests in the manifest folder. Its checks name only its own four files (`$K/cmd/kubeadm/app/preflight/checks.go:1001-1004`).
- NVKE has one static pod of its own today, kube-vip. The agent renders the manifest and writes it (`$A/kube_vip.go:35-40`, `:352`, `:432`). The controller asks for it before the init and after a join (`$C/temporal/workflows/provision_cluster.go:63`, `$C/temporal/workflows/provision_node.go:322-329`).
- For Konnectivity the manifest can go through the file lists of the section above. Then the agent needs no new code (deduction).
- The pod starts with the kubelet, before the API server of the node takes traffic (deduction).
- It needs a kubeconfig on the node for the TokenReview. kubeadm makes none for it. `admin.conf` is there on each control plane node (general knowledge), and the kind example uses it.
- The image must be on the node. kube-vip has its image name with a digest in the agent code (`kube_vip.go:40`).
- The certificate renewal restarts four named components (`$A/kubernetes_certificate_renewal.go:55-60`). The proxy server is not one of them.
- The graceful shutdown parks manifests by name. The names are kube-vip and the API server (`$A/control_plane_graceful_shutdown.go:53-56`). So the proxy server keeps running while the API server is parked (deduction, I did not read the whole function).

A pod of the new cluster on the control plane nodes:

- This is the kind example. It is a DaemonSet with the host network, a node selector for the control plane role, and host paths for `/etc/kubernetes` and for the socket folder (`$X/examples/kind/konnectivity-server.yaml:53-55`, `:106-126`).
- NVKE would apply it with the tenant client, as it applies the local DNS manifest (next section). No file goes to a node for it.
- It starts only after the scheduler and the kubelet of the node work. So the API server of a new node takes calls for some time with no socket (deduction).
- It can use a service account in place of a kubeconfig file (deduction, the server builds its client from the flag at `$XM:107-127`).
- A tenant with admin rights can delete or change the DaemonSet (deduction).

My view is the static pod for the prototype. It needs nothing from the scheduler, a tenant cannot remove it, and the file path exists (deduction).

### How NVKE installs add-ons and where the agent DaemonSet fits

- The CNI comes from the agent of the first control plane node, with Helm, one time for the cluster (`$A/cni.go:293-325`, `:878`, and `provision_cluster.go:176-260`).
- CoreDNS and kube-proxy are add-ons of kubeadm. NVKE skips kube-proxy with OVN (`kubeadm_init.go:113`, `init.go:215-217`).
- The local DNS is the one add-on that the controller applies itself. The manifest is a file in the controller binary, and the controller applies each object with a server-side apply through its tenant client (`$C/temporal/activities/install_kube_local_dns.go:42-43`, `:90-113`). The image name with a digest is in the manifest (`$C/temporal/activities/kube_local_dns.yaml:125`).
- The workflow calls it after the first node is in the cluster. The comment says "This could be expanded into an add-on system later" (`provision_cluster.go:76-79`).
- A step that is new in a workflow sits behind a version check, so that an old run replays (`provision_cluster.go:81-86`).
- The add-on step of an upgrade runs `kubeadm upgrade apply` on one node and then applies the local DNS manifest again (`$C/temporal/workflows/upgrade_control_plane_addons.go:59-95`).
- NVKE labels `kube-system` as privileged for Pod Security Admission (`$C/temporal/activities/label_system_namespaces_for_psa.go:34-36`).

So the agent DaemonSet fits as a second manifest beside the local DNS, in a new activity after `provision_cluster.go:77`, and again after `upgrade_control_plane_addons.go:95` (deduction).

Two points for the DaemonSet text:

- A worker joins with the taint `nvke.nvidia.com/provisioning=true:NoSchedule`, and NVKE removes it after the labels (`join.go:120-127`, `provision_node.go:331-338`). The upstream DaemonSet does not tolerate it (`konnectivity-agent-ds.yaml:22-26`).
- With the `default` strategy an agent on a control plane node can get a call for a worker that it cannot reach. So the agents run on workers only, or the server uses `destHost` first (deduction).

### The second port

- In the lab the shared address is the request field `controlPlaneEndpoint`, a `host` or a `host:port` that NVKE does not manage (`$E/controller/api/openapi.yaml:1154-1173`, `$E/controller/internal/server/cluster_network.go:234-294`).
- kubeadm puts the host of that field into the API server certificate (`$K/cmd/kubeadm/app/util/pkiutil/pki_helpers.go:425-431`). So `apiserver.crt` is valid for an agent that dials the shared address (deduction).
- The request needs no new field for a prototype. The agent host is the host of `controlPlaneEndpoint`, and the port is one fixed number (deduction). A product needs a field or a setting for the port.
- The lab Service has one port, 6443, and selects the control plane pods by two Cluster API labels (`$L/phase2-provider-run/api-service.yaml.tmpl:4-18`). It needs one more port entry. The pod provider does not make that Service (`$P/README.md:166-168`).
- The Service has no session affinity (`api-service.yaml.tmpl:10-18`). So it spreads new connections over the ready pods (general knowledge of kube-proxy).
- Its traffic policy is a variable. The run script of phase 1 has `Cluster` as the default (`$L/phase1-second-machine/remote/d/run/run.sh:37`). I did not find the value of the phase 3 run in the notes.
- The API server and the proxy server listen on each address of the node, so also on the pod address that the Service uses (`render.go:38`, `$XO:148`).
- With kube-vip the address is on one node at a time (general knowledge). Then each agent reaches only one server (deduction). So this form of Konnectivity fits the load balancer endpoint and not the kube-vip endpoint.

The readiness and the health gate of the pod provider:

- The readiness probe of a control plane pod runs a program in the node. It passes when the gate file is absent and `/readyz` of the local API server answers 200 (`$P/controllers/machine_resources.go:65-87`, `:527-533`).
- A pod has one readiness. So the second port follows the gate of the first port (deduction).
- The gate closes the open sockets of port 6443 only (`$A/control_plane_graceful_shutdown.go:1156-1171`, `:1261-1264`). An open tunnel of an agent stays (deduction).
- A tunnel that exists also stays when the pod leaves the Service (general knowledge of kube-proxy).
- A new control plane node, or one that started again, has a proxy server with no agent. The agents can reach it only after the pod is ready. So for a short time the API server of that node takes calls and its proxy server answers "No agent available" (deduction).
- The probe cannot wait for an agent. A cluster with no worker has no agent, and an agent cannot connect to a pod that is not ready (deduction).
- One way out is a second Service for the agent port with `publishNotReadyAddresses` on the same address (general knowledge, I did not check MetalLB 0.16.2 for a shared address).

### Certificates, the forced renewal and a rollout

- With the socket and the token form, kubeadm and NVKE make no new certificate. The proxy server uses `apiserver.crt` and its key for the agents, and `admin.conf` for the TokenReview (deduction from the kind example).
- A product should not give `admin.conf` to the proxy server. Then NVKE must make a kubeconfig for a user with `system:auth-delegator`, or run the server with a service account (deduction).
- The renewal of the agent runs `kubeadm certs renew all` and then restarts etcd, the API server, the controller manager and the scheduler, one at a time (`$A/kubernetes_certificate_renewal.go:262`, `:284-288`, `:55-60`).
- The proxy server reads its certificate one time (`$XM:408-412`). After a renewal it still shows the old certificate, which is valid until its old end date (deduction). So the renewal must restart the proxy server too, or the old certificate ends about a year after the start of that pod (deduction).
- A certificate of its own for the proxy server would be unknown to `kubeadm certs renew all`. NVKE would have to renew it (deduction).
- A rollout replaces each control plane node. The new node gets its certificates from `kubeadm join` and its files from the join request. So a rollout keeps the parts right when the files are in the join list (deduction).
- With one more node during a rollout the server count is four for some time. A fixed count of three in the server flags needs `--sync-forever` on the agents, or the Lease count (deduction).

## 4. The request and the product shape

What a similar switch looks like today:

| Shape | Example | Reference |
|---|---|---|
| A required boolean of the create request, one way | `etcdEncrypted`, with a later `enableEtcdEncryption` | `openapi.yaml:1072-1075`, `:1126-1130`, `$C/server/clusters.go:1511` |
| An optional boolean of the create request, default false | `enableCPNodeRecycling` | `openapi.yaml:1176-1182`, `clusters.go:1501-1515` |
| A string of the create request, fixed at creation, exclusive with another field | `controlPlaneEndpoint` of the lab branch | `$E/controller/api/openapi.yaml:1154-1173`, `cluster_network.go:234-294` |
| A setting of the deployment that the create handler pins on the cluster | The shared OIDC provider and the fleet OIDC providers, the Teleport default | `clusters.go:134-158` |
| Automatic for a kind of node | The container mode of kubeadm | `$C/temporal/activities/kubeadm.go:39-45` |
| A setting of the deployment for an image source | `KubeadmImageRepository`, `CNIImageRegistry` | `kubeadm_init.go:112`, `:158` |

The checks of the create handler for such fields:

- The extra flags are checked against the list of NVKE (`clusters.go:447-453`).
- The endpoint field is refused together with the VIP and inside the pod or service range (`cluster_network.go:234-294`).
- A legacy choice is refused unless the deployment allows it (`clusters.go:458-460`).
- A change of `openapi.yaml` needs `make generate` and passes `make api-compat-check` (`$R/AGENTS.md`).

My view (deduction):

- The need comes from the network between the control plane and the workers. NVKE has no data on that network, so "automatic for a provider" has no base today.
- A switch of the create request, fixed at creation, is the first product shape. It is like `controlPlaneEndpoint`. A check refuses it without `controlPlaneEndpoint`, because kube-vip does not spread the agents.
- The images and the agent port are settings of the deployment, as the image sources are today.
- NVKE then adds `egress-selector-config-file` to its own flag list, so that an operator cannot set another file.
- "Turn it on later" is a second step. It needs a rollout operation and a ConfigMap merge, as OIDC has.
- The prototype needs none of this. A setting of the deployment, or no NVKE code, is enough for it (section 5).

## 5. The smallest prototype

The pass rule is that `kubectl logs` and `kubectl exec` work for a pod on a worker that the control plane pods cannot reach, through each of the three API servers.

The form of both variants:

- The egress selector config has `cluster` with `GRPC` over a socket, and `controlplane` and `etcd` with `Direct`, as `configure-helper.sh:1018-1032`.
- The proxy server is a static pod with the host network on each control plane node. Its flags are a socket name, `--server-port=0`, the agent port 8132, `--mode=grpc`, `--cluster-cert` and `--cluster-key` with `apiserver.crt` and its key, `--kubeconfig=/etc/kubernetes/admin.conf`, the three agent identity flags, `--server-count=3` and `--proxy-strategies=destHost,default`.
- The agent is a DaemonSet on the workers only, with the host network, a toleration for each taint, the shared address as the server host, port 8132, the token volume, `--agent-identifiers=ipv4=<node address>` and `--sync-forever`.

### Variant L, the lab alone, with no NVKE code

| Part | Files | Size (my estimate) |
|---|---|---|
| The flag | `$L/phase3-run/requests/cluster-request.json.tmpl`, one entry in `controlPlaneConfig.apiServer.extraArgs` | 3 lines |
| The config file and the static pod manifest | The same file, two entries in `controlPlaneConfig.infra.bootstrapFiles` | 70 to 90 lines of text in the request |
| The volume | None. The config file and the socket go into `/etc/kubernetes/policies`, which NVKE mounts into the API server read-only (`init.go:269-275`) | 0 |
| The agent | A new lab manifest that the lab script applies to the new cluster | 90 lines |
| The second port | `$L/phase2-provider-run/api-service.yaml.tmpl`, one port entry | 1 line |
| The images | The proxy server image in the pod image, the agent image in the worker image, each as one more image file at the image build | 2 files, 2 build runs |
| The NVKE controller and the node agent | No change | 0 |

Limits of variant L (deduction):

- It proves the data path and the lab network. It does not prove an install path of NVKE.
- The files come one time from the bootstrap data. A join that fails runs `kubeadm reset` before the next try (`$A/agent.go:628-632`), and the reset empties the manifest folder (general knowledge). The static pod is then gone on that node.
- The socket sits in the audit policy folder. That is a lab shortcut.

### Variant N, the smallest change in NVKE

| Part | Files | Size (my estimate) |
|---|---|---|
| The flag, the volume and the two files in the renderer | `$C/kubeadmconfig/init.go` (`:27-72`, `:128-135`, `:290-303`), `join.go` (`:37-67`, `:202-208`), `render.go` (helpers as `:419-489`), `extra_args.go:45-64`, one new file for the config text and the manifest text | 150 to 200 lines |
| Tests and one fixture for the renderer | `$C/kubeadmconfig/*_test.go`, `testdata/` | 150 to 200 lines |
| The switch for the prototype, as a setting of the deployment with the port and the two images | `$C/controllerconfig`, `$C/config/config.go`, `$R/controller/hack/local-controller-config.yaml` | 40 to 60 lines |
| The switch into the init and the join | `$C/temporal/activities/kubeadm_init.go:104-118`, `kubeadm_join.go:115-126` | 20 to 30 lines |
| The agent add-on | A new activity and a new manifest beside `install_kube_local_dns.go`, one call after `provision_cluster.go:77` behind a version check | 120 to 150 lines of Go, 90 to 110 lines of YAML, 80 to 120 lines of tests |
| The node agent | No change. The files use the `Files` field that exists (`$A/agent.go:634`, `:856`) | 0 |
| The lab request | No new field. The host comes from `controlPlaneEndpoint` | 0 |
| The second port and the images | As variant L | 1 line, 2 files |

- The sum is about 330 to 440 lines of Go and 100 lines of YAML with no tests, and about 650 to 850 lines with the tests (my estimate).
- The change goes on the lab branch of the controller. Only the controller image is built again (deduction).

### The images

- Kubernetes master names `registry.k8s.io/kas-network-proxy/proxy-server:v0.37.0` and `registry.k8s.io/kas-network-proxy/proxy-agent:v0.37.0` (`$K/cluster/gce/manifests/konnectivity-server.yaml:23`, `$K/cluster/gce/addons/konnectivity-agent/konnectivity-agent-ds.yaml:30`). Kubernetes 1.36.4 names `v0.34.0`.
- The README of the proxy says to use the tag of the same minor number as Kubernetes (`$X/README.md:27-40`). The design must pick one version.
- A node of the lab cannot pull. The firewall of the second machine drops a new forwarded connection from a Docker bridge (lab note, `$L/phase1-second-machine/report.md:108`).
- The lab puts such an image into the containerd store of the node image at the image build, from a file. The worker image has the pause image and the DNS cache image that way (`$L/phase3-run/image/Dockerfile.worker:4-6`, `:23-28`). The pod image has the CNI images that way (`$L/phase2-node-image/Dockerfile.p3:2-17`).
- The two image files do not exist on the workstation. `docker image ls` shows no proxy image. I did not look at the second machine.
- So somebody pulls the two images one time on a machine that can pull and saves them to files. That is a download, and it needs the word of Davanum.

### What the prototype leaves out

- Webhooks and aggregated APIs through the proxy. A search of `$R` finds such objects only for the management side, so NVKE puts none into a new cluster (deduction). The identity webhook of the OVN chart is off by default and names a URL (lab copy of chart 2.4.2, `/scratch/kata-cp/work/phase1-cni/chart-extract/etc/dgx/ovn-kubernetes/values.yaml:9`, `:76`, `charts/ovnkube-identity/templates/webhook.yaml:28`).
- Metrics.
- Logs and exec for a pod on a control plane node. With `cluster` through the proxy, the API server also calls the kubelet of its own node through an agent. The prototype has no agent on the control plane nodes, and a worker agent cannot reach them (deduction). A second agent DaemonSet on the control plane nodes with `destHost` repairs that.
- High availability of the proxy. No test of a server that stops, no Lease count, no second Service.
- Upgrades, the add-on step of an upgrade, and a switch for a cluster that exists.
- A kubeconfig of its own for the proxy server, and the restart after a certificate renewal.
- The request field, the database column and the docs.

## 6. The lab network for the test

The facts:

- `kata-bb` is `172.29.0.0/16`. Kind nodes have `172.29.0.2`, `.4` and `.5`, and the load balancer addresses are `172.29.255.200` to `.250` (lab note, `$L/phase1-second-machine/report.md:103`, `:107`, and `result-AB.md`, section 3).
- `kata-bb-node` is `172.28.0.0/16`, an internal Docker network. Each control plane pod has its node address there through Multus (lab note, `$L/phase1-fixed-address/result-C1.md:15-19`, `$L/phase1-second-machine/remote/c1/c1-net.sh:16-18`).
- A worker on `kata-bb` alone reaches the shared address and not the node addresses of the control plane pods (lab note, `result-AB.md`, section 3).
- The API server still reaches that worker through the default route of its pod. The kind node replaces the source address (lab note, `result-AB.md`, section 3).
- The NVKE controller is a pod of the host cluster. It must still reach port 15005 of the worker (lab note, `result-AB.md`, section 1).
- The host cluster uses kindnet from kind v0.33.0 (lab note, `report.md:100-101`).
- A third Docker network does not help. The machine and Docker both stop traffic between two bridges, so that worker would reach neither the shared address nor the NVKE controller (lab note for the machine, `report.md:108` and `result-AB.md`, section 8, and general knowledge for Docker).

The proposal, with no change on the machine:

1. The worker gets `kata-bb` alone, with a fixed address in `172.29.2.0/24`. The wrapper `docker-two-nets` can do that with settings and no code change. The settings are `P3_NODE_NET=kata-bb`, `P3_NODE_IP_PREFIX=172.29.2` and an empty `P3_API_NET`, with `NICO_CONTAINERS_NODE_NETWORK=kata-bb` for the simulator (`$L/phase3-run/sim/docker-two-nets:36-38`, `:65-67`, `:101-104`).
2. One NetworkPolicy in the host cluster, in the namespace of the control plane pods. It selects the pods with the label `cluster.x-k8s.io/control-plane`, has the policy type `Egress`, and allows `0.0.0.0/0` except `172.29.2.0/24`.

- The change is one object in the lab cluster and three settings of the simulator container. No Docker network, no package and no rule in the network namespace of the machine.
- kindnet turns the policy into rules in the network namespace of each kind node container (general knowledge). Davanum can judge if that is inside his rule.
- The policy stops each new connection from a control plane pod to a worker address. That covers the API server and an agent on a control plane node (deduction).
- It does not stop the answers to a connection that the worker opened, and it does not select the NVKE controller (deduction).
- The first lab step must check it, because I did not test that kindnet of this version applies a policy to a Kata pod. From a control plane pod, port 10250 of the worker gives no answer. From the NVKE controller, port 15005 answers.

The fallback when the policy has no effect:

- One route in each control plane node, as a command of the request. The command is `ip route add blackhole 172.29.2.0/24` in `controlPlaneConfig.infra.preKubeadmCommands` (`openapi.yaml:3658-3663`). It is in the Kata guest only. It works only with the Service policy `Cluster`, because the answers then go to a kind node address (deduction). The command runs one time for a Machine, so a restart of the pod removes the route (lab note, `$L/phase2-node-image/result.md:69`).
- A drop rule for port 10250 in the network namespace of the worker container is a second fallback. I did not check that the worker image has the `nft` program.

What the test shows and what it does not show (deduction):

- The proof is in the kubelet of the worker. With the proxy it sees the call from its own node address. On the direct path it saw a kind node address.
- The pod network between that worker and the control plane nodes is broken, as in step A. The test pod must need no name lookup and no API Service. The agent needs the host network.
- Each worker of the cluster is of the unreachable kind, because the simulator has one setting for all workers.

## 7. Risks and open points

### The pod network

- Konnectivity gives a pod on a control plane node no path to a pod on a worker (deduction).
- With one network, pod traffic between the worker and the control plane nodes passed in 0 of 3 lines in each direction. The test pod on the worker did not reach the API Service, and its name lookup failed. NVKE still showed a good node (lab note, `result-AB.md`, section 3 and finding 3).
- The API Service points at the advertise address of each API server. NVKE sets that to the node address (`init.go:179-182`, `join.go:281-285`, `$K/cmd/kubeadm/app/phases/controlplane/manifests.go:187`). A worker that cannot reach the node addresses cannot reach the API Service from a pod (deduction).
- So a design for a network where the two sides do not reach each other needs more than Konnectivity. It needs an API address for pods that the workers reach, name service on the workers, and no cluster pod on a control plane node that a worker pod needs (deduction). That is the ground of phase 4.

### The health gate of phase 2

- The gate closes sockets of port 6443 only, so the tunnels stay through a guarded operation (section 3).
- A new or restarted control plane node takes API calls before its proxy server has an agent (section 3).
- The each-second call of the lab reads `/readyz`. It does not see a proxy server with no agent. The test needs a new check, for example `logs` through each API server each few seconds (deduction).
- The lab never ran the gate with workers under load (lab note, `result-AB.md`, section 9).

### The join of a new control plane node

- The node needs the flag from the ConfigMap and the config file from the join request. With the flag and no file the API server does not start (`$KS/server/options/egress_selector.go:88-90`), and the join runs into its time limit, as in the encryption fault (deduction).
- With the file and no flag the node joins, and its API server calls the kubelets directly. Then `logs` works through two API servers and fails through the third (deduction).
- The server count is four during a rollout with one more node (section 3).

### Etcd encryption and OIDC flows

- Both restart the API server of one node at a time behind the kube-vip guard and the gate (lab note, `results/phase2-gaps-agent-gate.md`, section 1).
- The proxy server of that node keeps running. The other two API servers keep their agents (deduction).
- The OIDC patch changes one flag and one volume by name and keeps the rest (`operation.go:380-391`, `node_agent.proto:340-349`). The encryption edits use `sed` on single lines (lab note).
- On `d625fcfa` the encryption flow that is turned on later damages the `apiServer` part of the ConfigMap (section 3). A prototype on the lab build has the fix. A design for main must name that fix as a need.
- `kubeadm upgrade apply` builds the manifest again from the ConfigMap (lab note, question 5). So the flag and the volume must be in the ConfigMap also for an upgrade.

### The node agent path

- The NVKE controller dials port 15005 at the address of each node (`$C/agent/transport.go:123-127`, `$R/docs/operate/plan-installation.md:64`).
- Konnectivity does not carry that call. It carries only connections that the API server opens (section 1).
- In a network where the control plane cannot reach the workers, NVKE needs its own route to the workers, or the node agent must dial out. The second is a large change (deduction).
- In the proposed lab test the NVKE controller keeps its direct path.

### More open points

1. The proxy version for Kubernetes 1.36.4. I read `v0.37.2`. Some flags of that version can be absent in `v0.34.0`.
2. `--sync-forever` makes each agent open a connection and cause a TokenReview on each sync (`clientset.go:291-308`, `$XP:1067-1072`). That is fine for a lab and a load for a large cluster (deduction).
3. A tenant with admin rights can make a token for the agent service account and connect an agent of its own. With the `default` strategy that agent gets calls of the API server (deduction).
4. Before the first worker joins, the cluster has no agent. Each `cluster` call fails then (deduction).
5. `admin.conf` for the proxy server is a prototype shortcut.
6. The ports 8132 to 8134 are free in the NVKE source. A search of `$A`, `$C` and `$R/docs/operate` finds none of them.

## Points where I am not sure

- That kindnet of kind v0.33.0 applies a NetworkPolicy, and that it applies it to a Kata pod. I know the first in general and tested neither.
- That the API server can use a socket in a folder that is mounted read-only. The kind example does it with its own folder. I did not test the audit policy folder of NVKE.
- That `kubeadm reset` empties the manifest folder. I did not read that code.
- That an open tunnel stays when a pod leaves the Service, and that MetalLB 0.16.2 gives one address to two Services.
- That `bootstrapFiles` of the control plane reach a node that replaces another. I read `bootstrap_userdata.go:101-109` and did not follow a replace.
- The cause of the failed API Service call in step A. The advertise address is my deduction.
- That the proxy server keeps working with the old `admin.conf` content after a renewal until a restart. I did not read how its client loads the file.
- The order of the kubelet start and the files of kubeadm on the first node. I expect that `apiserver.crt` and `admin.conf` exist before the kubelet starts the static pod.
- Which flags of `v0.37.2` exist in `v0.34.0`.
- Each size in section 5. They are estimates from the size of the examples that I read.
- The state of the second machine. I looked at no machine but the workstation.
