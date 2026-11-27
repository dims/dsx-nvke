# A health gate in the NVKE node agent (phase 2 gaps)

An agent wrote this change on 2026-11-27, from 10:17 to 10:48 EST. The design is `phase2-gaps-design.md`, section 1. The failure that it fixes is in `lab/phase2-gate-run/result.md`, section 4. Nothing is pushed. There is no pull request and no issue.

| Item | Value |
|---|---|
| Branch | `feat/agent-endpoint-health-gate`, one commit on `d625fcfa` |
| Commit | `32baa92bb363843f1edc7d8835f6a4d166e43fd0`, "feat(agent): add a control plane endpoint health gate" |
| Worktree | `/scratch/kata-cp/src/nvke-gate` |
| Size | 13 files, 1649 lines added, 17 lines removed |
| Sign-off | Yes. No GPG signature, no agent text, no `Co-Authored-By` |
| gRPC API and `.proto` | No change |
| New dependency | None. `make notices-check` passes |
| Lab branch | `lab/agent-fix-and-gate` at `f0d83222`, local only, worktree `/scratch/kata-cp/src/nvke-agentlab` |
| Lab binary | `/scratch/kata-cp/work/phase2-gaps/bin/nvke-agent`, sha256 `feadfb1e8f29eb6365b426d396d589cade46c5340c9c3c9fa5bb07db204a5cd3` |
| Logs | `/scratch/kata-cp/logs/phase2-gaps-agent-gate/` |

## 1. What changed

### The three flags

The names are the names of the design table. I renamed none.

| Flag | Default | Meaning |
|---|---|---|
| `--control-plane-endpoint-gate-file` | empty | Absolute path of the gate file. Empty means no gate |
| `--control-plane-endpoint-backend-interface` | empty | The interface on which the connections of the load balancer arrive |
| `--control-plane-endpoint-gate-settle` | `10s` | The time between the close of the gate and the close of the sockets |

With no gate file the agent runs the old code and nothing else. The gate code starts behind one check, `s.ControlPlaneEndpointGate.configured()`.

### The withdrawal

`withdrawKubeVipLocked` calls the new function `withdrawThroughControlPlaneEndpointGate` first, when a gate is configured. The function does these steps in order.

1. It reads the IPv4 address of the backend interface with `ip -o -4 addr show dev <interface> scope global`.
2. It writes the gate file. The content is the park directory of the caller.
3. It waits the settle time.
4. It closes the established sockets of remote clients on that address and port 6443. It calls the existing `closeRemoteVipPeers`, so the command is the existing `ss -K` command.
5. It runs the existing `waitForVipSocketQuietWindow` on that address, with the existing window of 30 s. A new socket fails the withdrawal.

Then the kube-vip steps run as before.

### The restore

`restoreKubeVipLocked` is now a short function. It calls `restoreKubeVip`, which is the old body with no change, and then `openControlPlaneEndpointGate`, which removes the gate file. It tries both and joins the errors. So each caller of `restoreKubeVipLocked` opens the gate.

- `StartKubeVipRestore` opens the gate through `runKubeVipRestore`.
- The etcd defrag gets the gate through the two calls that it had before, at `etcd_defrag.go:237` and `:429`. The file `etcd_defrag.go` has no change.
- The repair of stale state opens a stale gate in a new step of `ReconcileInterruptedStaticPodParks`.

### The flows that get the gate

| Flow | Withdrawal | Restore |
|---|---|---|
| The guard `cwe.kube-vip-drain-restore` of the controller, for certificate renewal, etcd encryption and OIDC | `StartK8sControlPlaneNodeGracefulShutdown` with no API server stop | `StartKubeVipRestore`, after success, failure and cancellation |
| The teardown of a control plane node, for a rollout, an upgrade and a delete | `StartK8sControlPlaneNodeGracefulShutdown` with the API server stop (`controller/internal/temporal/workflows/teardown_node_graceful_shutdown.go:49`) | None. The node goes away |
| The etcd defrag in the agent | `withdrawKubeVipLocked` | `restoreKubeVipLocked`, in the same call |
| The repair of stale state at the agent start | None | It opens a gate that a defrag closed |

The teardown is a flow that the task did not name. It has two effects in a cluster of the provider.

