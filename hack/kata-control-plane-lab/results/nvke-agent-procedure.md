Date 2026-11-25. NVKE commit bcc4376f. The text is a source reading, and no test ran.

# Procedure for kubeadm init through nvke-agent in one pod, with a SPIFFE check
Path prefixes: `R` = `/scratch/kata-cp/src/nvke`, `AG` = `R/agent`, `C` = `R/controller`, `CI` = `C/internal`, `ACT` = `CI/temporal/activities`, `IMG` = `C/hack/capd-kindest-node`, `SIM` = `C/nico-sim/internal/container`. A statement about SPIRE, kubeadm or systemd that I did not read in this clone has the mark "(not in this source)".

## 1. What nvke-agent needs at start
**Conclusion.** The agent starts with the image content and needs no extra flag. The image default is SPIFFE mTLS, so port 15005 stays closed until the SPIRE agent in the pod gives the agent an identity. The pod must supply two SPIRE files, or it must add `--disable-mtls`.
- The unit runs `/usr/local/bin/nvke-agent $AGENT_ARGS`. It reads `/etc/default/nke-agent` first and `/etc/default/nvke-agent` second, it restarts always, and it has the alias `nke-agent.service` (`AG/scripts/nvke-agent.service:6-20`).
- The image file `/etc/default/nvke-agent` has `AGENT_ARGS="--disable-mlx5-rescan --secure-server-port 15005 --bundle-server-url http://nvke-bundle-mirror/ --index-file-url http://nvke-bundle-mirror/index.json"` and `NKE_LOCAL_DEV=true` (`IMG/Dockerfile:242-257`, `/scratch/kata-cp/logs/nvke-node-image-build.md:94-95`). The Dockerfile adds `--enable-spiffe` only if the binary has that flag, and the binary has no such flag (`IMG/Dockerfile:243-246`, `AG/cmd/agent/main.go:513-570`).
- `NKE_LOCAL_DEV=true` changes one thing. The agent adds `--ignore-preflight-errors=SystemVerification` to `kubeadm init --config` and to `kubeadm join --config` (`AG/internal/agent/agent.go:126-130, 663-670, 873-880`).
- The SPIFFE socket is the flag `--spiffe-socket-path`, with the default `unix:///tmp/spire-agent/public/api.sock` (`AG/cmd/agent/main.go:515`). The SPIRE agent config from NVKE sets no socket path (`CI/clients/capi/capi_spire_agent.conf.tmpl:4-17`).
- The agent contacts the bundle server only during a call that installs a bundle. At start it only parses the URL (`AG/internal/agent/agent.go:370-388, 408-450`). It fetches the index in `InstallBundle`, in `InstallCollection` with a JSON collection, and in the CNI install inside `ExecuteKubeadmInit` when `no_cni_install` is false (`AG/internal/agent/agent.go:953-955, 2090-2103, 2216-2238`, `AG/internal/agent/cni.go:134, 418`). With `no_cni_install: true`, step A needs no bundle server.
- The state file is `/var/lib/nvke/state.json` (`AG/internal/agent/agent.go:73-74, 393-406, 452-472`). The agent also writes two log files in `/var/log`, and it runs `swapoff -a` and only logs a failure (`AG/cmd/agent/main.go:462-466, 549-552, 578-585`).
- The agent requires no other unit. Three units only have an order before it (section 7).
- When SPIRE is not ready, the process stays active and the port stays closed. `workloadapi.NewX509Source` blocks until the first SVID, the context has no time limit, and `net.Listen` comes later (`AG/cmd/agent/main.go:245-261, 384-392, 427, 618`, go-spiffe v2.9.0 `workloadapi/x509source.go:28-31`, `workloadapi/client.go:524-545`). The agent continues when the SVID arrives, so no restart is necessary.
- The mode with no mTLS is the flag `--disable-mtls` (`AG/cmd/agent/main.go:514, 387-405`). The controller has the same mode, and it dials in plaintext when the node has SPIFFE off (`CI/agent/transport.go:147-148`). The documents call the mode development only (`R/SECURITY.md:144`, `R/docs/site-bootstrap/pre-provisioned-nodes.md:208`). It is acceptable for a first run of step A, because it separates a kubeadm problem from a SPIRE problem. Record that authentication was off. Do the final run of step A with mTLS, so that step A and step B are one run.

