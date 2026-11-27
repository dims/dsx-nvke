# Phase 2: a fix in the NVKE node agent for the kubeadm upload step

Date: 2026-11-26, 20:32 to 20:59 local time. An agent wrote the fix and ran the checks. The main session read the change in `agent.go` and pushed the branch at 21:00. The fault came out of step 6 of phase 2 (`lab/phase2-replace-run/result.md`).

- Branch: `fix/agent-upload-certs-config` on `dims/dsx-nvke`, one commit on top of main (`d625fcfa`). https://github.com/dims/dsx-nvke/tree/fix/agent-upload-certs-config
- Commit: `f240606c`, "fix(agent): build the upload-certs config on every control plane node". Two files: `agent/internal/agent/agent.go` and `agent_test.go`.
- Worktree: `/scratch/kata-cp/src/nvke-agentfix`. Logs: `/scratch/kata-cp/logs/phase2-agentfix/`.
- No pull request. The commit has a sign-off, no GPG signature and no agent text.
- No change of the gRPC API, no new dependency.
- Tested in a cluster on the second machine, 2026-11-27 02:02 to 03:00 UTC (`lab/phase2-agentfix-run/result.md`). The replace of the first node and the rollout pass with this agent. All 10 `JoinNode` workflows completed at the first attempt. Section 5 has the points that are still open.

The main session chose the place of the fix (the NVKE agent, and not the node image) by the standing rules of Davanum, and told him. He can change it.

## 1. The fault

A lab test on 2026-11-26 showed it, with three control plane nodes whose node address is on a second interface:

1. The node that ran `kubeadm init` is deleted and replaced through the NVKE API.
2. For the join of the new node, NVKE asks a joined node for new join strings. The agent there runs `kubeadm init phase upload-certs --upload-certs`.
3. The step fails: "x509: certificate is valid for 10.112.0.1, 172.28.1.4, 172.29.255.220, not 10.244.2.58". The last address is the pod IP.
4. NVKE retries the join with no end. A rollout of the control plane stops at the same point.

The cause in the agent, at `d625fcfa`:

- `uploadControlPlaneCerts` (`agent/internal/agent/agent.go:1597-1602`) added `--config` only when `/tmp/kubeadm-init-config.yaml` exists.
- The agent writes that file only for `kubeadm init` with an init config (`agent.go:863-872`). A join never writes it.
- So only the init node has the file, and only until `/tmp` is cleared.

The cause in kubeadm (the agent read the Kubernetes source, read only):

- `initData.Client()` in `cmd/kubeadm/app/cmd/init.go` points the admin client of the `kubeadm init phase` commands at the local API endpoint. That change is in kubeadm 1.33.12, 1.34.8, 1.35.5, 1.36.1 and 1.37.0.
- Older kubeadm used the control plane endpoint, so older clusters did not show the fault. The lab image has kubeadm 1.36.4.
- With no config, kubeadm takes the address of the default route interface as the local API endpoint.
- On a host whose node address is on the default route interface the step picks a correct address. With the node address on a second interface it picks an address that is not in the API server certificate.

Each flow that makes a new control plane node is hit when the init node is gone or was started again: a refill after a delete, a scale up, remediation, a rollout.

## 2. The fix

The upload step now runs the same way on the init node, on a joined node, and on either after a restart:

1. The agent reads the annotation `kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint` from `/etc/kubernetes/manifests/kube-apiserver.yaml`. It gives the advertise address and the bind port of this node.
2. The agent reads the ClusterConfiguration from the `kubeadm-config` ConfigMap, with kubectl and `admin.conf`.
3. The agent writes `/var/lib/nvke/kubeadm-upload-certs-config.yaml` with mode 0600: an InitConfiguration with only `localAPIEndpoint`, then the ClusterConfiguration with no change.
4. The agent runs `kubeadm init phase upload-certs --upload-certs --config /var/lib/nvke/kubeadm-upload-certs-config.yaml`.

Why the annotation is the source of the address:

- `kubeadm init` and `kubeadm join` both write it, so every control plane node has it.
- It is on disk, so it survives a restart.
- kubeadm reads the same annotation when it builds the configuration of a node again.
- It needs no state in the agent, so nodes that joined before the fix work with no migration.
- The state file of the agent does not hold the address, and the join configuration is in `/tmp` and holds a bootstrap token.

