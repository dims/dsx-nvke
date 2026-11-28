// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// Command podvm-bootstrap applies the bootstrap data of the NVKE controller in
// the node image for pod machines. The data is a cloud-config text with
// write_files and runcmd. It runs as two systemd units, in the way of
// cloud-init:
//
//	-phase files     before the SPIRE agent and the node agent. It writes the
//	                 files. A later start for the same machine leaves a file
//	                 on the /var volume as it is, and writes each other file
//	                 again.
//	-phase commands  when the system is up. It runs the commands one time for a
//	                 machine and then sets the cloud-init status to "done".
//
// One unit cannot do both: the command of the controller restarts the node
// agent unit, and that unit starts after the target that would wait for this
// unit. A phase that fails sets the status to "error".
package main

import (
	"cmp"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"k8s.io/apimachinery/pkg/util/yaml"
)

type options struct {
	phase      string
	machine    string // the name of the Machine
	dataPath   string // the cloud-config text, from the Secret volume of the pod
	stateDir   string // the markers, on the /var volume
	statusFile string // the file that the cloud-init shim of the base image reads
	root       string // prefix of each write_files path, for tests
}

// cloudConfig is the part of a cloud-config that the NVKE controller renders.
type cloudConfig struct {
	WriteFiles []writeFile `json:"write_files"`
	RunCmd     []string    `json:"runcmd"`
}

type writeFile struct {
	Path        string      `json:"path"`
	Owner       string      `json:"owner"`
	Permissions permissions `json:"permissions"`
	Encoding    string      `json:"encoding"`
	Content     string      `json:"content"`
}

// permissions is the mode of a file as octal text. The NVKE controller writes
// a quoted text. cloud-init also takes a bare number, and YAML reads a bare
// 0644 as the octal number 420, so a number goes back to its octal text.
type permissions string

// UnmarshalJSON implements json.Unmarshaler.
func (p *permissions) UnmarshalJSON(data []byte) error {
	var text string
	if err := json.Unmarshal(data, &text); err != nil {
		var number uint32
		if err := json.Unmarshal(data, &number); err != nil {
			return fmt.Errorf("permissions %s are not an octal text or a number", data)
		}
		text = strconv.FormatUint(uint64(number), 8)
	}
	*p = permissions(text)
	return nil
}

func main() {
	opts := options{
		machine:    os.Getenv("PODVM_MACHINE_NAME"),
		dataPath:   "/etc/podvm/bootstrap/value",
		stateDir:   "/var/lib/podvm/bootstrap",
		statusFile: "/var/lib/nico-containers/cloud-init/status",
	}
	flag.StringVar(&opts.phase, "phase", "", "files or commands")
	flag.Parse()
	if err := run(opts); err != nil {
		slog.Error("bootstrap failed", "phase", opts.phase, "machine", opts.machine, "err", err)
		os.Exit(1)
	}
}

func run(opts options) error {
	err := runPhase(opts)
	if err != nil {
		err = errors.Join(err, writeAtomic(opts.statusFile, "error"))
	}
	return err
}

func runPhase(opts options) error {
	if opts.machine == "" {
		return errors.New("PODVM_MACHINE_NAME is not set")
	}
	data, err := os.ReadFile(opts.dataPath)
	if err != nil {
		return fmt.Errorf("reading the bootstrap data: %w", err)
	}
	var cfg cloudConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return fmt.Errorf("parsing the bootstrap data: %w", err)
	}
	switch opts.phase {
	case "files":
		return writeFiles(opts, cfg.WriteFiles)
	case "commands":
		return runCommands(opts, cfg.RunCmd)
	}
	return fmt.Errorf("unknown phase %q, use files or commands", opts.phase)
}

// writeFiles writes every file at the first start for a machine. A later
// start is a new container, so each path outside the /var volume has the
// content of the image again, or no file. Such a file is written again. A file
// on the volume stays as it is.
func writeFiles(opts options, files []writeFile) error {
	machineMarker := filepath.Join(opts.stateDir, "machine")
	first := readTrim(machineMarker) != opts.machine
	if first {
		if err := writeAtomic(opts.statusFile, "running"); err != nil {
			return err
		}
		if err := os.Remove(filepath.Join(opts.stateDir, "commands")); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("removing the commands marker: %w", err)
		}
	}
	written := 0
	for _, file := range files {
		if !first && onVolume(filepath.Join(opts.root, file.Path), opts.stateDir) {
			continue
		}
		if err := installFile(opts.root, file); err != nil {
			return fmt.Errorf("write_files %s: %w", file.Path, err)
		}
		written++
	}
	slog.Info("wrote the bootstrap files", "machine", opts.machine, "firstStart", first, "files", len(files), "written", written)
	if !first {
		return nil
	}
	// The marker comes last, so a first start that stopped half way runs again.
	return writeAtomic(machineMarker, opts.machine)
}

