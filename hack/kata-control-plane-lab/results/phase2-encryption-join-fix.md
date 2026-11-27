# A fix in the NVKE node agent for the join of a control plane node after encryption is turned on (phase 2 gaps)

An agent wrote this fix on 2026-11-27. The work ran from 12:38 to 12:50 EST and, after a restart of the Claude session, from 14:24 to 14:39 EST. The fault came out of step T2-11 of the phase 2 gaps run (`lab/phase2-gaps-run/progress.txt`). Nothing is pushed. There is no pull request and no issue.

| Item | Value |
|---|---|
| Branch | `fix/agent-encryption-join-config`, one commit on `d625fcfa`, local only |
| Commit | `06ffc4981ccaa7e2f6fa8b0ddebc9247dc96fb1a`, "fix(agent): merge API encryption into the kubeadm-config ConfigMap" |
| Worktree | `/scratch/kata-cp/src/nvke-encfix` |
| Size | 2 files, 562 lines added, 25 lines removed |
| Sign-off | Yes. No GPG signature, no agent text, no `Co-Authored-By` |
| gRPC API and `.proto` | No change |
| New dependency | None. `make notices-check` passes |
| Lab branch | `lab/agent-fix-gate-encryption` at `41e88c4d`, local only, worktree `/scratch/kata-cp/src/nvke-agentlab2` |
| Lab binary | `/scratch/kata-cp/work/phase2-gaps/bin-encfix/nvke-agent`, sha256 `cafddb1d4d28c79f2a07e05539440fd04402842d7c2157be754be3826b1e8a33` |
| Proof files | `/scratch/kata-cp/logs/phase2-encryption-join-fix/` |

Line numbers are the lines of `d625fcfa`, except in section 4, which has the lines of `06ffc498`. Paths of kubeadm and the kubelet are paths in the Kubernetes source at the tag `v1.36.4`.

## 1. The fault

The lab cluster c-1 had three control plane nodes with Kubernetes 1.36.4 and no encryption. The lab turned encryption on through the NVKE API (T2-08) and then started a rollout (T2-11). The new control plane node never joined.

- The kubelet of the new node logged "MountVolume.SetUp failed for volume encryption-config" with "hostPath type check failed: /etc/kubernetes/encryption-config.yaml is not a file", 30 times in 18 minutes.
- The API server pod of the new node never started, so `kubeadm join` ran into its timeout.
- `JoinNode` failed 3 times and ran a fourth time when the lab recorded the evidence and deleted the cluster.
- The evidence of the lab is in `/scratch/kata-cp/logs/bigbox/remote-logs/p2gaps/c-1/`, in the files `defect-encryption-join.txt` and `kubeadm-clusterconfiguration-after-enc.yaml`.

The cause is in one function of the agent, `updateEncryptionEntryForKubeadmConfigMap` (`agent/internal/agent/etcd_encryption_at_rest.go`, lines 889 to 941). The function has two faults.

1. It writes one volume into the `kubeadm-config` ConfigMap, for the host file `/etc/kubernetes/encryption-config.yaml` with the path type `File` (lines 916 to 924). No code creates that file. The agent keeps its encryption config in `/etc/kubernetes/kube-api-encryption/encryption-config.yaml` (line 766).
2. It replaces the whole `apiServer` section of the ClusterConfiguration, and not only the volume list. The function parses the document with `gopkg.in/yaml.v2` (lines 21 and 903). The library gives a nested map the type `map[interface{}]interface{}`. The type assertion to `map[string]any` at line 910 fails every time, so lines 912 and 913 start from an empty section.

The function runs only on the node that ran `kubeadm init`. `InitializeKubernetesAPIEncryption` calls it behind the check `s.NodeStatus.IsMaster` (lines 289 to 293), and only `ExecuteKubeadmInit` sets that field (`agent/internal/agent/agent.go`, line 802). The fault shows when encryption is turned on while that node is a member of the cluster. The lab cluster was in that state.

The controller writes the ConfigMap after the agent. At the end of its workflow it adds the two encryption flags and a volume with the name `enc` (`controller/internal/temporal/workflows/enable_etcd_encryption.go`, line 134). It replaces a volume only when the name is the same, so the wrong volume of the agent stays. The other settings that the agent dropped do not come back.

`kubeadm join` builds the API server manifest of a new control plane node from that ClusterConfiguration. The kubelet checks a host path of the type `File` and refuses a path that is missing (`pkg/volume/hostpath/host_path.go`, lines 478 to 481). The text of that error is the text in the lab log.

