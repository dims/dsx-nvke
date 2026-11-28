# The node image branch for pod machines

State on 2026-11-27 at 23:01 EST. The branch `feat/podvm-node-image` exists in the worktree `/scratch/kata-cp/src/nvke-podimage`. It stacks on `lab/provider-podvm-history` (`d2880014`). It is not pushed, and it has no pull request.

## Result

The branch has three commits. Each has the configured author, a sign-off line and no agent text.

| Commit | Title | Files | Lines |
|---|---|---|---|
| `70efc2b1f84eb26ecea9952ca2d755bc5406b6ef` | `feat(podvm): add the bootstrap program of the node image` | 4 | 437 added |
| `acd43f01d0b52c3ecd518016b6f5b81f54171e3d` | `feat(podvm): add the node image for pod machines` | 9 | 276 added |
| `cbad35cf1f40d99b4b5ab5e8f6ea2e39252f8b46` | `docs(podvm): describe the node image and its guest kernel options` | 4 | 180 added, 2 removed |

The first instruction asked for one commit. The coordinator then sent the rule of Davanum that the changes must be small and easy to review, with a split when the image needs more than about 400 lines. The image needs 887 lines in its folder. So I made three commits with one concern each. I ran the checks at each of the three commits, and they pass at each one. A squash of the three gives one commit again.

## What is in the folder

`cluster-api-provider-podvm/node-image/` holds one image definition, not steps. The base image comes in through the build argument `BASE_IMAGE`.

| File | Lines | Reason |
|---|---|---|
| `Dockerfile` | 63 | The image definition. It copies the files, makes two links, checks the health gate flags, and installs the CNI image package |
| `build-image.sh` | 28 | It compiles the bootstrap program on the host and runs one `docker build` with no network |
| `podvm-entrypoint` | 123 | The entry point of the pod contract |
| `bootstrap/main.go` | 248 | The program `podvm-bootstrap`, which applies the bootstrap data of NVKE |
| `bootstrap/main_test.go` | 149 | Its tests, with 5 test functions and 10 table cases |
| `units/podvm-bootstrap.service` | 19 | The unit that writes the files before the two agents |
| `units/podvm-bootstrap-final.service` | 21 | The unit that runs the commands when the system is up |
| `podvm-endpoint-ready` | 10 | The program of the readiness probe |
| `units/zz-podvm-endpoint-gate.conf` | 14 | The agent drop-in with the three health gate flags |
| `ovs-datapath-check` | 15 | The check of the Open vSwitch datapath |
| `units/zz-podvm-builtin-datapath.conf` | 10 | The drop-in that puts the check into the Open vSwitch unit |
| `build-ctr` | 12 | A `ctr` wrapper for the build, so that the CNI image import does not unpack |
| `README.md` | 146 | The text for a reader of the repository |
| `kernel/ovs.conf` | 18 | 8 guest kernel options for Open vSwitch with Geneve |
| `kernel/sockdiag.conf` | 11 | 3 guest kernel options for the socket close of the agent |

The commits change two files outside the folder:

- `cluster-api-provider-podvm/README.md` has 5 lines added and 2 removed. One row in the layout table names the folder. Two sentences that said the image is not in the module now point at it.
- `hack/base-image-check.sh` has 1 line added. It lists the new Dockerfile as exempt. Without the line `make base-image-check` fails, because the base image is a local image with no digest.

The commits change no Makefile, no `go.mod` and no workflow.

### How the image is built

I chose a script, `build-image.sh`, and not a make target. The reasons are these:

- The base image has the same form. `controller/hack/capd-kindest-node/build-image.sh` builds the node agent on the host and gives it to the Docker build.
- A make target needs a change of the Makefile of the module, and the other agent can change that file. A target can call the script later with one line.

The Dockerfile has no Go stage. A Go stage needs the network for the modules, as the Dockerfile of the provider does. With the program compiled on the host, the image build needs no network.

### Where the bootstrap program lives

The program is a package of the provider module, at `node-image/bootstrap`. So `make test` and `make lint` of the module cover it, and no check list of the repository needs a new module. It reads YAML through `k8s.io/apimachinery/pkg/util/yaml`, which the module requires already. `go mod tidy -diff` shows no change.

## Differences from the base image

The table has each difference between the last lab image (tag p10) and the base image `nvke-node:bcc4376f-amd64`.