## 2. Authentication in both directions
**Conclusion.** The controller and the agent use SPIFFE mTLS with X.509 identities from one SPIRE server. The controller accepts only `spiffe://<td>/host/<node UUID>`. The agent accepts each caller of its own trust domain whose path starts with `/nvke-service/`. The smallest setup is one SPIRE server, two join tokens and two entries.
- The controller dials `node.IP:15005` and selects external mTLS, plaintext or SPIFFE from the node record (`CI/agent/transport.go:123-157`, `CI/config/config.go:95-96`).
- The controller presents the identity from its own workload socket (`CI/agent/transport.go:244-262`). The ID is `spiffe://<td>/nvke-service/<service account>`. The SPIRE server issues it to pods in the controller namespaces through the `ClusterSPIFFEID` object `nvke-service` (`C/deploy/k8s/spire-nvke-services-spiffe-id.yaml:4-20`).
- The controller expects the agent ID with `tlsconfig.AuthorizeID` (`CI/agent/transport.go:235-262`, `CI/db/nodes.go:105-107`, `CI/spiffe/node_agent.go:14-19`). The node UUID is the ID of the node row.
- NVKE issues the agent ID with a `ClusterStaticEntry` with the name `host-<node UUID>`. Its parent is the alternate ID of the SPIRE agent, its selector is `unix:uid:0`, and its SPIFFE ID is the `/host/` ID (`CI/controllers/capi/machine_spire_entry_controller.go:60-124, 149-151`). The controller reads three Machine annotations for it (`CI/clients/capi/machine.go:110-112`, `CI/clients/shared/machine.go:254-261`).
- For the join token, the controller calls `CreateJoinToken` on the SPIRE server API with a TTL and with the agent ID `spiffe://<td>/join-token-spire-agent/host-id/<node UUID>` (`ACT/capi_node_resources.go:103-127`, `CI/spiffe/join_token.go:23-88`, `CI/constants/constants.go:109`). The default TTL is 1 hour (`C/deploy/charts/controller/values.yaml:831`).
- The agent checks its caller in the TLS handshake. The caller must have the trust domain of the agent, and its path must start with `/tenant/nvke/service/`, `/nvke-service/`, `/nke-service/` or `/tenant/nke/service/` (`AG/cmd/agent/main.go:208-230, 245-261`).
- On the `infra` path the token is in the text of `/etc/spire-agent/agent.conf`, in the key `value` of the Secret `<node>-bootstrap-data` (`CI/clients/capi/machine.go:79-92`, `CI/clients/capi/bootstrap_userdata.go:122-136`, `CI/clients/shared/machine.go:145-163`). The infrastructure provider must give that Secret to the node. With a `NicoMachineTemplate`, nico-sim gets the text as user data and applies it after the container start (`SIM/service.go:291-298`, `SIM/docker.go:136-198`). The CI lane uses this `infra` form (`R/cli/examples/nico-mock-cluster.yaml:16-19, 33-66`). The `nico` provider type makes no join token (`CI/clients/nico/machine.go:109-113`).
The smallest SPIRE setup for the lab has these parts (the `spire-server` commands are not in this source):
1. One SPIRE server pod with a ClusterIP Service on port 8081. Use version 1.14.1, which is the agent version in the image (`/scratch/kata-cp/logs/nvke-node-image-build.md:114`). The Tilt values set no option for join tokens (`C/deploy/helm-values/spire.yaml:31-60`), so I found no server setting to copy.
2. `spire-server bundle show -format pem` gives the content of `/etc/spire-agent/initial-trust-bundle.pem`.
3. `spire-server token generate -spiffeID spiffe://<td>/join-token-spire-agent/host-id/<NODE_UUID> -ttl 3600` gives the node token. `<NODE_UUID>` is a UUID that the lab chooses, because the lab has no node row.
4. `spire-server entry create -parentID spiffe://<td>/join-token-spire-agent/host-id/<NODE_UUID> -spiffeID spiffe://<td>/host/<NODE_UUID> -selector unix:uid:0` gives the agent ID. If the SPIRE controller manager runs, make a `ClusterStaticEntry` as NVKE does.
5. For the client, make a second token with a second alternate ID, and an entry under it with `-spiffeID spiffe://<td>/nvke-service/lab-client -selector unix:uid:0`. The client pod runs its own `spire-agent` with that token, so it needs no host socket. A faster form is an entry with `-selector unix:uid:1001` under the node parent and a client in the node pod with that uid, but that call does not go through the Service.
6. The node pod gets `agent.conf` from the template, with the Service address, the port, `<td>`, the bundle path and the token (`CI/clients/capi/capi_spire_agent.conf.tmpl:4-53`).

