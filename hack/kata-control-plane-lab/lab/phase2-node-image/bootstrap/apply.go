// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type options struct {
	Phase      string
	DataPath   string
	Machine    string
	StateDir   string
	StatusFile string
	Root       string
	WaitData   time.Duration
}

const (
	machineMarker  = "machine"    // the Machine whose data this volume has
	commandsMarker = "commands"   // "started <name>", "done <name>" or "failed <name>"
	outputLog      = "output.log" // the output of the commands
)

func uptime() string {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return "?"
	}
	return strings.Fields(string(data))[0]
}

func readTrim(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// writeAtomic writes a file with one rename, so a reader sees all of it or none.
func writeAtomic(path string, content []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".podvm-bootstrap.tmp"
	if err := os.WriteFile(tmp, content, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

func writeStatus(opts options, status string) error {
	return writeAtomic(opts.StatusFile, []byte(status+"\n"), 0o644)
}

// realPath is the path that a write must use: cloud-init opens the path and writes, so a
// symbolic link stays and its target gets the content. /etc/default/nke-agent is a link.
func realPath(path string) (string, error) {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved, nil
	}
	dir, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return "", err
		}
		if dir, err = filepath.EvalSymlinks(filepath.Dir(path)); err != nil {
			return "", err
		}
	}
	target := filepath.Join(dir, filepath.Base(path))
	// A link whose target does not exist yet: follow it one more time.
	if link, err := os.Readlink(target); err == nil {
		if !filepath.IsAbs(link) {
			link = filepath.Join(dir, link)
		}
		return realPath(link)
	}
	return target, nil
}

func lookupOwner(owner string) (int, int, error) {
	name, group, hasGroup := strings.Cut(owner, ":")
	u, err := user.Lookup(name)
	if err != nil {
		return 0, 0, err
	}
	uid, _ := strconv.Atoi(u.Uid)
	gid, _ := strconv.Atoi(u.Gid)
	if hasGroup {
		g, err := user.LookupGroup(group)
		if err != nil {
			return 0, 0, err
		}
		gid, _ = strconv.Atoi(g.Gid)
	}
	return uid, gid, nil
}

