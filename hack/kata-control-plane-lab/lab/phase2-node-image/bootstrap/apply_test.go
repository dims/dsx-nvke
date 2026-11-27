// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testOptions(t *testing.T, data string) options {
	t.Helper()
	root := t.TempDir()
	dataPath := filepath.Join(root, "value")
	if err := os.WriteFile(dataPath, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	return options{DataPath: dataPath, Machine: "m1", StateDir: filepath.Join(root, "state"),
		StatusFile: filepath.Join(root, "status"), Root: filepath.Join(root, "fs"), WaitData: time.Second}
}

func userData(root string) string {
	return "#cloud-config\nwrite_files:\n" +
		"    - path: /etc/a/one.conf\n      owner: root:root\n      permissions: \"0640\"\n      content: |\n        one\n" +
		"    - path: /etc/a/two.conf\n      content: two\n" +
		"runcmd:\n    - echo ran >>" + filepath.Join(root, "count") + "\n"
}

func TestFirstRunThenRepeat(t *testing.T) {
	opts := testOptions(t, "")
	root := filepath.Dir(opts.DataPath)
	os.WriteFile(opts.DataPath, []byte(userData(root)), 0o600)

	line, err := phaseFiles(opts)
	if err != nil || !strings.Contains(line, "RESULT first files=2 written=2") {
		t.Fatalf("first files phase: %q, %v", line, err)
	}
	if got := readTrim(opts.StatusFile); got != "running" {
		t.Fatalf("status after the files phase: %q", got)
	}
	info, err := os.Stat(filepath.Join(opts.Root, "/etc/a/one.conf"))
	if err != nil || info.Mode().Perm() != 0o640 {
		t.Fatalf("one.conf: %v, %v", info, err)
	}
	if line, err = phaseCommands(opts); err != nil || !strings.Contains(line, "RESULT first commands=1") {
		t.Fatalf("first commands phase: %q, %v", line, err)
	}
	if got := readTrim(opts.StatusFile); got != "done" {
		t.Fatalf("status after the commands phase: %q", got)
	}

	// A new pod for the same Machine: one file is gone, the other has another content.
	os.Remove(filepath.Join(opts.Root, "/etc/a/one.conf"))
	os.WriteFile(filepath.Join(opts.Root, "/etc/a/two.conf"), []byte("changed"), 0o644)
	if line, err = phaseFiles(opts); err != nil || !strings.Contains(line, "RESULT repeat files=2 written=1") {
		t.Fatalf("repeat files phase: %q, %v", line, err)
	}
	if got := readTrim(filepath.Join(opts.Root, "/etc/a/two.conf")); got != "changed" {
		t.Fatalf("a file that is present must stay: %q", got)
	}
	if line, err = phaseCommands(opts); err != nil || !strings.Contains(line, "none runs now") {
		t.Fatalf("repeat commands phase: %q, %v", line, err)
	}
	if got := readTrim(filepath.Join(root, "count")); got != "ran" {
		t.Fatalf("the command must run one time: %q", got)
	}

	// Another Machine on the same volume: all again.
	opts.Machine = "m2"
	if line, err = phaseFiles(opts); err != nil || !strings.Contains(line, "RESULT first") || !strings.Contains(line, "another Machine (m1)") {
		t.Fatalf("files phase of a new Machine: %q, %v", line, err)
	}
	if _, err = phaseCommands(opts); err != nil {
		t.Fatal(err)
	}
	if got := readTrim(filepath.Join(root, "count")); got != "ran\nran" {
		t.Fatalf("the command must run again for a new Machine: %q", got)
	}
}

func TestFailingCommand(t *testing.T) {
	opts := testOptions(t, "#cloud-config\nruncmd:\n    - exit 3\n    - echo never\n")
	if _, err := phaseFiles(opts); err != nil {
		t.Fatal(err)
	}
	line, err := phaseCommands(opts)
	if err == nil || !strings.Contains(line, "command 1 of 2 failed") || readTrim(opts.StatusFile) != "error" {
		t.Fatalf("failing command: %q, %v, status %q", line, err, readTrim(opts.StatusFile))
	}
	if line, err = phaseCommands(opts); err != nil || !strings.Contains(line, "failed before") || readTrim(opts.StatusFile) != "error" {
		t.Fatalf("repeat after a failure: %q, %v", line, err)
	}
}

func TestThroughLinkAndNoData(t *testing.T) {
	opts := testOptions(t, "#cloud-config\nwrite_files:\n    - path: /etc/default/link\n      content: new\n")
	os.MkdirAll(filepath.Join(opts.Root, "/etc/default"), 0o755)
	os.MkdirAll(filepath.Join(opts.Root, "/var/agent"), 0o755)
	os.WriteFile(filepath.Join(opts.Root, "/var/agent/real"), []byte("old"), 0o644)
	os.Symlink(filepath.Join(opts.Root, "/var/agent/real"), filepath.Join(opts.Root, "/etc/default/link"))
	if _, err := phaseFiles(opts); err != nil {
		t.Fatal(err)
	}
	if got := readTrim(filepath.Join(opts.Root, "/var/agent/real")); got != "new" {
		t.Fatalf("the target of the link must get the content: %q", got)
	}
	if info, _ := os.Lstat(filepath.Join(opts.Root, "/etc/default/link")); info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("the link must stay a link")
	}
	opts.Machine, opts.DataPath, opts.WaitData = "m9", opts.DataPath+".absent", 300*time.Millisecond
	if line, err := phaseFiles(opts); err == nil || !strings.Contains(line, "absent at the start") || readTrim(opts.StatusFile) != "error" {
		t.Fatalf("no data file: %q, %v", line, err)
	}
}
