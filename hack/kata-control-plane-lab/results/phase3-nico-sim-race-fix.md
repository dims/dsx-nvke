# Phase 3, the race of the simulated cloud-init with systemd in the NICo simulator, cause and fix

Date of the work is 2026-11-27. Times are EST, from `date` on the workstation. The work started at 18:19 and the report was written at 18:42.

The fix is one commit on a local branch. Nothing is pushed. No pull request and no issue exist.

| Item | Value |
|---|---|
| Fix commit | `a8cd8402ea5c32084d94ce6735d5b4f145601b4d` |
| Fix branch and worktree | `fix/nico-sim-wait-for-systemd` in `/scratch/kata-cp/src/nvke-simfix`, on top of `d625fcfa` |
| Lab commit | `54648c0e1bddb4315d76277ab7aa950fe8f03c05` (the cherry-pick) |
| Lab branch and worktree | `lab/controller-endpoint-capacity-simfix` in `/scratch/kata-cp/src/nvke-simlab`, on top of `5c08484c` |
| Lab binary | `/scratch/kata-cp/work/phase3/sim-fix/nico-sim` |
| sha256 of the lab binary | `d375230039965f5ec747f96bf8ff69ccb65b9a89f2ce068287c201a38150db43` |

## The fault

The container backend of the simulator starts a node as a Docker container that runs systemd. It then runs the `runcmd` commands of the cloud-init data inside that container. On main the simulator starts those commands with no wait for systemd. `docker start` returns before systemd in the container is up, so a command that calls `systemctl` can run too early.

In lab run a-1 the last command, `systemctl restart nke-agent.service`, ran 0.09 s before systemd made its control socket `/run/systemd/private`. The command failed with "Failed to connect to system scope bus via local transport". The runner script wrote `error` into the status file. Nothing runs the commands again, so the status stayed `error`, and the `NodePreflight` step of NVKE failed on `check_cloud_init_status` at each attempt.

I checked the lab evidence against the source. The times in `race-evidence.txt` are UTC, and they agree with the code:

- The container started at 22:35:28.687.
- The simulator wrote `runcmd.sh` at 22:35:29.261 and the status file changed to `error` at 22:35:29.322.
- systemd made `/run/systemd/private` at 22:35:29.414 and the D-Bus socket at 22:35:29.564.
- `runcmd.sh` has three commands. Only the last one calls `systemctl`.

The line numbers that the lab agent named are correct for main at `d625fcfa`.

## Answers to the five questions

### 1. What the simulator does between the container start and the first command

All line numbers in this section are for main at `d625fcfa`, in `controller/nico-sim/internal/container/`.

`startInstanceContainer` (`service.go`, lines 291 to 299) runs `docker start` at line 292 and calls `applyCloudConfig` at line 295 with nothing between them. `applyCloudConfig` (`docker.go`, lines 136 to 198) then does these steps in order, each one as a `docker exec` call:

- It writes `running` into the status file (line 139).
- For each `write_files` entry it runs `mkdir -p` (line 170), writes the content (line 173), runs `chmod` (line 177) and runs `chown` (line 182).
- It writes the runner script `runcmd.sh` (line 189).
- It starts the runner with `docker exec --detach` (line 194) and returns.

No wait and no readiness check exists on that path. I searched the three source files of the package for sleep, timer, retry, wait and poll, and found none. The only time that passes before the first command is the time of the `docker exec` calls for the files. The lab worker had 3 files, so the simulator made 14 calls, and they took 0.574 s.

Two other checks exist in the package, and neither one gates the commands. `Health` (`service.go`, lines 127 to 132) asks Docker for its version. `instanceStatusForContainer` (`convert.go`, lines 129 to 144) sets the status in the API answer from the running state of the container and from the TPM certificate.

### 2. Which commands need systemd, and what the status is after a failure

Commands that need systemd:

- NVKE adds `systemctl restart <agent unit>` as the last command of each node of a template provider (`controller/internal/clients/capi/bootstrap_userdata.go`, lines 150 to 151). The unit is `nke-agent.service` or `nvke-agent.service` (`controller/internal/nodecontract/nodecontract.go`, lines 46 and 56).
- The first command of the e2e tests for container nodes ends with `systemctl restart nvke-agent.service`, when `NKE_E2E_BUNDLE_SERVER_URL` is set (`controller/test/e2e/internal/nvke/request.go`, lines 192 to 198).
- Each other pool command that calls `systemctl`. The two other e2e commands, `mkdir` and `echo` (lines 199 to 202), need no systemd.