## 3. RPC sequence for the first control plane node
**Conclusion.** The controller calls `GetKubeadmStatus`, `ExecuteNodePreflight`, one reflection query and `ExecuteKubeadmInit`, and then it polls `GetKubeadmStatus` each 10 seconds. I found no call to `InstallBundle`, `InstallCollection`, `InstallPackages` or `ConfigureAptRepo` in `CI/temporal` or `CI/controllers`. In this image a request with no `init_config` fails, because the kubeadm shim refuses `init` without `--config` (`IMG/scripts/kubeadm-systemverification-shim:56-81`).
1. `WaitForCAPIMachineReady` copies the first Machine address to `node.IP` with no agent call (`ACT/capi_node_resources.go:262-314`).
2. The readiness controller calls `GetKubeadmStatus` on a timer and keeps `agent_version` (`CI/controllers/nodeagentreadiness/controller.go:116-133`, `CI/agent/client.go:151-163`). `EnsureNodeAgentVersion` runs before the preflight only when the node context has an agent version (`CI/temporal/workflows/provision_node.go:184-209`).
3. `NodePreflight` calls `GetKubeadmStatus` if the node row has no agent version, and it stops as not ready when the version is empty (`ACT/node_preflight.go:53-66`). Then it calls `ExecuteNodePreflight`. For a `DockerMachineTemplate`, or with the setting `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP`, the request has one check with the name `cluster-api-bootstrap-success` and `file_exists.path` `/run/cluster-api/bootstrap-success.complete` (`ACT/node_preflight.go:20-21, 107-133`, `ACT/capi_shared.go:20-64`). For each other kind the request has `check_cloud_init_status: {}`. The agent then passes on the file `/var/lib/dsxos/.cidata-consumed` or on `status: done` from `cloud-init status --long` (`AG/internal/agent/preflight.go:98-185`). The workflow tries again with no end (`CI/temporal/workflows/provision_node.go:376-402`).
4. Only with `cniPlugin: ovn-kubernetes`, the controller calls `StartOpenVSwitchReconciliation` and then `GetOpenVSwitchReconciliationStatus` (`CI/temporal/workflows/provision_node.go:404-438`, `ACT/configure_open_vswitch.go:79-125`).
5. `ConfigureKubeVip` returns at once when the cluster has no VIP (`ACT/configure_kube_vip.go:90-93`).
6. `KubeadmInit` calls `GetKubeadmStatus`. If the phase is `initialize` and the status is `ready` or `pending`, it goes to step 9 (`ACT/kubeadm_init.go:85-102`).
7. The controller asks gRPC reflection for the symbols `proto.KubeadmInitRequest.files` and `proto.KubeadmJoinRequest.files` (`CI/agent/kubeadm_files.go:39-106`, `ACT/kubeadm_patches.go:24-53`).
8. The controller calls `ExecuteKubeadmInit` (`ACT/kubeadm_init.go:135-184`). The agent answers `pending` and runs kubeadm in the background (`AG/internal/agent/agent.go:800-822`).
9. The controller polls `GetKubeadmStatus` until `kubeadm_status` is `ready` and `kubeadm_phase` is `initialize`. It also needs `cni_install_status` `ready` when the agent installs the CNI during init. The status `error` is final (`ACT/kubeadm_init.go:207-254`).
10. With the setting `installCNIAfterInit`, which Tilt sets, the controller calls `InstallCNI` one time (`ACT/install_cni.go:56-108`, `C/Tiltfile:1098-1103`).
11. Later the tenant access controller calls `GetKubeconfig`, and the agent returns `/etc/kubernetes/admin.conf` with no change (`CI/controllers/tenantaccess/kubeconfig.go:113-118`, `AG/internal/agent/agent.go:1522-1548`). The controller calls `UpdateAndFetchKubeAdmJoinStrings` only when a second node joins (`ACT/kubeadm_join.go:338`).
The `ExecuteKubeadmInit` request has these fields (`ACT/kubeadm_init.go:135-176`):
- `init_config` is the YAML below, `control_plane_endpoint` is the VIP or the node IP, and `pod_network_cidr` and `service_cidr` are the cluster values.
- `api_encryption_enabled` is the cluster setting, `objects_to_encrypt` is `["secrets"]`, and the key and its name are present only with encryption.
- `no_cni_install` is true when the CNI comes after init. With OVN the request also has `use_ovn_k8s_cni: true`, `cni_plugin_name: "ovn"` and `ovn_version`. With Calico it has `cni_plugin_name: "calico"` and `tigera_version`. `cni_config` is present only with a CNI image registry.
- `files` has four entries with the owner `root:root`. They are `/etc/kubernetes/patches/kubeletconfiguration0+merge.yaml` (0644), `/etc/kubernetes/patches/kube-apiserver-base-graceful-shutdown+merge.yaml` (0644), `/etc/kubernetes/policies/audit-policy.yaml` (0644) and `/etc/kubernetes/oidc/auth-config.yaml` (0600, for Kubernetes 1.34 and later) (`CI/kubeadmconfig/init.go:128-146`, `CI/kubeadmconfig/render.go:423-462`, `CI/kubeadmconfig/audit_policy.go:13-20`, `CI/kubeadmconfig/oidc.go:27, 156-168`). The agent requires a path, a mode and an owner for each file (`AG/internal/agent/kubeadm_prerequisite_files.go:116-148`). The fourth file permits anonymous access only to `/livez`, `/readyz`, `/healthz`, `/version` and the `cluster-info` ConfigMap (`CI/kubeadmconfig/testdata/auth_config_anonymous_only.yaml`).
- The controller does not set `extraApiCertSans`, `extra_args`, `use_staging`, `kubernetes_version` or `skip_cni_plugin_install`.
The rendered configuration for Kubernetes 1.36.4 follows, in a short form. Each `name=value` is one entry with `name` and `value`, and the full layout is in `CI/kubeadmconfig/testdata/init_local_dev.yaml`. The sources are `CI/kubeadmconfig/init.go:170-334`, `render.go:304-379` and `v1beta4.go:100-162`. With no VIP the controller sets E to the node IP, so E is equal to A (`ACT/kubeadm_init.go:80-83`). A client can send a different E.
```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
bootstrapTokens: [{token: <generated>, ttl: 24h0m0s, groups: ["system:bootstrappers:kubeadm:default-node-token"], usages: [signing, authentication]}]
localAPIEndpoint: {advertiseAddress: A, bindPort: 6443}
nodeRegistration: {name: <node name>, criSocket: "unix:///var/run/containerd/containerd.sock", imagePullPolicy: IfNotPresent, kubeletExtraArgs: [node-ip=A]}
nodeRegistration.ignorePreflightErrors: [SystemVerification]   # container mode only
patches: {directory: /etc/kubernetes/patches}
skipPhases: [addon/kube-proxy]                                 # only with cniPlugin ovn-kubernetes
timeouts: {controlPlaneComponentHealthCheck: 4m0s}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: <cluster version>, clusterName: kubernetes, controlPlaneEndpoint: E, certificatesDir: /etc/kubernetes/pki, imageRepository: registry.k8s.io
networking: {dnsDomain: cluster.local, podSubnet: <pod CIDR>, serviceSubnet: <service CIDR>}
apiServer.extraArgs: audit-log-maxage=30, audit-log-maxbackup=10, audit-log-maxsize=100, audit-log-path=/var/log/kubernetes_audit/audit.log, audit-policy-file=/etc/kubernetes/policies/audit-policy.yaml, authentication-config=/etc/kubernetes/oidc/auth-config.yaml, bind-address=0.0.0.0, enable-admission-plugins=NodeRestriction,DenyServiceExternalIPs,OwnerReferencesPermissionEnforcement,PodNodeSelector,PodTolerationRestriction, etcd-compaction-interval=5m, kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt, profiling=false, service-account-extend-token-expiration=false, shutdown-delay-duration=10s, shutdown-send-retry-after=true, shutdown-watch-termination-grace-period=20s, tls-cipher-suites=<6 suites>
apiServer.extraVolumes: audit-logs /var/log/kubernetes_audit, audit-policies /etc/kubernetes/policies (read only), oidc-auth-config /etc/kubernetes/oidc (read only)
controllerManager.extraArgs: bind-address=127.0.0.1, large-cluster-size-threshold=50, profiling=false, secondary-node-eviction-rate=0, terminated-pod-gc-threshold=12500
scheduler.extraArgs: bind-address=127.0.0.1, profiling=false
etcd.local: {dataDir: /var/lib/etcd, extraArgs: auto-compaction-retention=1, bootstrap-defrag-threshold-megabytes=200, listen-metrics-urls=http://0.0.0.0:2381, quota-backend-bytes=17179869184}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
metricsBindAddress: 0.0.0.0:10249
conntrack: {maxPerCore: 0, min: 0}                             # container mode only
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true, serializeImagePulls: false, maxParallelImagePulls: 4, podPidsLimit: 16384, seccompDefault: true, tlsCipherSuites: <6 suites>
failSwapOn: false                                              # container mode only
kubeReserved: {cpu: 1000m, memory: 2Gi, ephemeral-storage: 1Gi}   # container mode has 100m, 256Mi, 256Mi
systemReserved: {memory: 16Gi}                                    # container mode has 256Mi
```
The two modes differ in four places, and the four files are the same in the two modes:
- Container mode adds `ignorePreflightErrors: [SystemVerification]` (`CI/kubeadmconfig/init.go:193-197`).
- Container mode sets the two kube-proxy `conntrack` values to 0 (`CI/kubeadmconfig/render.go:313-322`).
- Container mode sets `failSwapOn: false` (`CI/kubeadmconfig/render.go:358-364`).
- Container mode has the small kubelet reservations (`CI/kubeadmconfig/render.go:348-376`).
In this image the kubeadm shim makes the two modes almost equal. It always adds the flag for `SystemVerification`, and it writes `failSwapOn`, the small reservations and `conntrack.maxPerCore: 0` into the configuration (`IMG/scripts/kubeadm-systemverification-shim:50-92`, `IMG/scripts/update-kubeadm-config-for-containers:59-82`). The kubelet patch file has the reservations of the pool in the two modes, with the defaults 16Gi and 2Gi (`CI/kubeadmconfig/init.go:131`, `CI/kubeadmconfig/render.go:440-462`). kubeadm applies that patch after the configuration (not in this source), and the kubelet does not start when the reservation is larger than the capacity (`CI/kubeadmconfig/render.go:365-368`). CI sets `systemReservedMemory: "1Gi"` (`R/cli/examples/capd-cluster.yaml:20`). So the client must send a patch file with reservations below the guest memory.