Why the ClusterConfiguration is in the config:

- The upload step reads `certificatesDir` and `etcd.external` from its config. They name the files that it uploads.
- kubeadm validates `kubernetesVersion`. With none it looks the version up on the network.
- A check with real kubeadm 1.36.4: for a cluster with its own certificates folder and external etcd, a minimal InitConfiguration made the step upload empty entries with exit code 0.

New code at `f240606c`: `agent.go:1576-1583` (the RPC), `:1651` (`writeUploadCertsConfig`), `:1685` (`apiServerAdvertiseEndpoint`), `:1707` (`uploadCertsConfig`). The redaction of the certificate key has no change.

## 3. Points for the review of a pull request

The agent made these choices. Davanum can change each one.

1. The step no longer reads the init config at all, also on the init node. The reason: that file also breaks the step when it is old. Real kubeadm 1.36.4 refuses an init config with `kubernetesVersion: v1.34.2`. So today an init node that has not restarted fails this step after two minor upgrades.
2. A `certificateKey` in a custom init config is no longer reused. The controller does not set one.
3. The RPC now needs kubectl on the node. The lab image has it, and the kubeadm package of NVKE ships it.
4. A missing API server manifest or an unreadable ConfigMap now fails the RPC with `FailedPrecondition`. kubeadm does not run with a guessed address. This also applies while another operation has moved the manifest away (a graceful shutdown, a certificate renewal, an etcd defrag).
5. A mutex serializes the RPC, so one call cannot write the config again while kubeadm reads it for another.
6. The removal of a stale init config at `kubeadm init` stays, with a corrected comment.

## 4. Tests and checks

Tests, table-driven with testify and the mocks of the agent:

- `TestUpdateAndFetchKubeAdmJoinStrings`, 8 cases. Among them: an init node with an init config on disk that names another address (the step ignores it), a joined node that never had an init config, an init node after a restart, no manifest, a failed kubectl call, a failed config write.
- `TestUploadCertsConfig`: IPv4 with v1beta4, a v1beta3 cluster, IPv6 with another port, a missing or bad annotation, a bad manifest, an empty ConfigMap value.
- The agent put the old behavior back in a scratch copy: the tests fail for it.

Checks, all pass on the committed tree, in `agent/`: `make fmt`, `make vet`, `make check-protos`, `make lint` (0 issues), `make test` (12 packages), `make notices-check`. From the root: `make coverage-check`.

A check with real kubeadm 1.36.4 and no cluster (the program came out of the local kind node image with no container start):

- For the 10 init fixtures of the controller, kubeadm made the manifest and the stored ClusterConfiguration in dry-run mode, and the functions of the fix built the config.
- `kubeadm config validate` accepted each config.
- `kubeadm init phase upload-certs --upload-certs --dry-run` passed with each config, with the same output as with the full init config.

## 5. Not verified

The cluster test of 2026-11-27 (`lab/phase2-agentfix-run/result.md`) verified these points, which were open when the fix was written:

- The step against a live API server on a node with its node address on a second interface, with this build.
- The kubectl read of the ConfigMap on a real node, and the write to `/var/lib/nvke` by the agent. The file has 3022 bytes and mode 600.
- A full join after the init node is deleted, also when the controller has no kept join strings and asks a joined node.

Still not verified:

- The agent log line of the fix with a kubeadm other than 1.36.4. The upgrade test made a cluster with kubeadm 1.35.5 and this agent, and its joins passed (`lab/phase2-gate-run/result.md`). Nobody read the log line in that cluster.
- The v1beta3 path. It has a unit test only.
- Two calls at one time. The mutex has no test.
- arm64.

## 6. The agent program for the lab

- Built with the flags of `make build-amd64` and cgo off: `/scratch/kata-cp/work/phase2-agentfix/bin/nvke-agent`, static, linux/amd64, version `v0.24.0-beta.18-4-gf240606c`.
- sha256: `e465d46ad7a578b1634ca129dc2b0303c76bc6146fc346e937e18371affe8770`.
- Its place in the node image: `/usr/local/bin/nvke-agent`, mode 0755.
- In the lab, the agent log line "wrote the kubeadm config for upload-certs" with `localAPIEndpoint=<node address>:6443` shows that the fix ran.