func installFile(opts options, f file) error {
	path, err := realPath(filepath.Join(opts.Root, f.Path))
	if err != nil {
		return err
	}
	mode, err := strconv.ParseUint(f.Mode, 8, 32)
	if err != nil {
		return err
	}
	uid, gid, err := lookupOwner(f.Owner)
	if err != nil {
		return err
	}
	tmp := path + ".podvm-bootstrap.tmp"
	if err := os.WriteFile(tmp, f.Content, 0o600); err != nil {
		return err
	}
	if err := os.Chown(tmp, uid, gid); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Chmod(tmp, os.FileMode(mode)); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// loadData waits for the data file and parses it. The first return value says what it saw.
func loadData(opts options) (string, []file, []string, error) {
	start := time.Now()
	seen := "present at the start"
	for {
		if info, err := os.Stat(opts.DataPath); err == nil && info.Mode().IsRegular() {
			break
		}
		seen = "absent at the start"
		if time.Since(start) > opts.WaitData {
			return seen, nil, nil, fmt.Errorf("no data file %s after %s", opts.DataPath, opts.WaitData)
		}
		time.Sleep(200 * time.Millisecond)
	}
	if seen != "present at the start" {
		seen = fmt.Sprintf("absent at the start, present after %.1f s", time.Since(start).Seconds())
	}
	data, err := os.ReadFile(opts.DataPath)
	if err != nil {
		return seen, nil, nil, err
	}
	files, commands, err := parseCloudConfig(data)
	return seen, files, commands, err
}

func phaseFiles(opts options) (string, error) {
	head := fmt.Sprintf("podvm-bootstrap files: machine %q, uptime %s s", opts.Machine, uptime())
	if opts.Machine == "" {
		writeStatus(opts, "error")
		return head, errors.New("no Machine name (PODVM_MACHINE_NAME)")
	}
	seen, files, _, err := loadData(opts)
	head += ", data " + seen
	if err != nil {
		writeStatus(opts, "error")
		return head, err
	}
	marker := filepath.Join(opts.StateDir, machineMarker)
	if readTrim(marker) == opts.Machine {
		// A later start for the same Machine: only a file that is absent.
		written := 0
		for _, f := range files {
			if _, err := os.Stat(filepath.Join(opts.Root, f.Path)); err == nil {
				continue
			} else if !errors.Is(err, os.ErrNotExist) {
				return head, err
			}
			if err := installFile(opts, f); err != nil {
				writeStatus(opts, "error")
				return head, fmt.Errorf("write_files %s: %w", f.Path, err)
			}
			written++
		}
		return fmt.Sprintf("%s. RESULT repeat files=%d written=%d (only absent files)", head, len(files), written), nil
	}
	note := ""
	if old := readTrim(marker); old != "" {
		note = fmt.Sprintf(" The volume had the marker of another Machine (%s).", old)
	}
	if err := writeStatus(opts, "running"); err != nil {
		return head, err
	}
	os.Remove(filepath.Join(opts.StateDir, commandsMarker))
	if err := writeAtomic(marker, []byte(opts.Machine+"\n"), 0o644); err != nil {
		return head, err
	}
	for _, f := range files {
		if err := installFile(opts, f); err != nil {
			writeStatus(opts, "error")
			return head, fmt.Errorf("write_files %s: %w", f.Path, err)
		}
	}
	return fmt.Sprintf("%s. RESULT first files=%d written=%d.%s", head, len(files), len(files), note), nil
}

func phaseCommands(opts options) (string, error) {
	head := fmt.Sprintf("podvm-bootstrap commands: machine %q, uptime %s s", opts.Machine, uptime())
	if opts.Machine == "" || readTrim(filepath.Join(opts.StateDir, machineMarker)) != opts.Machine {
		writeStatus(opts, "error")
		return head, errors.New("the files phase did not run for this Machine")
	}
	marker := filepath.Join(opts.StateDir, commandsMarker)
	switch readTrim(marker) {
	case "done " + opts.Machine:
		if readTrim(opts.StatusFile) != "done" {
			writeStatus(opts, "done")
		}
		return head + ". RESULT repeat: the commands ran before for this Machine, none runs now. Status done", nil
	case "failed " + opts.Machine:
		writeStatus(opts, "error")
		return head + ". RESULT repeat: a command failed before for this Machine, none runs now. Status error", nil
	case "started " + opts.Machine:
		writeStatus(opts, "error")
		return head + ". RESULT repeat: an earlier run stopped in its commands, none runs again. Status error", nil
	}
	_, _, commands, err := loadData(opts)
	if err != nil {
		writeStatus(opts, "error")
		return head, err
	}
	if err := writeAtomic(marker, []byte("started "+opts.Machine+"\n"), 0o644); err != nil {
		return head, err
	}
	logFile, err := os.OpenFile(filepath.Join(opts.StateDir, outputLog), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return head, err
	}
	defer logFile.Close()
	for i, command := range commands {
		var out bytes.Buffer
		cmd := exec.Command("/bin/sh", "-c", command)
		cmd.Stdout, cmd.Stderr = &out, &out
		runErr := cmd.Run()
		fmt.Fprintf(logFile, "%s machine %s command %d: %s\n%s", time.Now().UTC().Format(time.RFC3339), opts.Machine, i+1, command, out.String())
		if runErr != nil {
			fmt.Fprintf(logFile, "command %d failed: %v\n", i+1, runErr)
			writeAtomic(marker, []byte("failed "+opts.Machine+"\n"), 0o644)
			writeStatus(opts, "error")
			return fmt.Sprintf("%s. RESULT first: command %d of %d failed. Status error", head, i+1, len(commands)), fmt.Errorf("runcmd %d: %w", i+1, runErr)
		}
	}
	if err := writeAtomic(marker, []byte("done "+opts.Machine+"\n"), 0o644); err != nil {
		return head, err
	}
	if err := writeStatus(opts, "done"); err != nil {
		return head, err
	}
	return fmt.Sprintf("%s. RESULT first commands=%d. Status done", head, len(commands)), nil
}