## 2. The answers to the six questions

### Question 1. What the enable flow changes on a node that is in the cluster

The controller runs the workflow `enableEtcdEncryption` (`controller/internal/temporal/workflows/enable_etcd_encryption.go`, lines 66 to 150). The steps are in this order:

1. Line 87 checks that the ConfigMap can take the encryption settings. The step writes nothing.
2. Lines 104 to 113 call `InitializeKubernetesAPIEncryption` on each control plane node, one node at a time (lines 190 to 210). The call is in `controller/internal/rollout/operations/etcd/encryption.go`, lines 178 to 180.
3. Lines 114 to 120 call `PromoteKubernetesAPIEncryptionProviders` on each node.
4. Line 122 starts the rewrite of the stored objects on one node and polls its status.
5. Lines 126 to 132 call `RemovePlainTextSecondaryEncryptionEntry` on each node.
6. Line 134 merges the encryption settings into the ConfigMap from the controller (`controller/internal/temporal/activities/kubeadm_config.go`, lines 39 to 53, and `controller/internal/kubeadmconfig/configmap.go`, lines 219 to 272).
7. Lines 137 to 147 finalize the key and mark the cluster as encrypted.

`InitializeKubernetesAPIEncryption` does these steps on the node (`agent/internal/agent/etcd_encryption_at_rest.go`):

- Line 213 sets the node label `nvke.nvidia.com/k8s-api-encryption-configured=true`.
- Line 225 writes `/etc/kubernetes/kube-api-encryption/encryption-config.yaml` with mode 0600 (lines 755 to 855). The provider order is identity first and secretbox second (lines 100 to 114).
- Line 239 calls `createVolumeMountEntries` (lines 640 to 680). It runs `sed -i` two times on `/etc/kubernetes/manifests/kube-apiserver.yaml`. It adds a host path volume with the name `encryption-config` for the directory `/etc/kubernetes/kube-api-encryption` with the type `DirectoryOrCreate` (lines 116 to 119), and a read-only mount of that directory (lines 121 to 123).
- Line 253 calls `modifyAPIServerManifest` (lines 682 to 717). It runs `sed -i` two more times and adds the flags `--encryption-provider-config=/etc/kubernetes/kube-api-encryption/encryption-config.yaml` and `--encryption-provider-config-automatic-reload=true`.
- Lines 273 to 287 wait until the API server is ready again.
- Lines 289 to 293 update the ConfigMap, on the node that ran `kubeadm init` only.

The later RPCs change the config file only. The promote step writes the file again with secretbox first (lines 300 to 333). The remove step deletes the line `identity: {}` from the file (lines 450 to 470) and changes node labels.

The local manifest and the local file of each existing node are correct after the flow. The ConfigMap is the only wrong part.

### Question 2. What a join of a control plane node does when the request carries the key

- The controller puts the key and the key name into the join request for a control plane node of an encrypted cluster (`controller/internal/temporal/activities/kubeadm_join.go`, lines 146 to 155).
- The agent writes the encryption config before kubeadm runs (`agent/internal/agent/agent.go`, lines 643 to 652). It writes the same path as on the other nodes, with secretbox first and identity second (`etcd_encryption_at_rest.go`, lines 732 to 734 and 81 to 95).
- The agent then runs `kubeadm join --config /tmp/kubeadm-join-config.yaml` (`agent.go`, lines 654 to 675).
- The flag and the volume of the new API server come only from the ClusterConfiguration in the ConfigMap. The join request has no API server settings. kubeadm reads the document from the cluster (`cmd/kubeadm/app/util/config/cluster.go`, lines 84 to 124) and builds the manifest from it (`cmd/kubeadm/app/cmd/phases/join/controlplaneprepare.go`, lines 189 to 210). Each entry of `apiServer.extraVolumes` becomes a host path volume (`cmd/kubeadm/app/phases/controlplane/volumes.go`, lines 89 and 137 to 142).
- The patches folder of the join holds one patch for the API server, and that patch sets only the termination grace period (`controller/internal/kubeadmconfig/render.go`, lines 423 to 438).
- Nothing changes the manifest after the join. The agent changes kubelet settings only (`agent.go`, lines 693 to 699). The controller sets labels and taints, checks the role label, configures kube-vip and marks the node as provisioned (`controller/internal/temporal/workflows/provision_node.go`, lines 300 to 343).