The runner script has `set -eu` and a trap that writes `error` when the script ends early (`docker.go`, lines 200 to 221, trap at line 211). So the first command that fails stops the script, and the status is `error`. The script writes `done` only after the last command (line 219).

The status is final for the life of the container. The evidence in the source:

- Only `applyCloudConfig` starts the runner, and only the create path calls it (`service.go`, lines 156, 283 and 295).
- A reboot request runs `docker restart` and does not run the commands again (`service.go`, lines 179 to 188).
- The status file is under `/var`, which is a volume of the container (`service.go`, line 269), so the file survives a restart.
- The `cloud-init` program of the node image only prints the content of the file (`controller/hack/capd-kindest-node/scripts/cloud-init-status-shim`, lines 33 to 53).

On the NVKE side the agent turns `status: error` into an error (`agent/internal/agent/preflight.go`, lines 126 and 172 to 180). The workflow retries `NodePreflight` with no limit of attempts (`controller/internal/temporal/workflows/provision_node.go`, lines 376 to 388).

### 3. Why CI can pass with the same commands

What the source shows:

- CI has the same race and no protection against it. The NICo lane builds the same simulator (`controller/hack/ci/backend-e2e.sh`, lines 850 to 853) and runs it in the runner container (lines 1168 to 1173, and `controller/hack/nico-provider/run-nico-sim.sh`, lines 47 to 69). No script and no e2e command adds a wait for systemd.
- CI is exposed at the first command, not only at the last one. CI sets `NKE_E2E_BUNDLE_SERVER_URL` (`backend-e2e.sh`, lines 385 to 396), so the first e2e command calls `systemctl restart` a few milliseconds after the runner starts.
- The only time between `docker start` and the runner is the time of the `docker exec` calls for the files. NVKE sends 3 files for a node, or 4 with the client CA bundle (`bootstrap_userdata.go`, lines 115 to 137, and `controller/internal/temporal/activities/activities.go`, lines 64 to 91). So the simulator makes 14 to 18 calls before the runner.
- Before pull request 2059 (commit `02a8422c`, 2026-11-02) the simulator ran each command with its own `docker exec` call and waited for it. A failed command failed the create call, the simulator removed the container, and CAPNICo tried the create again. So a lost race corrected itself with a new container. Since that commit the runner is detached and a lost race stays as `error`.

Deductions, which I did not measure:

- CI passes when the 14 to 18 `docker exec` calls take longer than the entry program of the node image plus the start of systemd. In the lab the calls ended 0.574 s after the container start, the failed command ran at 0.634 s, and the socket came at 0.727 s. On a CI runner with 16 CPUs that also runs a kind cluster and the management plane, each `docker exec` call is probably slower in relation to the start of systemd. I have no CI log that shows the two times.
- CI can lose the race at times and show it as a spec that times out. I found no record of that in the repository. A comment in the agent (`preflight.go`, lines 120 to 125) names a run that reported `status: error` 44 times in 90 minutes. The comment does not name the backend, so I cannot connect it to this race.

### 4. What a real machine does

On a real node cloud-init runs as systemd units. The `runcmd` commands run in the last stage, which systemd starts after `multi-user.target`. So systemd made its control socket long before the first command, and a `systemctl` call always reaches systemd.

Evidence:

- The cloud-init package of the workstation (version 26.2) has `After=multi-user.target` in `/usr/lib/systemd/system/cloud-final.service`. Its `/etc/cloud/cloud.cfg` has `scripts_user` in the list of the final stage (line 80), and that module runs the `runcmd` script.
- The repository says the same in `os-image/files/nvke-spire-configure.service`, lines 7 to 9.

The simulator with the fix gives a container node the part of that guarantee that the failed command needs. The control socket exists before the first command. The fix does not wait for `multi-user.target`, so a command still runs earlier in the boot than on a real node. The section on choices has the reason.

### 5. The VM backend