| Difference | Kind | In the branch |
|---|---|---|
| The entry point `podvm-entrypoint`, set as `ENTRYPOINT` | Needed for the contract (container, volume devices, state, hostname check) | Kept, in a shorter form |
| The program `podvm-bootstrap` and its two units | Needed for the contract (bootstrap data) | Kept, in a shorter form |
| `/etc/default/nvke-agent` is a link to `/var/lib/podvm/agent/nvke-agent` | Needed for the contract (state that stays through a new pod) | Kept |
| The probe program `/usr/local/bin/podvm-endpoint-ready` | Needed for the contract (readiness probe) | Kept, as a plain file |
| The agent drop-in with three flags, and the gate folder | Needed for the contract (the gate file that the probe reads) | Kept, as a plain file. The drop-in makes the folder at the agent start |
| The Open vSwitch drop-in and `ovs-datapath-check` | A correction of the base image. Its start step fails with a datapath that is built into the kernel (design note, sections 6 and 8, no finding number) | Kept. The README says that the right place is the base image |
| `/var/lib/dbus/machine-id` is a link to `/etc/machine-id` | A correction of the base image, finding 5 | Kept. The README says the same |
| The CNI image package installed at build time, with the package file removed (tag p3) | A correction of the base image, finding 6 | Kept. The README says the same. The step runs only when the base image has the package file |
| The kernel config file `/boot/config-6.18.62` (tags p2 and p6) | A lab part | Left out |
| The images `pause:3.10.2` and `k8s-dns-node-cache:1.26.8` in the containerd store | A lab part. A lab node cannot pull | Left out |
| The lab builds of the node agent (tags p4, p6 and p9) | A lab part | Left out |
| The marker file `/usr/share/podvm/image-form` and the labels `podvm.image-form` and `podvm.agent-sha256` (tags p5, p7 and p10) | A lab part | Left out |
| The labels `podvm.contract` and `podvm.kernel-release` | A lab part. The first names the lab design note, the second belongs to the kernel config file | Left out |
| The settings file `endpoint-gate.env` in the image, and the build step `gate-setup.sh` | Lab build parts | Replaced by the two plain files and one build step in the Dockerfile |
| The empty folder `/var/lib/podvm/bootstrap` | State folder | Not in the image. The program makes it |
| `/run/containerd` of the base image is gone | A side effect of the containerd that the build starts | The same in the branch |

## What I left out and why

- The kernel config file. The task names it a lab part. The kubeadm wrapper of the base image adds `--ignore-preflight-errors=SystemVerification` for `init`, `join` and `upgrade`, and that check is the reader of the file. The entry point has no warning about the file any more.
- The two baked images, the lab agent builds, the markers and the labels. They are lab parts by the task text.
- The Konnectivity image (tag p11), the image with another Kubernetes version for the upgrade test, the image with a probe that does not read the gate (tag p8), and the worker image of phase 3. They are test images.
- The test data generator `genfixture`. It copies types and a template of the NVKE controller, and only the lab tests in a pod used its output.
- The second Docker stage with Go. See "How the image is built".
- The Open vSwitch system ID on the volume (finding 12) and a journal that stays (finding 13). The lab image did not have them. The README lists both under "What is not covered".

## What changed in the kept parts

The kept files are shorter than the lab files, by the rule for small changes. These points differ in behavior:

- The bootstrap program has one flag, `-phase`. The paths are fixed values. The lab program had seven flags.
- The program does not wait for the data file. The lab wait of 30 s was never used, because the runtime fills the Secret volume before PID 1 starts.
- The program writes a file in place and not through a rename. A path can be a link into the `/var` volume, and an open through the link keeps it. The lab code resolved the link by hand, in a function of its own. The machine marker is now written after the files, so a first start that stops half way runs again.
- The program writes the output of a command to the journal. The lab program wrote it to a log file on the volume.
- The commands marker has two values, `started` and `done`. A run that failed keeps `started`. The next start then sets the status `error` and fails the unit. In the lab that next start set the status `error` and ended with success.
- The program rejects a bare number for `permissions`, a mode above `0777` and an empty path. NVKE writes a quoted mode and a path for each file.
- The entry point needs `PODVM_MACHINE_NAME`. The lab script used the hostname with a warning when the variable was absent. The check is now the first step, before a volume is touched.
- The entry point mounts a tmpfs on `/run` and `/tmp` in each case. The lab script emptied the folder when it was a mount point. The pod of the provider has no volume there.
- The entry point writes only `PODVM_MACHINE_NAME` to `/run/podvm/env`. The units need no other variable.
- The state folders have the names `/var/lib/podvm/state/etc/kubernetes`, `/var/lib/podvm/state/etc/spire-agent` and `/var/lib/podvm/state/kind`.
- The units are enabled with `SYSTEMD_OFFLINE=1 systemctl enable`, as the base image does it. The build log shows the two links.

## Checks and results

All times are from `date` on the workstation, in EST.

| Check | Result |
|---|---|
| Shell syntax, `bash -n` for 2 files and `sh -n` for 3 files | Pass |
| `shellcheck` 0.11.0 on the 5 shell files, at the default severity | No finding |
| `systemd-analyze verify` on the two units | No syntax finding. It reports only that the program is absent on the workstation |
| `go vet`, `gofmt -l` | Clean |
| `make test` in the module | Pass, 3 packages. Also with `-race` for the new package |
| `make lint` in the module, golangci-lint 2.14.0 | 0 issues |
| `GOWORK=off go mod tidy -diff` in the module | No change |
| Five breakages of the program, one at a time | Each one makes a test fail |
| `make license-header-check` | Pass |
| `make docs-check` | Pass |
| `make coverage-check` | Pass, 14 modules collect coverage |
| `make name-check` | Clean |
| `make base-image-check` | Pass with the exempt line. It failed before the line |
| `make lint-shell` | Pass, 233 scripts |
| `make go-version-check`, `make grype-ignore-check`, `make deploy-lists-check`, `make tool-version-check` | Pass |
| At the first and at the second commit, `make test`, `make lint`, `make docs-check`, `make coverage-check`, `make name-check`, `make base-image-check` and `make lint-shell` | Pass |
| Search for the bash network socket device path form in each changed file and in this report | Nothing found |
| Search for lab words, lab paths and addresses in the new files | Nothing found. The word "phase" is only the name of the flag of the program |