So a wrong ConfigMap gives a wrong manifest on the new node, and no later step corrects it.

### Question 3. A cluster that has encryption from its creation

- The create request sets `EtcdEncrypted` (`controller/internal/server/clusters.go`, line 1511).
- The controller renders the init config with the two flags and the volume `enc` for the directory `/etc/kubernetes/kube-api-encryption`, with the type `DirectoryOrCreate` and read-only (`controller/internal/kubeadmconfig/init.go`, lines 290 to 295, `render.go`, lines 464 to 476, and `configmap.go`, line 37).
- The agent writes the config file before `kubeadm init` runs (`agent.go`, lines 888 to 895).
- kubeadm stores the ClusterConfiguration of the init config in the ConfigMap. Section 3 shows the stored document from real kubeadm.
- The agent function with the fault never runs for such a cluster. The workflow returns early (`enable_etcd_encryption.go`, lines 80 to 82) because the cluster is marked as encrypted (`controller/internal/temporal/activities/enable_etcd_encryption.go`, lines 53 to 55).

A join on such a cluster works. The agent writes the file into the directory, and kubeadm builds a manifest that mounts the directory and names the file in the flag. A cluster with encryption from its creation does not have the defect. I have that from the source and from the manifest that real kubeadm builds. I did not run a cluster.

| ConfigMap content under `apiServer` | Created with encryption | Encryption turned on later, old agent | Encryption turned on later, fixed agent |
|---|---|---|---|
| The 16 flags that the controller renders | Present | Lost | Present |
| The two encryption flags | Present | Present, from the controller | Present |
| Volumes `audit-logs`, `audit-policies`, `oidc-auth-config` | Present | Lost | Present |
| Volume `enc`, directory, `DirectoryOrCreate` | Present | Present, from the controller | Present |
| Volume `encryption-config`, missing file, `File` | Absent | Present | Absent |

With the fix the two paths differ only in the order of the entries in the two lists.

### Question 4. Whether the replace drops the volumes of the init config

Yes, and it drops more than the volume list. The function replaces the whole `apiServer` section, so every setting that `kubeadm init` stored there is lost.

- For the lab version 1.36.4 the controller renders 16 flags and 3 volumes. The fixture `controller/internal/kubeadmconfig/testdata/init_base.yaml` shows them at lines 27 to 77. The fixture is for 1.34.2 and has one more flag, for a feature gate.
- The ConfigMap of the lab cluster confirms it. The file `kubeadm-clusterconfiguration-after-enc.yaml` has only the two encryption flags, the wrong volume and the volume `enc` under `apiServer`.
- A field such as `certSANs` is lost in the same way. The NVKE renderer does not set that field.

The effect on a node that joins has two parts. The wrong volume stops the API server pod, which is the fault of the lab. If the wrong volume were not there, the API server would start with the defaults of kubeadm. It would have no audit log and no audit policy, only the admission plugin `NodeRestriction`, no `--authentication-config` and no TLS cipher list. The full list of the lost flags is in section 3.

### Question 5. What kubeadm upgrade and the NVKE rollout and upgrade flows do with the `apiServer` part of the ConfigMap

- An NVKE upgrade does three things in order. It writes the new version into the ConfigMap, it replaces every control plane node, and it runs `kubeadm upgrade apply` on one control plane node (`controller/internal/controllers/controlplane/k8s_upgrade.go`, lines 119 to 137 and 83 to 116).
- The ConfigMap step sets `kubernetesVersion` and merges the etcd settings (`controller/internal/temporal/workflows/update_kubeadm_configmap.go`, lines 50 to 72, and `configmap.go`, lines 161 and 316). It keeps what is under `apiServer` and adds the flag `etcd-compaction-interval`. It does not remove the wrong volume, and it does not put the other lost flags back.
- A rollout and the node step of an upgrade make each new node with `kubeadm join`. With the wrong ConfigMap the flow stops at the first node, as in the lab.
- `kubeadm upgrade apply` builds the manifests of the node from the same ClusterConfiguration (`cmd/kubeadm/app/cmd/phases/upgrade/apply/controlplane.go`, lines 55 to 66). It replaces a manifest that differs (`cmd/kubeadm/app/phases/upgrade/staticpods.go`, line 218), waits for the new pod, and puts the old manifest back when the pod does not come up (lines 252 to 275). With the wrong ConfigMap, the command would write a manifest that the kubelet refuses, and then fail. I did not run that case.
- No NVKE flow repairs the `apiServer` section of a cluster that has the wrong content.