The VM backend does not have this fault. It gives the cloud-init data to the guest as a seed disk or through the metadata server (`controller/nico-sim/internal/vm/artifacts/artifacts.go`, lines 83 to 91, and `internal/cloudinit/metadataserver.go`, lines 54 to 65). The real cloud-init in the guest runs the commands as a systemd unit. The simulator runs no cloud-init command in a VM. Its SSH code serves only the diagnostics API (`internal/http/handler_diagnostics.go`, lines 115 and 136). The `mock` VM backend starts no machine.

## The fix

Commit `a8cd8402` changes five files under `controller/nico-sim/`. It adds no dependency. The change is inside the container backend and its README section. The subject is `fix(nico-sim): wait for systemd before simulated cloud-init commands`. The commit has a sign-off line with the configured identity, no GPG signature and no agent text.

| File | Lines | Change |
|---|---|---|
| `internal/container/docker.go` | 27 to 35 | The socket path, the check command, the limit of 60 s and the interval of 100 ms |
| `internal/container/docker.go` | 202 to 208 | `applyCloudConfig` calls `waitForSystemd` after the files and the runner script are written, and before `docker exec --detach` |
| `internal/container/docker.go` | 217 to 248 | `waitForSystemd` |
| `internal/container/service.go` | 115 to 118, 129 to 130 | Two fields of `Service` for the limit and the interval. `New` sets the defaults |
| `internal/container/docker_test.go` | 102 to 211 | The new test `TestUnit_ApplyCloudConfig_WaitsForSystemd` |
| `internal/container/service_test.go` | 74 to 76, 83 to 90 | The fake Docker of the old test answers the new check, and the test sets a logger and the two fields |
| `README.md` | 364 to 378 | The new step 3 of the cloud-init simulation and the reason for it |

How `waitForSystemd` works:

- It runs `docker exec <container> sh -c 'if [ -S /run/systemd/private ]; then echo ready; else echo waiting; fi'`.
- When the answer is `ready`, it writes one log line, "systemd is ready for cloud-init commands", with the container ID, the number of checks and the time of the wait. Then the runner starts.
- When the answer is not `ready`, it waits 100 ms and checks again.
- When 60 s pass, it returns the error `systemd in container <ID> did not open its control socket /run/systemd/private within 1m0s`.
- When the context of the caller ends, it returns `wait for systemd in container <ID>` with the context error.
- When the `docker exec` call itself fails, it returns `check systemd in container <ID>` with the Docker text at once.

When the wait runs out, the create call fails. The code that was there before does the rest, as for each other failed step of `applyCloudConfig`:

- The simulator writes `error` into the status file (`docker.go`, lines 152 to 161).
- It removes the container (`service.go`, lines 290 to 294), and the HTTP layer removes the instance row (`internal/http/backend_container.go`, lines 34 to 42).
- The API answers 500 with the error text and the simulator logs it (`internal/http/backend.go`, lines 136 to 148).
- CAPNICo sets the condition of the `NicoMachine` to the error text and tries the create again. I read that in CAPNICo v0.1.0 (`controllers/nicomachine_controller.go`, lines 294 to 322), which is the version in `controller/go.mod`.

I chose a failed create because the commands cannot work on a node that has no systemd, and a new container is the only way to a good node. The two other options were worse. To run the commands without systemd gives the old fault again. To keep the container with the status `error` leaves a node that nothing corrects.

## Choices that a reviewer can change