## 4. The cloud-config on the infra path with a join token
**Conclusion.** With no caller additions the cloud-config has three files and one command. A wrapper can write the two SPIRE files before systemd starts, and then the command is not necessary.
The `write_files` entries are in this order (`CI/clients/capi/bootstrap_userdata.go:101-148`):
1. Each entry of `infra.bootstrapFiles` of the caller, with its path, owner, permissions and content.
2. `/etc/spire-agent/initial-trust-bundle.pem`, owner `root:root`, permissions `0644`. The content is the trust bundle in PEM form (`CI/constants/constants.go:113`, `CI/spiffe/spiffe.go:17-53`).
3. `/etc/spire-agent/agent.conf`, owner `root:root`, permissions `0644`. The content is `CI/clients/capi/capi_spire_agent.conf.tmpl` with `join_token` and with the `NodeAttestor "join_token"`, `KeyManager "disk"` in `/var/lib/spire-agent` and `WorkloadAttestor "unix"` blocks.
4. The agent environment file, owner `root:root`, permissions `0644`, content `AGENT_ARGS="--secure-server-port 15005"` (`ACT/activities.go:64-93`). The path is `/etc/default/nke-agent` for a new node, because the node row has no agent version (`CI/nodecontract/nodecontract.go:43-75`, `CI/config/config.go:42`). The image file `/etc/default/nvke-agent` is read later, so its values stay in use (not in this source for the systemd rule).
The `runcmd` entries are each `infra.preKubeadmCommands` entry of the caller and then `systemctl restart nke-agent.service` (`CI/clients/capi/bootstrap_userdata.go:150-151`). The callers for container nodes add `mkdir -p /run/cluster-api` and `echo success > /run/cluster-api/bootstrap-success.complete` (`R/cli/examples/capd-cluster.yaml:22-24`).
nico-sim does these steps with `docker exec` (`SIM/docker.go:136-221`). It writes `running` to `/var/lib/nico-containers/cloud-init/status`. It writes each file and applies the permissions and the owner. It writes the commands to `/var/lib/nico-containers/cloud-init/runcmd.sh` and starts that script detached. The script writes `done` or `error` to the status file. The cloud-init shim of the image reads that file (`IMG/scripts/cloud-init-status-shim:33-54`).
A pod must do these steps in the wrapper, before the kind entrypoint:
1. Write the trust bundle and `agent.conf` from a Secret at each start, because `/etc/spire-agent` is outside the volumes. `/var/lib/spire-agent` must be on the `/var` volume. A join token works one time (not in this source), so an empty `/var` needs a new token.
2. Leave `/etc/default/nvke-agent` as it is for mTLS. For the plaintext run, write it again with `--disable-mtls` added to the image arguments.
3. Write `done` to `/var/lib/nico-containers/cloud-init/status`. For the sentinel form, make `/run/cluster-api/bootstrap-success.complete` after systemd is up, because I did not verify that a file in `/run` stays through the start.
4. Set the pod hostname to the node name. nico-sim sets the container hostname to that name (`SIM/service.go:257`).
5. Optionally bind a boot ID file from `/var`, then run `exec /usr/local/bin/entrypoint /sbin/init` (`SIM/service.go:33-42`).