With the fixed agent the ConfigMap has the volume `enc`. A node whose manifest came from the `sed` edits has the volume name `encryption-config` for the same directory. `kubeadm upgrade apply` on such a node replaces the manifest with one that has the name `enc`, the same directory and the same flags.

### Question 6. Whether the defect is specific to a node in a pod

No. The source has no branch for the kind of node on this path.

- The agent function, the ConfigMap, the manifest code of kubeadm and the host path check of the kubelet are the same on bare metal, in a virtual machine and in a pod.
- The local development switch of the agent adds one preflight flag to `kubeadm join` (`agent.go`, lines 663 to 670). The container mode of the controller changes kubelet and kube-proxy settings only (`render.go`, lines 304 to 325 and 358 to 377).
- I reproduced the wrong ConfigMap and the wrong manifest on the workstation with no node at all.

## 3. The proof with real kubeadm

The kubeadm program is the file `/usr/bin/kubeadm` of the local image `kindest/node:v1.36.4`. I copied it out with `docker create` and `docker cp` and removed the container. The container never started. `kubeadm version -o short` prints `v1.36.4`. No cluster ran. Every kubeadm command ran without root, in dry-run mode, with a private dry-run folder (`KUBEADM_INIT_DRYRUN_DIR`). The control plane endpoint in the config was `127.0.0.1:6443`.

The steps:

1. The init renderer of the controller made the init config for 1.36.4, one time without encryption and one time with encryption. `kubeadm config validate` accepted both.
2. `kubeadm init phase upload-config kubeadm --dry-run` printed the ClusterConfiguration that kubeadm stores in the ConfigMap, for both configs.
3. The old agent function ran on the stored document of the cluster without encryption. Then the merge function of the controller ran on the output.
4. The fixed agent function ran on the same stored document. Then the merge function of the controller ran on the output.
5. `kubeadm init phase control-plane apiserver --dry-run` built the API server manifest from each document.

`kubeadm join` needs a cluster for its discovery step, so I used the init phase for step 5. The init phase and the join phase call the same function, `controlplane.CreateStaticPodFiles`, with the ClusterConfiguration (`cmd/kubeadm/app/cmd/phases/init/controlplane.go`, line 147, and `cmd/kubeadm/app/cmd/phases/join/controlplaneprepare.go`, lines 203 to 210).

The results:

- The stored document of a cluster created with encryption differs from the document without encryption in 9 lines. They are the two flags and the volume `enc`.
- After the old agent function, the `apiServer` section has one volume and nothing else. The 16 flags and the 3 volumes are gone.
- After the old agent function and the controller merge, the `apiServer` section is the same, line for line, as the section in the ConfigMap of the lab cluster. The rest of the two documents differs only in the endpoint, the two subnets and the kube-proxy setting of the lab.
- The manifest that kubeadm builds from that document has the wrong volume. The manifest of the lab node has the same three lines.

```yaml
  - hostPath:
      path: /etc/kubernetes/encryption-config.yaml
      type: File
    name: encryption-config
```

- The same manifest lacks 15 flags of a cluster created with encryption. They are the four `--audit-log-*` flags, `--audit-policy-file`, `--authentication-config`, `--bind-address`, `--etcd-compaction-interval`, `--kubelet-certificate-authority`, `--profiling`, `--service-account-extend-token-expiration`, the three `--shutdown-*` flags and `--tls-cipher-suites`. A sixteenth flag has another value. The manifest has `--enable-admission-plugins=NodeRestriction` in place of the list of five plugins.
- After the fixed agent function, the stored document has 9 more lines than before and no other change. The merge function of the controller reports no change for it, and its output is the same file byte for byte.
- The manifest from that document has 169 lines, the same count as the manifest of a cluster created with encryption. The two manifests have the same lines. Only the two encryption flags are at another place in the command.
- The fixed agent function leaves the stored document of a cluster created with encryption the same byte for byte.
- The fixed agent function, run on the document of the lab cluster, removes the 5 lines of the wrong volume and nothing else.

The documents and the manifests are in `/scratch/kata-cp/logs/phase2-encryption-join-fix/`. I did not start an API server, so the proof covers the ConfigMap and the manifest and not a running pod.

## 4. The fix