- A failed quiet window now fails the teardown of a control plane node, unless the request has `force_unreachable` (`controller/internal/temporal/workflows/teardown_node.go:252`). Before the change the withdrawal did nothing there and could not fail.
- The gate stays closed on the volume of the old node, because no caller restores a node that goes away. The lab storage wipes a released volume (`p2-provider/storage.sh`, step `reset`), so a new node starts with no gate file. A storage that gives a new node the old files would start that node with a closed gate.

### Who opens a closed gate

The gate file holds one line. The line is the park directory of the flow that closed the gate. The agent uses the same directories to decide who restores a parked manifest.

| Content of the gate file | Closed by | Opened by |
|---|---|---|
| `/etc/kubernetes/manifests-backup` | `StartK8sControlPlaneNodeGracefulShutdown` | `StartKubeVipRestore` |
| `/etc/kubernetes/manifests-backup/etcd-defrag` | `StartEtcdDefrag` | The agent, at the end of the defrag or at its next start |
| Other content, or no content | An operator, by hand | `StartKubeVipRestore` |

### Files and lines at `32baa92b`

| File | Lines | Content |
|---|---|---|
| `agent/internal/agent/control_plane_endpoint_gate.go` (new, 333 lines) | 24 | `DefaultControlPlaneEndpointGateSettle` |
| | 29 to 34 | Six new progress steps |
| | 46 | Type `ControlPlaneEndpointGate` with `File`, `BackendInterface`, `Settle` |
| | 82 | `withdrawThroughControlPlaneEndpointGate` |
| | 156 | `closeControlPlaneEndpointGate`, which writes the file and decides the owner |
| | 204 | `openControlPlaneEndpointGate` |
| | 234 | `handOffControlPlaneEndpointGateToCaller` |
| | 285, 307 | `resolveEndpointBackendAddress`, `parseInterfaceIPv4Addresses` |
| `agent/internal/agent/control_plane_graceful_shutdown.go` | 245 to 249 | The gate call in `withdrawKubeVipLocked` |
| | 404 to 415 | `restoreKubeVipLocked`, now kube-vip and then the gate |
| | 429 | `restoreKubeVip`, the old body |
| | 832 to 834 | The gate in `handOffParkedManifestsToCaller` |
| `agent/internal/agent/static_pod_park_reconcile.go` | 127 to 134 | The new step in `ReconcileInterruptedStaticPodParks` |
| | 187 to 193 | `openInterruptedControlPlaneEndpointGate` |
| `agent/internal/agent/agent.go` | 238 to 241 | Field `ControlPlaneEndpointGate`, the last field of `NodeAgentServer` |
| `agent/cmd/agent/main.go` | 110 | Field in `AgentConfig` |
| | 168 to 196 | `registerControlPlaneEndpointGateFlags` |
| | 202 to 223 | `validateEndpointGateConfig` |
| | 515, 638, 679, 686 | Wiring and the check at start |
| `agent/internal/agent/control_plane_endpoint_gate_test.go` (new, 960 lines) | 183, 379, 521, 703, 815, 894 | Six table tests |
| `agent/cmd/agent/main_test.go` | 424 | `TestControlPlaneEndpointGateFlags` |

### Docs

| Page | Lines | Change |
|---|---|---|
| `controller/docs/certificate-renewal.md` | 86, 92 to 102 | The sentence "Nodes without kube-vip skip the drain" is gone. A new paragraph says what the drain does for kube-vip, for a gate, for both and for neither |
| | 288 to 289 | The gate file is in the list of evidence for an incident |
| `docs/tenant-clusters/certificate-renewal.md` | 184 to 187 | The workflow also closes and opens the gate |
| `agent/README.md` | 50 to 52 | The three flags in the flag table |
| | 74 to 135 | New section "Control plane endpoint gate" with the steps, the needs of the deployment and the owner rules |
| | 153 | The gate in the list of capabilities |
| `agent/docs/DESIGN.md` | 37 to 40, 152, 411 to 423 | The gate in the purpose list, in the config list and in section 9.4 |
| `agent/docs/SECURITY.md` | 19 to 20, 142 to 144 | The gate in two lists of what the agent changes |
| `controller/internal/rollout/README.md` | 43 | The guard also closes and opens the gate |

The task named `docs/certificate-renewal.md`. The page with those lines is `controller/docs/certificate-renewal.md`.

## 2. Choices that a reviewer can change