## 5. A client for step A and step B
**Conclusion.** No tool in the repository does the two steps. `grpcurl` is sufficient for step A in plaintext mode only. A Go program of about 150 lines does step A and step B, and it is the best way.
- The agent registers gRPC reflection, and the service name is `proto.NodeAgent` (`AG/internal/grpcserver/register.go:17-20`, `AG/pkg/agent/proto/node_agent.proto:6-10`). `grpcurl` is not on the PATH of this machine. With SPIFFE it cannot check the agent ID, because the certificate has no DNS name (not in this source).
- `AG/scripts/grpcurl-lib.sh:181-200` and `C/test/kubeadm/internal/cluster/init.go:52-117` use plaintext by default and send no `init_config`, so their init call fails with this image. The second one is an internal package behind the build tag `kubeadm_bringup`.
- The controller transport is internal and needs a database node record (`CI/agent/transport.go:123`). nvkectl has no command that calls the agent. I found no import of the agent proto package in `R/cli`.
```
grpcurl -plaintext -d '{}' <service>:15005 proto.NodeAgent/GetKubeadmStatus
grpcurl -plaintext -d '{"checkCloudInitStatus":{}}' <service>:15005 proto.NodeAgent/ExecuteNodePreflight
jq -n --rawfile c init.yaml --arg k "$(base64 -w0 kubelet-patch.yaml)" '{initConfig:$c, controlPlaneEndpoint:"E", podNetworkCidr:"<pod CIDR>", serviceCidr:"<service CIDR>", objectsToEncrypt:["secrets"], noCniInstall:true, files:[{path:"/etc/kubernetes/patches/kubeletconfiguration0+merge.yaml", content:$k, mode:420, owner:"root:root"}]}' | grpcurl -plaintext -d @ <service>:15005 proto.NodeAgent/ExecuteKubeadmInit
grpcurl -plaintext -d '{}' <service>:15005 proto.NodeAgent/GetKubeconfig | jq -r .kubeconfig
```
The `files` list in that command needs the three other files in the same form, with mode 384 for the file with 0600. The Go program has these parts:
- A separate module in the lab folder that imports `github.com/dsx-ai-factory/nvke/agent/pkg/agent/proto`, with a `replace` line to `R/agent`. It also imports `workloadapi`, `spiffeid`, `spiffetls/tlsconfig` and `spiffegrpc/grpccredentials` from go-spiffe v2.9.0, and `google.golang.org/grpc`.
- Flags for the address, the socket, the expected agent ID, the configuration file, the four files and a plaintext switch.
- `workloadapi.NewX509Source`, then `grpccredentials.MTLSClientCredentials(source, source, tlsconfig.AuthorizeID(expected))`, then `grpc.NewClient`. These are the calls of the controller (`CI/agent/transport.go:244-262`).
- The calls of section 3 in order, with `no_cni_install: true` and a poll each 10 seconds, then `GetKubeconfig` and `GetSpireAgentStatus`. The last call returns the SVID ID that the agent holds (`AG/internal/agent/spire_agent.go:187-246`).
- For the evidence, print the peer ID with `grpccredentials.PeerIDFromPeer`. Run one call with a wrong expected ID, and run one call with a client ID outside the four prefixes. The two calls must fail.
- To get the configuration text, copy the block of section 3 into the full layout, or call `kubeadmconfig.InitConfig.Render` from a small program in a copy of the controller module, because the package is internal.