The agent now merges the encryption settings into the ClusterConfiguration and keeps everything else. The settings are the settings that the controller renders for a cluster created with encryption, so the two paths give the same ConfigMap.

| File | Lines at `06ffc498` | Content |
|---|---|---|
| `agent/internal/agent/etcd_encryption_at_rest.go` | 22 | Import of `sigs.k8s.io/yaml`, which the agent module already uses |
| Same file | 58 to 79 | Constants for the two kubeadm API versions, the flags, the directory, the volume name `enc`, and the name and path of the old volume |
| Same file | 913 to 942 | `updateEncryptionEntryForKubeadmConfigMap` reads the ConfigMap, calls the merge and writes the ConfigMap |
| Same file | 944 to 1016 | `mergeEncryptionIntoClusterConfiguration`, the new merge |
| Same file | 1018 to 1042 | Two small helper functions, `clusterConfigurationField` and `upsertNamedEntry` |
| `agent/internal/agent/etcd_encryption_at_rest_test.go` | 605 to 1032 | Fixtures and three test functions |

The merge does these steps:

1. It parses the document with `sigs.k8s.io/yaml`, which gives nested maps the type `map[string]any`.
2. It accepts the API versions `kubeadm.k8s.io/v1beta3` and `kubeadm.k8s.io/v1beta4`. Any other version is an error (line 957).
3. It keeps the `apiServer` section and makes an empty one only when the document has none.
4. It sets the flags `encryption-provider-config` and `encryption-provider-config-automatic-reload` in `extraArgs`. For v1beta4 the flags are list entries with a name and a value. For v1beta3 they are keys of a map (lines 969 to 988). An entry with the same name is replaced and not doubled.
5. It removes the volume that earlier agent versions wrote. The entry must have the name `encryption-config` and the host path `/etc/kubernetes/encryption-config.yaml` (line 997).
6. It sets the volume `enc` for the directory `/etc/kubernetes/kube-api-encryption`, with the type `DirectoryOrCreate` and read-only (lines 1003 to 1009).
7. It returns an error and writes nothing when a field has an unknown shape, for example `extraArgs` as a map in a v1beta4 document.

The join path of the agent has no change. It already writes the config file into the directory that the volume `enc` mounts.

## 5. Choices that a reviewer can change

1. The agent still writes the ConfigMap. The other way is to delete the write from the agent and leave the controller as the only writer, because the controller merge at the end of the workflow gives the same result. I kept the write because the agent then gives the right ConfigMap by itself. If the agent wrote nothing and the controller step did not run, a new node would join with an API server that has no encryption, and no step would report it.
2. The volume name is `enc`, the name in `controller/internal/kubeadmconfig/configmap.go`, line 37. The two names must stay equal. With another name the controller merge would add a second volume for the same mount path, and the API server pod would be invalid.
3. The merge removes the old volume only when the name and the host path both match. A volume with the name `encryption-config` on another path stays.
4. The merge does not bring back the flags and volumes that an earlier agent dropped. The agent does not know them. Section 10 has the decision for clusters that have the wrong content now.
5. A document of an unknown API version or shape fails the RPC, and so it fails the enable workflow. The old code wrote such a document anyway. An empty ClusterConfiguration made the old code panic with "assignment to entry in nil map", and it is now an error.
6. The function uses `sigs.k8s.io/yaml`, and the rest of the file uses `gopkg.in/yaml.v2`. kubeadm and the controller write the document with `sigs.k8s.io/yaml`, so the output keeps their format.
7. The new entries go to the end of each list. A cluster created with encryption has them in sorted order. The order has no effect on the API server.
8. The check `IsMaster` has no change, so the agent writes only on the node that ran `kubeadm init`. When that node is gone, the controller merge is the only writer, as before.
9. The agent writes the ConfigMap on every call, also when nothing changes, and it does not try again after a write conflict. Both points are as before.
10. The join does not write a second copy of the config to the old path. Such a copy would let a node join a cluster with the wrong ConfigMap, but its API server would run without the lost flags.
11. The new log line uses `slog`. The old lines of the function keep `log.Printf`.

## 6. Tests and checks

The tests are table-driven with testify, the mocks of the agent and the fake Kubernetes client that the package already uses. Each case goes through `updateEncryptionEntryForKubeadmConfigMap`, so the same tests run against the old code.

