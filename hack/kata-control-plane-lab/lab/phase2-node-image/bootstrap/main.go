// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// podvm-bootstrap applies the bootstrap data of NVKE inside a node image for pods.
//
// The data is the cloud-config text of the Secret "<node>-bootstrap-data" (write_files and
// runcmd). The provider mounts it at /etc/podvm/bootstrap/value. The parse code is
// cloudconfig.go of the lab bootstrap helper (phase 1, step 4), with no change.
//
// It runs in two phases, as two systemd units, in the way of cloud-init:
//
//	-phase files     before the SPIRE agent unit. First run for a Machine: status "running",
//	                 the marker, then each file. Later run for the same Machine: only a file
//	                 that is absent.
//	-phase commands  after multi-user.target. It runs the commands one time for a Machine and
//	                 then writes the status "done", or "error" when a command fails.
//
// Why two phases: the one command of NVKE is "systemctl restart nke-agent.service", and that
// unit is ordered after multi-user.target. A unit that multi-user.target waits for cannot
// wait for it.
//
// The status file is the file that the cloud-init shim of the node image reads, so
// "cloud-init status --long" gives the answer to the agent.
package main

import (
	"flag"
	"fmt"
	"os"
	"time"
)

func main() {
	opts := options{}
	flag.StringVar(&opts.Phase, "phase", "", "files or commands")
	flag.StringVar(&opts.DataPath, "data", "/etc/podvm/bootstrap/value", "the cloud-config text")
	flag.StringVar(&opts.Machine, "machine", os.Getenv("PODVM_MACHINE_NAME"), "the name of the Machine")
	flag.StringVar(&opts.StateDir, "state-dir", "/var/lib/podvm/bootstrap", "folder for the markers, on the /var volume")
	flag.StringVar(&opts.StatusFile, "status-file", "/var/lib/nico-containers/cloud-init/status", "the file that the cloud-init shim reads")
	flag.StringVar(&opts.Root, "root", "", "prefix for each write_files path (tests)")
	flag.DurationVar(&opts.WaitData, "wait-data", 30*time.Second, "how long to wait for the data file")
	flag.Parse()

	var (
		line string
		err  error
	)
	switch opts.Phase {
	case "files":
		line, err = phaseFiles(opts)
	case "commands":
		line, err = phaseCommands(opts)
	default:
		fmt.Fprintln(os.Stderr, "use: podvm-bootstrap -phase files|commands")
		os.Exit(2)
	}
	if line != "" {
		fmt.Println(line)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "podvm-bootstrap:", err)
		os.Exit(1)
	}
}