| Choice | What the commit does | Reason | Other option |
|---|---|---|---|
| The check | It tests that the socket `/run/systemd/private` exists | The absent socket is the cause in the lab evidence. `man systemd` on the workstation says that `systemctl` talks to systemd through that socket. The lab ran the same test in three worker starts and each node joined. The same manual page calls the socket an interface private to systemd. The commit only tests that the file exists and sends nothing through it | `systemctl is-system-running` with the states `initializing`, `starting`, `running` and `degraded`. It is the documented command and asks systemd for an answer. I did not use it because nobody ran it in a worker of the lab, and it exits with an error for each state except `running` |
| How far the boot must be | Only the socket | The wait is about 0.2 s in the lab times, so the create answer stays fast | A wait for `multi-user.target`, which is what a real node has, and what kind does for the same base image with a limit of 30 s (kind v0.33.0, `provision.go`, lines 444 to 447). The create answer then waits for the whole boot, about 8 s in the lab, and CAPNICo ends its HTTP call after 30 s |
| Where the wait runs | In the simulator, before it starts the runner | The error reaches the simulator log and the API answer. The task asked for tests with a fake for the Docker calls | A wait loop at the start of the runner script in the container. The create answer does not wait then, and the error is only in `output.log` |
| The place in `applyCloudConfig` | After the files, right before the runner | The files need no systemd. They land as early as before, so the units that read them at boot see no change | A wait before the files |
| The limit | 60 s, a constant | The socket comes in less than 1 s on a good node. The limit only ends the wait for a node whose systemd never starts. The fake Docker backend of CAPNICo v0.1.0 gives a node 60 s for containerd (`internal/fake/docker/backend.go`, lines 102 to 105). The create handler allows 10 minutes (`internal/http/handler_instances.go`, line 23) | 30 s as kind, or a setting in the environment |
| The interval | 100 ms | One check is one `docker exec` call, which took about 40 ms in the lab | 200 ms, as the lab command |
| A `docker exec` call that fails | The wait ends at once with the Docker text | The check command always exits 0, so a failure means that Docker or the container is broken. Each other step of the function fails the create in that case | Try again until the limit |
| Cloud-init data with no command | The simulator waits also then | One path for each create. The entry of the container always starts systemd | Skip the wait when `runcmd` is empty |
| The log line | One line at level info for each create | The lab can see that the wait ran and how long it took | Level debug, or no line |
| The two fields of `Service` | Not exported. `New` sets them. A test sets its own values | The tests need a short limit, and a package variable is not safe with parallel tests | Arguments of `waitForSystemd` |
| The README | The new step and the reason | The README lists the steps of the simulation, so the list must stay true | No README change |
| The fifth test case | "check fails in Docker" | It covers the choice to end the wait at once | Remove it with that choice |

## Tests and checks

The new test `TestUnit_ApplyCloudConfig_WaitsForSystemd` is a table test with testify. Its fake Docker is a shell script that records each call and finds the socket from a chosen check on. Each case calls `applyCloudConfig`.

| Case | What the test asserts |
|---|---|
| systemd ready at once | The calls are status `running`, one check, the runner |
| systemd ready after some checks | The calls are status `running`, three checks, the runner |
| systemd never ready | The error names the container, the socket and the limit. No runner. The last call writes status `error` |
| context ends during the wait | The error is `context.Canceled` with the wait text. No runner. The last call writes status `error` |
| check fails in Docker | The error has the check text. One check, no runner, status `error` |

I put the old behavior back in a scratch copy. I copied the package from the commit into the scratch folder and removed only the call of `waitForSystemd`. `applyCloudConfig` in that copy has the same text as on main (I compared lines 136 to 198 with `diff`). At 18:38 the new test failed in each of the five cases:

- Three cases reported "An error is expected but got nil".
- Two cases reported the calls `status running`, `runner` in place of the calls with the checks.
- Each other test of the package passed in the copy.

I ran the checks on the committed tree `a8cd8402` from 18:38:06 to 18:38:24. `flox` is not on PATH, so I used plain `make`. Go is 1.27.4, as `go.work` asks. golangci-lint is 2.14.0, as the pin asks.

| Check | Where | Result |
|---|---|---|
| `make fmt` | `controller/nico-sim` | Pass, no file changed |
| `make lint` | `controller/nico-sim` | Pass, 0 issues |
| `go build ./...` and `go vet ./...` | `controller/nico-sim` | Pass |
| `go vet -tags=integration ./test/integration/...` | `controller/nico-sim` | Pass (compile only) |
| `go test -count=1 -race` on 13 packages | `controller/nico-sim` | Pass, 13 of 13 |
| The new test and `TestUnit_StartInstanceContainer`, 40 times with `-race` | `controller/nico-sim` | Pass |
| `make file-license-check REPO_ROOT=<root>` | `controller/nico-sim` | Pass, no file changed |
| `make license` | `controller` | Exit 0. It changed a file that is not mine (see below) |
| `make license-header-check` | root | Pass |
| `make coverage-check` | root | Pass. I added no test file |
| `hack/name-check.py --mode fail` and `hack/removed-settings-check.py` | root | Clean |
| `go test -count=1 -race ./internal/container/` | the lab worktree | Pass |

What failed, and what I did not run:

- `make license` in `controller/nico-sim` fails as it is written, with exit 2. The Makefile sets `REPO_ROOT` to the module folder, and the header file is in `hack/` at the root. The fault is on main and is not from my change. With `REPO_ROOT` given on the command line the target passes. I did not change the Makefile.
- `make license` in `controller` adds a header to `controller/test/e2e/internal/oidc/testdata/auth-config.yaml`, which has none on main. I restored the file with `git restore`. It is not in the commit.
- I did not run `make test` as a target, because it runs each package. I ran `go test` with the race flag on 13 of the 16 packages that have tests.
- `internal/consolessh` is not run. Its tests listen on each interface of the machine.
- `test/integration/mock` is not run. Its tests start the whole simulator, which listens on each interface.
- `internal/lifecycle` is not run. Its tests open TCP connections to port 22 of `192.0.2.x` addresses. The rule on tests names containers, VMs and networks, so the skip of that package is my own caution.
- The tests with the tag `integration` (libvirt, QEMU) and the e2e lanes are not run. They need a VM or containers.
- None of the three packages that I skipped uses the code path that I changed. `test/integration/mock` turns the container backend off.

## What is not verified

- The fix did not run against a container. I started no container on the workstation. The check command ran only in the local `dash`, for a path with a socket and for a path with none.
- The lab did not run the new binary yet. A run must show the log line of the wait and the status `done` with the request of the preparation, which has no wait command.
- The time that the wait adds on a loaded machine is not measured.
- The statements on systemd come from `man systemd`, `man systemctl` and the lab file times. I did not read the systemd source. I state as known, and not as checked, that systemd keeps a job that arrives right after the socket exists until its order allows the start. The three lab workers with the wait in the request support it.
- The answer to question 3 has two deductions, marked there.
- I read CAPNICo v0.1.0 for the behavior after a failed create. The lab uses v0.3.0-rc.1, which I did not read.
- I built only the amd64 binary.
- No reviewer other than me read the change.

## The lab binary

- The worktree `/scratch/kata-cp/src/nvke-simlab` is on the new local branch `lab/controller-endpoint-capacity-simfix`, made from `lab/controller-endpoint-and-capacity` at `5c08484c`. I did not change the worktree `nvke-ctrllab`.
- The cherry-pick of `a8cd8402` is `54648c0e` and had no conflict. The lab branch has no change of its own under `controller/nico-sim`, so that folder is the same as in the fix commit.
- The build command at 18:39 was `GOOS=linux GOARCH=amd64 make -C controller/nico-sim BINARY=/scratch/kata-cp/work/phase3/sim-fix/nico-sim build-static`, as CI does it. The linker printed its usual warning on `dlopen` in a static program.
- The binary is static (no `INTERP` header) and is for x86-64. Its build data shows `vcs.revision=54648c0e1bddb4315d76277ab7aa950fe8f03c05` and `vcs.modified=false`. It holds the new error text. The old lab binary does not.
- `SHA256SUMS` is next to the binary and has one line. `sha256sum -c` passes.
- sha256 is `d375230039965f5ec747f96bf8ff69ccb65b9a89f2ce068287c201a38150db43`.
- I did not touch `/scratch/kata-cp/work/phase3/sim/`. Its two checksums still pass.

Notes for the lab run:

- The start guard of `run-sim.sh` checks a `SHA256SUMS` that also lists `default-seed.yaml`. The seed file did not change (sha256 `af182b37...`, the same as in the tree). So the lab folder needs the new binary and a new line for it in its own `SHA256SUMS`.
- `docker-two-nets` passes each call that is not `create` to the real Docker, so the check works in the step B form.
- With `NICO_SIM_LOG_FORMAT=text` the simulator log has one line for each create with `checks=` and `waited=`.
- The request of the preparation, without the lab wait command, is the right test.

## Points for Davanum

- Decide on the check. The commit tests the socket. The other option is `systemctl is-system-running`, or a wait for `multi-user.target`.
- Decide on the limit of 60 s and on a failed create when the limit passes.
- Decide if the lab runs the new binary now, and with which request.
- The two faults of the license targets on main are not part of the commit. Say if you want an issue or a separate change for them.
- Say if I must run the three test packages that I skipped. They need a listener on each interface or TCP connections out of the machine.
- One of my search commands printed lab log files that hold the cloud-init data of the lab workers. That data can hold a join token of the lab. The text is in the local session files of the workstation only. It is not in the commit, not in the binary folder and not in this report.