| Test | Cases | What it shows |
|---|---|---|
| `TestUpdateEncryptionEntryForKubeadmConfigMap` | 9 | A cluster without encryption keeps every setting and gets the flags and the volume. A cluster created with encryption stays the same. The old volume is removed. A volume with the same name on another path stays. A flag or volume with another value is replaced. `certSANs` and `extraEnvs` stay. An empty and a missing `apiServer` section work. A v1beta3 document gets the flags as map keys |
| `TestUpdateEncryptionEntryForKubeadmConfigMapMatchesClusterCreatedWithEncryption` | 1 | The result for a cluster that gets encryption later has the same flags, volumes and other settings as the document of a cluster created with encryption |
| `TestUpdateEncryptionEntryForKubeadmConfigMapRejectsUnknownShapes` | 6 | A missing ConfigMap, an empty ClusterConfiguration, an unknown API version, `extraArgs` of the wrong form, `extraVolumes` of the wrong form and a document that is not YAML each give an error, and the agent does not write the ConfigMap |

I put the source file of `d625fcfa` into a scratch copy of the agent module and ran the new tests there. Of the 16 cases, 15 fail and 1 passes.

- All 9 cases of the first test fail. In each case the `apiServer` section has only the wrong volume.
- The second test fails.
- In the third test the case with the empty ClusterConfiguration ends in the panic of the old code. The four cases after it fail when I run them alone. The case with the missing ConfigMap passes, because the old code and the new code behave the same there.
- The output is in `/scratch/kata-cp/logs/phase2-encryption-join-fix/old-behavior-test.out`.

The checks ran on the committed tree `06ffc498` with plain `make`, because `flox` is not on the PATH.

| Check | Result |
|---|---|
| `make fmt` in `agent/` | Pass, no file changed |
| `make vet` | Pass |
| `make check-protos` | Pass, no file changed |
| `make lint` | Pass, 0 issues |
| `make test` | Pass, 12 packages |
| `make notices-check` | Pass, no file changed |
| `make coverage-check` from the root | Pass. I added no test file, so the check was not required |

`make check-protos` runs `buf generate` with the remote plugins of `buf.build`, as `agent/buf.gen.yaml` says. A remote plugin gets the description of the proto files, so the check sent the description of the unchanged proto file to that service. I did not watch the network. I ran the check because the task names it. Section 10 has the point.

On the lab branch `41e88c4d`, `go vet ./...` and `go test ./...` in `agent/` pass for the 12 packages.

## 7. Not verified

- No cluster ran with the fix. The lab must show that encryption can be turned on and that a control plane node joins after it.
- I did not run `kubeadm join`. The manifest proof uses the init phase, which calls the same manifest function.
- I did not start an API server from a manifest. I conclude from the manifest and the config file that the API server of a new node encrypts, because a cluster created with encryption has the same manifest lines and the same file.
- The v1beta3 path has a unit test only. kubeadm 1.36 stores v1beta4.
- I read the behavior of `kubeadm upgrade apply` on a wrong ConfigMap in the source and did not run it.
- I did not test two writers of the ConfigMap at the same time.
- I did not test a control plane join in the middle of the enable workflow. With the fix the ConfigMap has the flags after `InitializeKubernetesAPIEncryption` ran on the init node, and the controller sends the key only after the workflow ends (`kubeadm_join.go`, line 146). So I expect from the source that such a join fails and that a later attempt works. Before the fix such a join failed on the wrong volume. I did not check whether NVKE allows a join in that window.
- I built no arm64 binary.

## 8. Other defects that I saw

I changed none of them.

1. The controller merge cannot repair a ConfigMap that an old agent wrote. It adds its own entries and leaves the wrong volume and the lost flags (`configmap.go`, lines 219 to 272 and 421). A cluster keeps the wrong content when its init node runs an old agent at the time when encryption is turned on.
2. The two sample files `agent/samples/kubeadm-deploy/kubeadm-init.yaml` (lines 20 to 29) and `control-plane-join.yaml` (lines 7 to 9) use the file path `/etc/kubernetes/encryption-config.yaml` with the type `File`. NVKE uses the directory. The old agent function wrote the same file path and the same type.
3. `control-plane-join.yaml` (lines 13 to 17) and `cp-join-no-encryption.yaml` (lines 11 to 15) hold a value in the form of a bootstrap token and a CA hash. I did not check whether the values were ever valid. I do not repeat them here.
4. The controller sends `ObjectsToEncrypt` with only `secrets` in the init request (`controller/internal/temporal/activities/kubeadm_init.go`, line 141). The agent ignores the field at init and at join and writes its own list of seven kinds (`etcd_encryption_at_rest.go`, lines 732 to 734 and 827). The list is the list that the enable workflow sends, so the nodes agree.
5. After encryption is turned on later, the old nodes have a config file without the identity provider, and a node that joins later gets a file with secretbox first and identity second. Both files read and write encrypted objects. The files are not the same.
6. An empty ClusterConfiguration made the old function panic inside the RPC. The fix turns that case into an error.
7. The agent updates the ConfigMap with one read and one write and no second attempt after a conflict (`etcd_encryption_at_rest.go`, lines 890 and 934).