### A node with kube-vip and a gate

Both run. On withdrawal the gate goes first and kube-vip second. On restore kube-vip goes first and the gate second. Each one runs when it is configured, and neither looks at the other.

- The reason is the gap that this change closes. An operator who sets the gate flags says that a load balancer reads the gate. The quiet window on the VIP cannot see a connection that arrives on the backend address, so a node that only left the VIP still gets those connections.
- The gate goes first because the close of the gate cuts no connection before the settle time ends. A gate that fails stops the withdrawal before the agent touches kube-vip.
- The cost is time. Such a node takes the settle time and a second quiet window longer, about 40 s.
- The other option is kube-vip alone, with the gate only when the agent finds no kube-vip. It is less code. The gate flags then do nothing on a node with kube-vip.

### The gate after an agent restart

The gate file is the only record. The agent keeps no gate state in memory or in `state.json`.

- A gate that a graceful shutdown closed stays closed. The same holds for a parked kube-vip manifest in `/etc/kubernetes/manifests-backup`. A caller opens it with `StartKubeVipRestore`.
- A gate that the etcd defrag closed is opened by the agent at its next start, before it serves RPCs. The same holds for a manifest in `/etc/kubernetes/manifests-backup/etcd-defrag`.
- A gate that a defrag handed to the caller stays closed. The defrag does that when etcd does not come back healthy, at the same place where it hands over the parked manifests.
- A gate file with other content stays closed.

### The gate after a node restart

The agent does nothing special. With the gate file on a disk that survives the restart, the rules of the agent restart apply. The lab path `/var/lib/nvke/control-plane-endpoint.gate` is on such a volume, so a new pod sees the old gate.

- A control plane pod that starts again in the middle of a guarded operation stays out of the Service until `StartKubeVipRestore` runs. The guard of the controller runs it after success, failure and cancellation. If no caller runs it, nobody opens the gate.
- The same holds for kube-vip today. A parked kube-vip manifest survives a restart of the node.
- The other option is a gate file on a tmpfs path. A restart of the node then opens the gate in each case. It needs no code change, only another path in the unit and in the probe program.

### The owner in the gate file

The content is the park directory, for example `/etc/kubernetes/manifests-backup`. The agent has no second name for the two flows, so the code needs no mapping.

- The other option is a word such as `caller` or `etcd-defrag`. An operator reads it more easily.
- The etcd defrag does not take over a gate that a caller closed. It skips its gate steps and does not open that gate at its end.
- A caller takes over a gate that a defrag left closed.
- `StartKubeVipRestore` opens the gate whoever closed it. It differs from kube-vip in one case. `StartKubeVipRestore` does not restore a kube-vip manifest that sits in the defrag directory.

### The backend address

The agent reads it with `ip` at each withdrawal, before it writes the gate file. So a wrong interface fails the withdrawal with the gate open.

- The agent does not handle IPv6. It asks `ip` for IPv4 only, and it does not close and does not check connections that arrive over IPv6. An interface with IPv6 only fails the withdrawal with "no global IPv4 address on eth0". The kube-vip code is also IPv4 only. The existing `ss` calls do not put an IPv6 address in brackets, so IPv6 needs a change in those functions.
- An interface with more than one IPv4 address fails the withdrawal with "multiple global IPv4 addresses on eth0" and the list. The kube-vip code does the same for two addresses on `lo`. The other option is that the agent closes and checks each address in turn, which takes one quiet window for each address.
- The agent takes addresses with scope global. It ignores link-local addresses.

### Names

- I kept `withdrawKubeVipLocked`, `restoreKubeVipLocked` and `kubeVipWithdrawal`. They now also cover the gate. The RPC `StartKubeVipRestore` has the same kind of name and cannot change. A reviewer can ask for `...ControlPlaneEndpoint...` names. The rename touches `etcd_defrag.go`, `static_pod_park_reconcile.go` and their tests.
- I renamed no progress step. The gate has six new steps, because `closing_vip_sockets` and `waiting_for_vip_socket_quiet_window` name a VIP. The new steps are `resolving_endpoint_backend_address`, `closing_endpoint_gate`, `waiting_for_endpoint_gate_settle`, `closing_endpoint_backend_sockets`, `waiting_for_endpoint_backend_socket_quiet_window` and `opening_endpoint_gate`. The controller reads no step name.
- I did not change `closeRemoteVipPeers`, `listRemoteVipPeers` and `waitForVipSocketQuietWindow`. Their log lines and one error text say "VIP" and "after kube-vip exit" also for the backend address. The gate code puts "control plane endpoint backend socket quiet window failed on <address>" in front of that error. A neutral text needs a change of the text on the kube-vip path.
- The etcd defrag reports a failed gate under its old text "withdraw this node from the control-plane VIP". I did not change `etcd_defrag.go`.