// onVolume reports whether path is a file on the filesystem of the state
// folder, which is the /var volume. A link or a bind mount into the volume
// counts, because the file itself is there.
func onVolume(path, stateDir string) bool {
	file, err := os.Stat(path)
	if err != nil {
		return false
	}
	state, err := os.Stat(stateDir)
	if err != nil {
		return false
	}
	fileStat, fileOK := file.Sys().(*syscall.Stat_t)
	stateStat, stateOK := state.Sys().(*syscall.Stat_t)
	return fileOK && stateOK && fileStat.Dev == stateStat.Dev
}

// installFile writes in place and not through a rename: a path can be a link
// into the /var volume, and the link must stay.
func installFile(root string, file writeFile) error {
	if !filepath.IsAbs(file.Path) {
		return errors.New("the path is not absolute")
	}
	content := []byte(file.Content)
	switch file.Encoding {
	case "":
	case "b64", "base64":
		decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(file.Content))
		if err != nil {
			return fmt.Errorf("decoding the content: %w", err)
		}
		content = decoded
	default:
		return fmt.Errorf("unsupported encoding %q", file.Encoding)
	}
	// The defaults are the defaults of cloud-init.
	mode, err := strconv.ParseUint(cmp.Or(string(file.Permissions), "0644"), 8, 9)
	if err != nil {
		return fmt.Errorf("permissions are not an octal mode up to 0777: %w", err)
	}
	uid, gid, err := lookupOwner(cmp.Or(file.Owner, "root:root"))
	if err != nil {
		return err
	}
	path := filepath.Join(root, file.Path)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, content, 0o600); err != nil {
		return err
	}
	if err := os.Chown(path, uid, gid); err != nil {
		return err
	}
	return os.Chmod(path, os.FileMode(mode))
}

// lookupOwner resolves "user" or "user:group" to numeric IDs.
func lookupOwner(owner string) (uid, gid int, err error) {
	name, group, hasGroup := strings.Cut(owner, ":")
	u, err := user.Lookup(name)
	if err != nil {
		return 0, 0, err
	}
	gidText := u.Gid
	if hasGroup {
		g, err := user.LookupGroup(group)
		if err != nil {
			return 0, 0, err
		}
		gidText = g.Gid
	}
	if uid, err = strconv.Atoi(u.Uid); err != nil {
		return 0, 0, err
	}
	gid, err = strconv.Atoi(gidText)
	return uid, gid, err
}

// runCommands runs the commands one time for a machine. A run that failed or
// stopped half way does not run again: a command can be unsafe to repeat.
func runCommands(opts options, commands []string) error {
	if readTrim(filepath.Join(opts.stateDir, "machine")) != opts.machine {
		return errors.New("the files phase did not run for this machine")
	}
	commandsMarker := filepath.Join(opts.stateDir, "commands")
	switch state := readTrim(commandsMarker); state {
	case "":
	case "done":
		return writeAtomic(opts.statusFile, "done")
	default:
		return fmt.Errorf("an earlier run of the commands ended as %q, no command runs again", state)
	}
	if err := writeAtomic(commandsMarker, "started"); err != nil {
		return err
	}
	for i, command := range commands {
		cmd := exec.Command("/bin/sh", "-c", command)
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("runcmd %d of %d: %w", i+1, len(commands), err)
		}
	}
	slog.Info("ran the bootstrap commands", "machine", opts.machine, "commands", len(commands))
	if err := writeAtomic(commandsMarker, "done"); err != nil {
		return err
	}
	return writeAtomic(opts.statusFile, "done")
}

func readTrim(path string) string {
	data, _ := os.ReadFile(path)
	return strings.TrimSpace(string(data))
}

// writeAtomic writes a marker or the status with one rename, so a reader sees
// the old text or the new text.
func writeAtomic(path, text string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(text+"\n"), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