## 6. The local NVKE stack as the alternative
**Conclusion.** Use the small client for step A. The local stack cannot use a pod that exists, and it always installs a CNI, which the plan does not want and the Kata guest cannot run with OVN.
- The stack is a kind cluster `controller-capi` with Cluster API, PostgreSQL, Temporal, SPIRE, cert-manager, the controller, CAPNICo, nico-sim and a BGP container (`R/docs/get-started/quickstart-local.md:9-14, 117-170`, `C/Tiltfile:540-760`).
- The quickstart asks for 6 CPUs, 12 GiB of free memory, 100 GiB of free disk and ten free ports (`R/docs/get-started/quickstart-local.md:7, 21, 26`). I found no start time in the source. The CI job for the short suite has a limit of 30 minutes (`R/.github/workflows/nico-e2e.yml:119-124`).
- The node makers of the stack make Docker containers. nico-sim runs `docker create` (`SIM/service.go:254-279`), and the CAPD example mounts the Docker socket (`R/cli/examples/capd-cluster.yaml:25-34`). So a `DockerMachineTemplate` cannot target a pod.
- The provisioned provider can bind an address that exists, and the setting `LOCAL_DEV_FORCE_DOCKER_MACHINE_BOOTSTRAP` gives each kind the sentinel preflight and the container mode (`CI/config/config.go:372-381`, `ACT/capi_shared.go:27-29`). But the Tiltfile has no entry for that provider, and the provider does not give the bootstrap Secret to the host (`~/notes/hosted/results/architecture-reading.md`, Q2).
- The controller accepts only `ovn-kubernetes` or `calico` (`ACT/kubeadm_init.go:166-176`). OVN needs Open vSwitch before the node is ready to join (`CI/temporal/workflows/provision_node.go:404-438`), and the image has only the OVN packages.
- The client sends the same `ExecuteKubeadmInit` request with the same mTLS calls, so the agent code under test is the same. The client does not test the controller transport, the Temporal workflows or the certificate approval for the kubelet. The controller parts belong to phase 1.
- The stack also pulls many images at one time, which is against the rule for the VPN agent in `~/notes/hosted/PROMPT.md` section 5.