### Other choices

1. The gate file is written as `<gate file>.tmp` and then renamed. The probe only asks if the file exists. A write that stops in the middle would leave a closed gate with no owner, and only a caller would open it. So `FileWriter` gets the `.tmp` path, and the rename is an `os.Rename` call.
2. The gate file has mode 0644. The agent makes the folder with mode 0755 when it does not exist.
3. A wrong set of flags stops the agent at its start, as a wrong authentication setting does. The cases are a gate file with no interface, an interface with no gate file, a relative path and a negative settle time. A settle time of zero is allowed.
4. A withdrawal that fails after the gate closed leaves the gate closed. kube-vip does the same with its parked manifest. The restore that follows opens the gate.
5. The agent does not wait for the load balancer after it opens the gate. It also opens the gate when the API server is not ready, as it restores kube-vip in that case. The health check has to test `/readyz` itself.
6. The repair of stale state opens the gate after it restores the manifests. It does so also when no manifest is parked.
7. The comments in `node_agent.proto` still describe kube-vip only. The task forbids a change of that file.

## 3. Tests and checks

### New tests

All are table tests with testify. They use the fake node of the defrag tests as `CommandRunner` and `MockFileWriter` for the failed write.

| Test | Cases | Function under test |
|---|---|---|
| `TestGracefulShutdownWithdrawsThroughTheControlPlaneEndpointGate` | 12 | `runK8sControlPlaneNodeGracefulShutdown` |
| `TestKubeVipRestoreOpensTheControlPlaneEndpointGate` | 8 | `runKubeVipRestore` |
| `TestRunEtcdDefragUsesTheControlPlaneEndpointGate` | 6 | `runEtcdDefrag`, then `ReconcileInterruptedStaticPodParks` |
| `TestReconcileInterruptedStaticPodParksOpensAStaleControlPlaneEndpointGate` | 8 | `ReconcileInterruptedStaticPodParks` |
| `TestCloseControlPlaneEndpointGateOwnership` | 7 | `closeControlPlaneEndpointGate` |
| `TestResolveEndpointBackendAddress` | 7 | `resolveEndpointBackendAddress` |
| `TestControlPlaneEndpointGateFlags` | 9 | The flags and `validateEndpointGateConfig` |

The cases that the task names are these.

| Case of the task | Test case |
|---|---|
| Gate only | "gate only: the gate closes, the settle time passes, the backend sockets close and the quiet window passes" |
| kube-vip only | "kube-vip only: with no gate flag the withdrawal is the kube-vip withdrawal and nothing else" |
| Neither | "neither: with no gate flag and no kube-vip the withdrawal does nothing" |
| Both | "both: the node leaves the load balancer first and the VIP second" |
| A failed quiet window | "gate only: a load balancer that still sends connections fails the withdrawal and leaves the gate closed" |
| A failed gate write | "gate only: a failed gate write fails the withdrawal with the gate open and no socket closed" |
| Restore with no gate file | "gate only: restore with no gate file succeeds and opens nothing" |
| The defrag path | Six cases, for example "gate only: the gate is closed while etcd restarts and open when the node is back" |
| The stale state repair | Eight cases, for example "a gate closed by a graceful shutdown stays closed" |

The tests check the order and not only the end state. The fake node records the state of the gate at each `ss -K` call and at the stop of etcd. The withdrawal tests compare the full list of progress steps.

### Proof that the tests can fail

I broke the new code in 12 ways, one at a time, and ran the tests. Each breakage made at least one test fail. Then I put the files back and compared them with the copies. The breakages were these: no gate in the withdrawal, no gate in the restore, no gate in the repair, the owner ignored at open, the owner ignored at close, no settle wait, no quiet window, no hand-off, no socket close, the gate only when kube-vip is absent, the first of two addresses taken, the sockets closed before the gate.

### Proof for "no gate flag, no change"