## 9. The lab binary

| Item | Value |
|---|---|
| Path | `/scratch/kata-cp/work/phase2-gaps/bin-encfix/nvke-agent`, mode 0755, 55423100 bytes |
| sha256 | `cafddb1d4d28c79f2a07e05539440fd04402842d7c2157be754be3826b1e8a33` |
| `--version` | `NVKE Agent Version: v0.24.0-beta.18-6-g41e88c4d` |
| Kind | ELF 64-bit, x86-64, statically linked, stripped |
| Source | Branch `lab/agent-fix-gate-encryption` at `41e88c4d`, which is `lab/agent-fix-and-gate` (`f0d83222`) plus the cherry-pick of `06ffc498`. The cherry-pick had no conflict |
| Place in the node image | `/usr/local/bin/nvke-agent`, mode 0755 |

The build command ran in `/scratch/kata-cp/src/nvke-agentlab2/agent`. It has the flags of `make build-amd64`, with cgo off.

```
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-X main.VERSION=v0.24.0-beta.18-6-g41e88c4d -s -w -buildid=" -o /scratch/kata-cp/work/phase2-gaps/bin-encfix/nvke-agent ./cmd/agent/main.go
```

- A second build gave the same sha256.
- The folder `/scratch/kata-cp/work/phase2-gaps/bin/` has no change. Its binary still has the sha256 `feadfb1e8f29eb6365b426d396d589cade46c5340c9c3c9fa5bb07db204a5cd3`.
- The worktree `/scratch/kata-cp/src/nvke-agentlab` has no change.
- The lab branch is not pushed.

The fix acts when encryption is turned on, on the node that ran `kubeadm init`. So the lab test needs the new binary in the image of the first control plane node before encryption is turned on. A cluster that turned encryption on with the old binary keeps the wrong ConfigMap, also after a change of the image.

A check for the lab after encryption is turned on is the ConfigMap. `kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'` must show the flags and volumes that the cluster had before, the two encryption flags, the volume `enc`, and no volume with the name `encryption-config`. With the renderer of `d625fcfa` and Kubernetes 1.36.4, a cluster has 16 flags and 3 volumes before.

## 10. Points that Davanum must decide or check

1. Some clusters have the wrong ConfigMap now, and they need a decision. Every cluster that turned encryption on after its creation, while the node that ran `kubeadm init` was a member, has lost the `apiServer` settings in the ConfigMap and has the wrong volume. No control plane node can join such a cluster, so a rollout, an upgrade, a replace and a scale up stop. The fix does not repair them, because the controller never calls the agent function again for a cluster that is marked as encrypted. The repair is an edit of the ConfigMap that removes the volume `encryption-config` and puts back the flags and volumes that the controller renders. Removing only the volume lets the node join, but its API server then runs without the audit, admission, authentication and TLS settings. The choice is between a manual repair for each cluster and a repair step in the controller. I wrote neither.
2. The place of the fix is a choice. I kept the write in the agent and corrected it. Section 5, point 1, has the other way.
3. `make check-protos` contacted `buf.build`. The task has the rule to send nothing to an outside service, and it also names that check. The earlier fix ran the same check. Please say if the check must stay off in later work.
4. Two sample files hold values in the form of a token (section 8, point 3). A check of the Git history can show whether the values were ever valid.
5. I did not push `fix/agent-encryption-join-config` to the dims fork, and I opened no issue and no pull request. Each of them needs your word.
6. The lab must test the fix with the new binary, as section 9 says.
7. I made the folder `/scratch/kata-cp/logs/phase2-encryption-join-fix/` for the proof files (156 KB). It holds no key and no token. The worktree `/scratch/kata-cp/src/nvke-encfix` has ignored build output in `agent/bin/`, `coverage/` and `.local/` from the checks.