### The build check

The base image `nvke-node:bcc4376f-amd64` is in the local Docker store, so I pulled nothing. The folder `controller/hack/capd-kindest-node` has no change between `bcc4376f` and the head of the branch.

I ran two builds, one after the other, with `build-image.sh`, `docker build --network none` and `GOPROXY=off` for the Go compile. The task text says one build. The first build was done before the readiness program and the gate step were in the Dockerfile, so the second build is the check of the committed files.

| Build | Time | Result |
|---|---|---|
| The image with no readiness program and no gate step | 22:46:25 to 22:46:43 | Pass |
| The committed Dockerfile | 22:51:15 to 22:51:31 | Pass |

Facts of the second build:

- The image has the entry point `/usr/local/bin/podvm-entrypoint`, no command, and the stop signal of the base image.
- The build log shows the two unit links and the line "import complete" of the CNI image package. The import took 2 s.
- The agent of this base image has no health gate flag. The build printed its notice and removed the drop-in.
- The image is 4.55 GB against 3.22 GB for the base image. The CNI step adds 666 MB, as in the lab.

I started no container. I read the image with `docker save` and `tar`, and looked at the 8 new layers. They have the two links, the moved agent settings, the modes `0755` and `0644`, the installed package, the containerd store with the imported images, and removal marks for the package file, for `build-ctr` and for the drop-in. In the first build I counted the store. It has 14 blobs with 333 MB, and no unpacked image.

I removed both check images. The build cache of Docker keeps the layers of the two builds, about 1.3 GB. I did not prune it, because a prune also removes the cache of other builds.

### The gate step outside Docker

The base image has an agent with no gate flag, so the build check cannot show the other case. I took the gate step out of the Dockerfile text and ran it on a folder with four fake agents that print a usage text:

| Case | Result |
|---|---|
| The agent knows the three flags | The drop-in stays |
| The agent knows no gate flag | Notice, the drop-in is removed |
| One flag has another name | Notice, the drop-in is removed |
| The agent unit has another `ExecStart` line | The step fails with an error |

## What is not verified

- The image has not run. I started no container, and the lab cluster was not in my task. So the shorter entry point, the shorter bootstrap program in a real pod, the two units under systemd and the image with no kernel config file are not tested in a pod. The unit tests cover the program. Nothing covers the entry point but syntax and shellcheck.
- The gate drop-in with a real agent that has the flags. The usage text of the fake agents has the form of the Go flag package. I did not run the agent of the gate branch.
- A base image with no CNI image package. The step then does nothing, by the text of the Dockerfile.
- A build on arm64, with the legacy builder, or with another container tool.
- `make internal-config-check`. It needs ripgrep, and `make` finds no `rg` program on this workstation. A search of the new files for a UUID and for 16 digits found nothing.
- `make work-check` and `make gate` as a whole. They use the network.
- The move of the commits onto the rewritten provider branch. The three README hunks can conflict there. The module checks must run again after the move, because the other branch can bring a lint setting.
- The two Kata references in the README (issue 14062 and pull request 13627). They come from the notes of 2026-11-25. I did not read them again.

## Points for Davanum

1. Three commits or one. A squash is one command.
2. The CNI image package at build time. I kept it as the correction for finding 6. It costs one build step that starts containerd, the file `build-ctr`, and 666 MB in the image. Without it a node start has the 34 to 57 s of the base image unit again.
3. The rule for a base image whose agent has no gate flag. The build now removes the drop-in and prints a notice. The other choice is a build that fails. The agent of the provider branch has no gate flag, because the gate is on `feat/agent-endpoint-health-gate`. So an image of this branch alone sets no flag, and the probe checks `/readyz` only.
4. The kernel config file. It is out, as the task says. The proof that kubeadm does not need it is the source of the wrapper, not a run.
5. The exempt line in `hack/base-image-check.sh`. It is the only change outside the module. The script says that a Dockerfile leaves the list when the image is published.
6. The flag `--disable-mlx5-rescan`. The bootstrap data of NVKE replaces the agent arguments of the base image, and the lab pod image did not force the flag. In a Kata guest the rescan sees only guest devices. The worker image of phase 3 forced it. I kept it out and listed it in the README.
7. A run of this image in the lab cluster before a pull request. The kept parts are shorter than the tested files, so one cluster create and one pod replace are a good proof.