- No existing test file in `agent/internal/agent` has a change. `git diff --numstat d625fcfa 32baa92b -- '*_test.go'` shows 0 removed lines.
- The existing tests of the withdrawal, the restore, the defrag and the repair pass with no change, 80 passing entries in the verbose output.
- Three new cases with no gate flag check that the agent does not read the backend interface and does not touch a file at the lab path.
- The error texts on the kube-vip path are the same. `errors.Join` of one error gives the text of that error.

### Checks

All ran on the committed tree `32baa92b` with a clean tree before and after. `flox` is not on PATH, so I ran plain `make`.

| Check | Where | Result |
|---|---|---|
| `make fmt` | `agent/` | Pass, no file changed |
| `make vet` | `agent/` | Pass |
| `make check-protos` | `agent/` | Pass, no file changed |
| `make lint` | `agent/` | Pass, 0 issues |
| `make test` | `agent/` | Pass, 12 packages |
| `make notices-check` | `agent/` | Pass, no file changed |
| `make coverage-check` | root | Pass |
| `make docs-check` | root | Pass. Not asked for, it is a merge gate job for doc changes |
| `python3 -B hack/name-check.py --mode fail` | root | Pass, clean |
| `make license-header-check` | root | Pass |
| `go test -race` on the touched tests | `agent/` | Pass |
| The new tests 20 times | `agent/` | Pass |
| `go vet`, `make lint`, `make test` on the lab tree `f0d83222` | `agent/` | Pass, 0 issues, 12 packages |

The first lint run found two points in my code, a repeated string and the spelling "cancelled". I fixed both before the commit. The `ip` call has a `//nolint:goconst` with the same reason as the existing `ip` call at `control_plane_graceful_shutdown.go:619`.

## 4. What is not verified

1. Nothing ran against a real kernel. The tests use a fake for `ip`, `ss` and `crictl`. I wanted to run the withdrawal in a private network namespace on this workstation. AppArmor refuses a user namespace here, and I did not go around it.
2. `ss -K` in the guest. It needs the kernel option `INET_DIAG_DESTROY`. Without it the close of the sockets fails, the withdrawal fails and the operation does not start.
3. The whole path with the probe program. The agent side is tested, the probe side is not mine. No test shows that the Service takes the pod out in the settle time.
4. The settle time of 10 s against the probe of the provider. The provider at `d2880014` sets a period of 2 s, 3 failures and a limit of 3 s for each probe. So a pod is out after about 6 s, or after about 9 s when each probe runs into its limit. The Service then needs its own time. 10 s leaves 1 to 4 s.
5. The quiet window as a proof. The existing check lists the established sockets once each second. It sees a client that connects again to this node and keeps its connection. It can miss a short call. So test 4 of the design, "the gate fails safe", can pass the withdrawal by chance when no client comes back to the node.
6. Two address cases on a real interface. They are a point-to-point address and an address with a flag such as `secondary`. Both have unit tests with text that I wrote from the `ip` format.
7. `make secrets-check`. `gitleaks` is not installed. I searched the commit by hand for words such as token, password and key. There is no match, and each address is from a documentation range.
8. arm64. I built and tested amd64 only.
9. The agent start with a wrong flag set on a real node. The check has unit tests. I did not start the agent on this workstation, because it listens on a port and changes the host.

## 5. The lab binary

| Item | Value |
|---|---|
| Source | Branch `lab/agent-fix-and-gate` at `f0d83222`, which is `f240606c` plus the gate commit |
| Worktree | `/scratch/kata-cp/src/nvke-agentlab`, clean |
| Path | `/scratch/kata-cp/work/phase2-gaps/bin/nvke-agent`, mode 0755, 55419004 bytes |
| sha256 | `feadfb1e8f29eb6365b426d396d589cade46c5340c9c3c9fa5bb07db204a5cd3` |
| `--version` | `NVKE Agent Version: v0.24.0-beta.18-5-gf0d83222` |
| Kind | ELF 64-bit, x86-64, statically linked, stripped |
| Place in the node image | `/usr/local/bin/nvke-agent`, mode 0755 |

The build command ran in `/scratch/kata-cp/src/nvke-agentlab/agent`.

```
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-X main.VERSION=v0.24.0-beta.18-5-gf0d83222 -s -w -buildid=" -o /scratch/kata-cp/work/phase2-gaps/bin/nvke-agent ./cmd/agent/main.go
```

