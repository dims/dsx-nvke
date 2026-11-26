# Phase 1, step 4: the bootstrap helper

Date: 2026-11-26, 10:22 to 10:57 local time. A test agent wrote and tested the helper and returned this report as text. The main session wrote the file. Source: this folder, with the original in `/scratch/kata-cp/work/phase1-helper/`. Logs: `/scratch/kata-cp/logs/phase1-helper/`, with `progress.txt`.

Result: built, tested, pass. The test namespace is deleted. The image `nvke-lab-bootstrap-helper:dev` is in the kind node. "Deduction" marks what is not tested.

## Why it exists

NVKE joins the Kata pods through `cluster-api-provider-provisioned`, which gives a host no bootstrap data. NVKE still makes, for each node, the Secret `<node name>-bootstrap-data` with the SPIRE agent configuration, the join token, the trust bundle and the agent environment file. Nothing copies it to the host. `nico-sim` solves the same problem for its containers (`controller/nico-sim/internal/container/docker.go:136-218`). The helper does that job for a pod. A `PodMachine` provider of phase 2 replaces it.

## 1. What the helper does

1. It runs as one pod (Deployment, 1 replica, runc, not privileged). Each 5 s it lists the `ProvisionedMachine` objects of one namespace.
2. A machine counts as bound when it has `status.hostName` and `status.initialization.provisioned: true`.
3. It follows the owner reference to the Machine, reads `spec.bootstrap.dataSecretName`, and reads the key `value` of that Secret.
4. It finds the one pod with the label `nvke.lab/host=<status.hostName>` in the namespace of the host pods. The container must run.
5. It sends one shell script through `pods/exec` on stdin. The script holds the files as base64.
6. First run for a Machine: wait for systemd, status `running`, write a marker, write each file in the order of the Secret, run the commands in the form of nico-sim, then write `done` or `error` to `/var/lib/nico-containers/cloud-init/status`.
7. The marker is `/var/lib/nico-containers/cloud-init/nvke-lab-bootstrap-helper.machine`. It holds the Machine UID.
8. Later runs for the same Machine (a new container, a new pod, a changed Secret, a new helper pod): write only the files that are absent or differ. Never run the commands again.
9. A failing command gives the status `error` and one ERROR log line with the number of the command. No retry.
10. The log has names, counts and results. It has no file content.

It is Go with client-go, about 950 lines, a static binary in a distroless image of 45.6 MB.

## 2. Facts from the NVKE source

Paths are relative to NVKE at `bcc4376f`.

Objects:

- `ProvisionedMachine`: group `infrastructure.cluster.x-k8s.io`, version `v1alpha1`. The provider writes `spec.providerID` first and `status.hostName` with `status.initialization.provisioned` second (`cluster-api-provider-provisioned/controllers/machine_controller.go:317-336, 499-501`).
- The Machine name is the NVKE node name and the name of the `ProvisionedMachine` (`controller/internal/clients/shared/machine.go:191`). The node name has a random part.
- The Secret is `<node name>-bootstrap-data`, key `value`, in the same namespace (`shared/machine.go:152,160`).
- NVKE puts the Cluster API objects of all clusters in one management namespace, `nvke-system` by default (`controller/internal/config/config.go:617-622`).
- Order in NVKE: the infra machine, the join token, the Secret, the Machine (`controller/internal/clients/capi/machine.go:75-115`).

The cloud-config with `joinToken` and SPIFFE on (`controller/internal/clients/capi/bootstrap_userdata.go:101-163`):

| # | Path | Owner | Mode |
|---|---|---|---|
| 1 | `/etc/spire-agent/initial-trust-bundle.pem` | root:root | 0644 |
| 2 | `/etc/spire-agent/agent.conf`, with `join_token` | root:root | 0644 |
| 3 | `/etc/default/nke-agent`, content `AGENT_ARGS="--secure-server-port 15005"` | root:root | 0644 |

The one command is `systemctl restart nke-agent.service`.

Names:

- NVKE renders the old names (`nke-agent`), because a new node has no agent version yet (`controller/internal/nodecontract/nodecontract.go:43-51,70-75`).
- The node image handles both names. The unit has the alias `nke-agent.service`, and `/etc/default/nke-agent` is a link to `/etc/default/nvke-agent`.
- The helper writes through the link, as cloud-init and nico-sim do. Tested.

What the environment file of NVKE changes in the lab image (tested):

- The file of the image loses its lab arguments: `--disable-mlx5-rescan`, the bundle server arguments and `NKE_LOCAL_DEV=true`. The agent then runs with `--secure-server-port 15005` only.
- With no `NKE_LOCAL_DEV` the agent does not add `--ignore-preflight-errors=SystemVerification`. So a host pod needs the kernel config file of gate 1 (deduction).
- A lab setting for the agent must be in a systemd drop-in with `Environment=`, not in `/etc/default/nvke-agent`. The CNI wrapper of step 1 already uses a drop-in.

Timing:

- The SPIRE agent unit of the image starts again each 5 s while it has no configuration. A write during that loop is safe: each file appears with one rename, and the bundle comes before `agent.conf`. The helper wrote the three files in 31 ms, and the next start of the unit read them.
- The helper does not restart the SPIRE agent. The unit starts by itself within 5 s.
- The join token lives 1 hour. The helper acted 0.5 s and 2.5 s after the bind in two tests. The worst case is about 5 s when the pod runs.
- The SPIRE agent uses the token only when it has no identity in `/var/lib/spire-agent`. So a second write of the same `agent.conf` does not use the token again (deduction: the test had no SPIRE server).

Repeat safety:

- The marker is on the `/var` volume in the gate 4 pod layout, and so is `/var/lib/spire-agent`.
- `/etc/spire-agent` and `/etc/default/nvke-agent` have no volume. Each new container has the image content there. So after a new container or a new pod the helper writes the files again and runs no command.
- In 3 of 3 runs the files were back 2 to 4 s after the container start, before systemd started the units. This is a race against a 5 s poll and is not sure.

## 3. Tests

Target: the NVKE node image with the class `kata-clh-runtime-rs-fix-direct`, 2 CPUs and 4Gi, in the namespace `phase1-helper-test`.

| Test | Input | Result |
|---|---|---|
| Build | 11 Go tests in the build container | Pass |
| 01a | 6 files (modes 0600 and 0640, another owner, base64, the link), 3 commands | Pass. 6 of 6 files correct, each command ran one time, status `done` |
| 01b | Command 2 of 4 exits with 3 | Pass. Status `error`, commands 3 and 4 did not run, and the log names command 2 |
| 02 | A second pass, then a new helper pod | Pass. 0 files written, nothing changed |
| 03 | A new container in the pods | Pass. The files are written again, no command runs, the status stays |
| 04 | A Secret with another token | Pass. 1 file written 1 s later, no command |
| 05 | A `ProvisionedMachine` and a Machine made by hand, with the 3 files and 1 command of NVKE | Pass. The helper waited while the machine had no host. Files 0.54 s after the status change |
| 08, 09 | The final image, tests 01, 02 and 05 again | Pass |
| 10 | Rights of the service account | Pass |

- One fault found and corrected before test 01: the script ran with umask 077, so new folders had mode 0700.
- One exec into a Kata pod took 0.15 to 0.23 s.
- The test Secrets come from a generator with the template of NVKE. All values are fake.

## 4. How to use it in the real run

`HOSTS_NS=<namespace of the host pods> deploy/render.sh | kubectl apply -f -`

| Variable | Default | Meaning |
|---|---|---|
| `HOSTS_NS` | none, necessary | Namespace of the three host pods |
| `CAPI_NS` | `nvke-system` | Namespace of the Cluster API objects and Secrets |
| `HELPER_NS` | `nvke-lab-bootstrap-helper` | Namespace of the helper |
| `IMAGE` | `docker.io/library/nvke-lab-bootstrap-helper:dev` | In the kind node, pull policy Never |
| `HOST_LABEL` | `nvke.lab/host` | Label key on the host pods |
| `CONTAINER` | `node` | Container name of the gate 4 pod |

Rights:

- In `CAPI_NS`: `list` provisionedmachines, `get` machines, `get` secrets.
- In `HOSTS_NS`: `list` pods, `create` pods/exec.
- The helper pod has no host network, no hostPath, a read-only root filesystem, no capability and no port.

What the host pods need:

1. The label `nvke.lab/host: <inventory hostname>` on each pod. The hostname has at most 63 characters.
2. The container name `node`.
3. `/var` on the volume, mounted before systemd starts. The gate 4 wrapper does this.
4. A wrapper that writes no file in `/etc/spire-agent` and no cloud-init status. The helper does both.
5. Lab settings for the agent in a systemd drop-in.

The success line in the log: `bootstrap data applied, cloud-init status is done ... files=3 commands=1 run=first`.

## 5. Limits and not tested

- Not tested: a `ProvisionedMachine` that the real provider binds, a real join token, the identity of the agent, and the NVKE call over mTLS. Step 5 is the first real run.
- Not tested: `/var` on a block volume, a new pod on the same volumes, a broken exec stream, two pods with one label.
- The node needs the helper at each container start, because `/etc/spire-agent` is not on a volume. With the helper down, a node that starts again has no SPIRE configuration. A bind mount of `/etc/spire-agent` from the `/var` volume in the wrapper removes this. Recommendation of the agent.
- A first run that stops in the middle is final. The next pass writes `error` and does not run the commands again.
- A lost `/var` with the same Machine: the helper applies the data again, and the token is used already. The SPIRE agent then fails. The node needs a new token.
- A changed Secret gives a new `agent.conf`, and nobody restarts the SPIRE agent.
- The Role lets the helper read any Secret of `nvke-system` by name. RBAC cannot limit it to a name form.
- The helper polls each 5 s. It has no watch.