## 7. The systemd units of the image in the Kata guest
**Conclusion.** From the source I expect two unit failures in the Kata guest, Open vSwitch and the network unit that requires it. They do not block the agent or kubeadm. The SPIRE agent restarts in a loop until the pod supplies its files, and that state blocks the agent port in mTLS mode.

| Unit or shim | Source | What it needs | In the Kata guest | Effect |
|---|---|---|---|---|
| `nvke-agent.service` | `IMG/Dockerfile:153-165, 295` | Section 1 | It starts, and the port opens as section 1 says | Necessary |
| `spire-agent.service`, as root | `IMG/Dockerfile:195-222, 295`, `C/hack/ci/assets/spire-agent.service:4-18` | `agent.conf`, the bundle, a route to the SPIRE server | It restarts each 5 seconds until the files exist | It blocks port 15005 in mTLS mode |
| `etcd-data-dir.service` | `IMG/systemd/etcd-data-dir.service:8-17` | The user `etcd`, and the etcd volume mounted before systemd | I found no dependency on the guest | Harmless |
| `nke-container-cni-images.service` | `IMG/scripts/nke-container-cni-images.service:4-19` | containerd, the file `/usr/lib/nvke/e2e/cni-images.deb`, space in `/var` | It installs the package at each start, and the agent waits for it. The package script is not in this repository | Harmless if containerd works. The wrapper can delete the file to skip the unit |
| `ovs-vswitchd.service` | `IMG/Dockerfile:83, 107-109` | `/sys/module/openvswitch` or `modprobe openvswitch` | It fails, because the guest has no module | Harmless for step A and step B. It blocks only OVN |
| `nke-container-network.service` | `IMG/scripts/nke-container-network.service:4-17`, `IMG/scripts/prepare-container-network:19-62` | Open vSwitch, udev, D-Bus, one default route with a gateway | It fails as a dependency, and writes no netplan file | Harmless. The agent has only an order after it |
| `systemd-networkd.service` | `IMG/Dockerfile:110-111` | Nothing | Not found in the source what it does to `eth0` with no netplan file | Check in the lab |
| `swtpm-local.service` | `IMG/Dockerfile:296-300`, `C/hack/backend-e2e-lib.sh:37-45` | `/dev/vtpmx` | The join token image has it off | None. The `tpm` image cannot work in the guest |
| `nke-attestation.service` | `IMG/Dockerfile:294` | Not found in the repository | Not present | None |
| kubeadm shim | `IMG/Dockerfile:52-59` | `--config` for `init` | I found no dependency on the guest | It hides `SystemVerification`. Run `/usr/bin/kubeadm.real init phase preflight` with the configuration file by hand for the list of kernel options |
| cloud-init shim | `IMG/Dockerfile:66-67` | The status file in `/var` | It answers `running` with no file | It blocks only a cloud-init preflight |
| reboot shim | `IMG/Dockerfile:36-48` | `systemctl poweroff` | Kubernetes makes a new container | `ScheduleNodeReboot` runs `reboot` (`AG/internal/agent/node_reboot.go:36-62`). The two steps do not call it |
| kubelet arguments | `IMG/Dockerfile:238` | Nothing | `--fail-swap-on=false` has no effect with no swap | Harmless |

In the runc pod the kernel module of the host is present, so `nke-container-network.service` runs `netplan apply` and gives `eth0` to systemd-networkd with the same address and route (`IMG/scripts/prepare-container-network:41-62`). I did not find more about that case in the source.