- The flags are the flags of `make build-amd64`, with cgo off.
- A second build gave the same sha256.
- The binary holds the log text of the fix and the log text of the gate.
- `--help` shows the three new flags.

The cherry-pick had one conflict, in `agent/internal/agent/agent.go`. The fix and the gate each add a field at the end of `NodeAgentServer`. I kept both fields, the field of the fix first. The two branches conflict at the same place when both go to main.

## 6. Flag text and log lines for the node image

### Flag text

Add this text to `AGENT_ARGS` in `/etc/default/nvke-agent`.

```
--control-plane-endpoint-gate-file /var/lib/nvke/control-plane-endpoint.gate --control-plane-endpoint-backend-interface eth0 --control-plane-endpoint-gate-settle 10s
```

`TestControlPlaneEndpointGateFlags` parses this exact text. The agent stops at its start when the gate file flag is there and the interface flag is not.

### Log lines

The agent writes JSON lines to stdout, and each line also has a `time` field. The lines below are from a test run, with the lab path. In the lab the address is the address on `eth0`.

The gate closes, in a guarded operation.

```
{"level":"INFO","msg":"closed the control plane endpoint gate","gateFile":"/var/lib/nvke/control-plane-endpoint.gate","owner":"/etc/kubernetes/manifests-backup"}
{"level":"INFO","msg":"waiting for the load balancer to act on the closed control plane endpoint gate","settle":10000000000,"backendInterface":"eth0","backendAddress":"198.51.100.10"}
{"level":"INFO","msg":"closing stale remote VIP socket","vip":"198.51.100.10","port":6443,"peerIP":"203.0.113.7","peerPort":"41000"}
{"level":"INFO","msg":"no new remote VIP sockets observed","vip":"198.51.100.10","port":6443,"quietWindow":30000000000}
{"level":"INFO","msg":"withdrew this node from the control plane endpoint through the gate","gateFile":"/var/lib/nvke/control-plane-endpoint.gate","backendInterface":"eth0","backendAddress":"198.51.100.10"}
{"level":"INFO","msg":"kube-vip is not configured; skipping kube-vip withdrawal"}
```

The gate opens.

```
{"level":"INFO","msg":"kube-vip is not configured; skipping kube-vip restore"}
{"level":"INFO","msg":"opened the control plane endpoint gate","gateFile":"/var/lib/nvke/control-plane-endpoint.gate","owner":"/etc/kubernetes/manifests-backup"}
```

- The line "closed the control plane endpoint gate" shows that the gate closed. The line "opened the control plane endpoint gate" shows that it opened.
- With no socket to close, the third line is "no stale remote VIP sockets to close".
- In an etcd defrag the owner is `/etc/kubernetes/manifests-backup/etcd-defrag`.
- A failed quiet window gives an operation error that starts with "control plane endpoint backend socket quiet window failed on" and ends with the address pairs of the new sockets.
- The values of `settle` and `quietWindow` are nanoseconds.

### What the agent needs from the image and the provider

1. The probe fails while the gate file exists. It passes only when the file does not exist and `/readyz` answers 200. The contract says so.
2. No other host connects to the address on `eth0` and port 6443, apart from clients that come through the Service. The provider at `d2880014` is correct here. Its readiness probe is a program in the guest, and its startup probe uses port 15005.
3. Clients in the new cluster use the address on `net1`. A client that connects to the address on `eth0` fails the quiet window.
4. `eth0` has one global IPv4 address.
5. The guest kernel has `INET_DIAG_DESTROY`.
6. Each guarded operation takes longer for each node. The withdrawal needs the settle time and the quiet window, 40 s. The guard of the controller asks each 10 s. The lab saw 10 s before the change.

## 7. What failed or was skipped

- The first lint run failed on two points in my code. I fixed them before the commit.
- The cherry-pick for the lab branch had one conflict. Section 5 has the resolution.
- The check in a private network namespace did not run. AppArmor refused it.
- `make secrets-check` did not run. `gitleaks` is not installed.
- `flox` is not on PATH, so the checks ran with plain `make`.
- No push, no pull request, no issue. The two new branches have no upstream.
- I changed only the worktrees `nvke-gate` and `nvke-agentlab`. I read `nvke-podvm` and changed nothing there.
