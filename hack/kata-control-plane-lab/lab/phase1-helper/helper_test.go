// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/base64"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The format that NVKE renders with spireAttestationMethod joinToken
// (controller/internal/clients/capi/bootstrap_userdata.go:101-163).
const sampleUserData = `#cloud-config
write_files:
    - path: /etc/spire-agent/initial-trust-bundle.pem
      owner: root:root
      permissions: "0644"
      content: |
        -----BEGIN CERTIFICATE-----
        AAAA
        -----END CERTIFICATE-----
    - path: /etc/spire-agent/agent.conf
      owner: root:root
      permissions: "0644"
      content: |
        agent {
            join_token = "not-a-real-token"
        }
    - path: /etc/nke/controller-ca.crt
      owner: root:root
      permissions: "0644"
      encoding: b64
      content: aGVsbG8K
    - path: /etc/default/nke-agent
      owner: root:root
      permissions: "0644"
      content: |
        AGENT_ARGS="--secure-server-port 15005"
runcmd:
    - systemctl restart nke-agent.service
`

func TestParseCloudConfig(t *testing.T) {
	files, commands, err := parseCloudConfig([]byte(sampleUserData))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 4 || len(commands) != 1 {
		t.Fatalf("got %d files and %d commands", len(files), len(commands))
	}
	if files[0].Path != "/etc/spire-agent/initial-trust-bundle.pem" || files[1].Path != "/etc/spire-agent/agent.conf" {
		t.Errorf("the order of the files changed: %s, %s", files[0].Path, files[1].Path)
	}
	if got := string(files[1].Content); got != "agent {\n    join_token = \"not-a-real-token\"\n}\n" {
		t.Errorf("agent.conf content: %q", got)
	}
	if got := string(files[2].Content); got != "hello\n" {
		t.Errorf("b64 content: %q", got)
	}
	if files[3].Mode != "0644" || files[3].Owner != "root:root" {
		t.Errorf("mode %q owner %q", files[3].Mode, files[3].Owner)
	}
	if commands[0] != "systemctl restart nke-agent.service" {
		t.Errorf("command: %q", commands[0])
	}
}

func TestParseCloudConfigForms(t *testing.T) {
	tests := map[string]struct {
		userData string
		wantErr  string
		check    func(*testing.T, []file, []string)
	}{
		"empty user data": {
			userData: "",
			check: func(t *testing.T, files []file, commands []string) {
				if len(files) != 0 || len(commands) != 0 {
					t.Errorf("want nothing, got %d files, %d commands", len(files), len(commands))
				}
			},
		},
		"defaults and a bare octal mode": {
			userData: "#cloud-config\nwrite_files:\n  - path: /a\n    content: x\n  - path: /b\n    permissions: 0600\n    owner: etcd\n    content: y\n  - path: ' '\n    content: skipped\nruncmd:\n  - ''\n  - echo 1\n",
			check: func(t *testing.T, files []file, commands []string) {
				if len(files) != 2 || files[0].Mode != "0644" || files[0].Owner != "root:root" {
					t.Errorf("defaults: %+v", files)
				}
				if files[1].Mode != "0600" || files[1].Owner != "etcd" {
					t.Errorf("bare mode: %+v", files[1])
				}
				if len(commands) != 1 {
					t.Errorf("commands: %q", commands)
				}
			},
		},
		"unsupported encoding":   {userData: "write_files:\n  - path: /a\n    encoding: gzip\n    content: x\n", wantErr: "unsupported cloud-config encoding"},
		"relative path":          {userData: "write_files:\n  - path: a/b\n    content: x\n", wantErr: "not an absolute path"},
		"bad mode":               {userData: "write_files:\n  - path: /a\n    permissions: \"u+x\"\n    content: x\n", wantErr: "not an octal mode"},
		"bad owner":              {userData: "write_files:\n  - path: /a\n    owner: \"root;id\"\n    content: x\n", wantErr: "not user or user:group"},
		"runcmd entry is a list": {userData: "runcmd:\n  - [echo, 1]\n", wantErr: "parse cloud-config"},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			files, commands, err := parseCloudConfig([]byte(test.userData))
			if test.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErr) {
					t.Fatalf("want error with %q, got %v", test.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			test.check(t, files, commands)
		})
	}
}

func TestParseResult(t *testing.T) {
	result, found := parseResult("NOTE old marker\nRESULT error first files_written=2: command 2 of 3 failed (exit code 3), see /x/output.log in the pod\n")
	if !found || result.State != "error" || result.Mode != "first" || len(result.Notes) != 1 {
		t.Fatalf("%+v %v", result, found)
	}
	if !strings.HasPrefix(result.Detail, "files_written=2: command 2 of 3 failed") {
		t.Errorf("detail: %q", result.Detail)
	}
	if _, found := parseResult("some text\n"); found {
		t.Error("a result with no RESULT line")
	}
}

// node is a folder that stands for the filesystem of a host pod.
type node struct {
	t     *testing.T
	root  string
	state string
	owner string
}

func newNode(t *testing.T) *node {
	t.Helper()
	current, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	group, err := user.LookupGroupId(current.Gid)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	return &node{t: t, root: root, state: filepath.Join(root, "var/lib/cloud-init"), owner: current.Username + ":" + group.Name}
}

func (n *node) path(name string) string { return filepath.Join(n.root, name) }

func (n *node) file(name, mode, content string) file {
	return file{Path: n.path(name), Mode: mode, Owner: n.owner, Content: []byte(content)}
}

// run executes the apply script as the exec call does and returns the script result.
func (n *node) run(machineID string, files []file, commands []string) execResult {
	n.t.Helper()
	script := buildApplyScript(scriptOptions{MachineID: machineID, StateDir: n.state}, files, commands)
	scriptPath := filepath.Join(n.root, "apply.sh")
	if err := os.WriteFile(scriptPath, []byte(script), 0o600); err != nil {
		n.t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	// The exec call can start the script with any umask. The script sets its own.
	output, err := exec.CommandContext(ctx, "sh", "-c", `umask 077; exec sh "$1"`, "sh", scriptPath).Output()
	result, found := parseResult(string(output))
	if !found {
		n.t.Fatalf("no RESULT line. err=%v output=%q", err, output)
	}
	if _, statErr := os.Stat(scriptPath); !os.IsNotExist(statErr) {
		n.t.Errorf("the script did not remove itself")
	}
	return result
}

func (n *node) read(path string) string {
	n.t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		n.t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func (n *node) status() string { return n.read(filepath.Join(n.state, "status")) }

func (n *node) lines(name string) int {
	data, err := os.ReadFile(n.path(name))
	if err != nil {
		return 0
	}
	return strings.Count(string(data), "\n")
}

func (n *node) wantMode(path string, want os.FileMode) {
	n.t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		n.t.Fatal(err)
	}
	if info.Mode().Perm() != want {
		n.t.Errorf("%s has mode %o, want %o", path, info.Mode().Perm(), want)
	}
}

func TestApplyScriptFirstRunAndRepeat(t *testing.T) {
	n := newNode(t)
	// The node image has /etc/default/nke-agent as a link to /etc/default/nvke-agent.
	if err := os.MkdirAll(n.path("etc/default"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(n.path("etc/default/nvke-agent"), []byte("AGENT_ARGS=\"image\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(n.path("etc/default/nvke-agent"), n.path("etc/default/nke-agent")); err != nil {
		t.Fatal(err)
	}
	binary := string([]byte{0, 1, 2, 255, '\n', '\''})
	files := []file{
		n.file("etc/spire-agent/initial-trust-bundle.pem", "0644", "bundle\n"),
		n.file("etc/spire-agent/agent.conf", "0600", "agent {\n    join_token = \"x\"\n}\n"),
		n.file("etc/default/nke-agent", "0644", "AGENT_ARGS=\"--secure-server-port 15005\"\n"),
		n.file("etc/it's a dir/binary", "0640", binary),
		n.file("etc/empty", "0644", ""),
	}
	count := n.path("count")
	commands := []string{
		"echo one >> '" + count + "'",
		"echo \"it's two\" >> '" + count + "'; echo to-the-log; echo to-the-log-2 >&2",
	}

	first := n.run("machine-1", files, commands)
	if first.State != "done" || first.Mode != "first" || first.Detail != "files_written=5 commands=2" {
		t.Fatalf("first run: %+v", first)
	}
	if got := n.read(files[1].Path); got != string(files[1].Content) {
		t.Errorf("agent.conf: %q", got)
	}
	n.wantMode(files[0].Path, 0o644)
	n.wantMode(files[1].Path, 0o600)
	n.wantMode(files[3].Path, 0o640)
	if got := n.read(files[3].Path); got != binary {
		t.Errorf("binary content: %q", got)
	}
	if info, err := os.Lstat(n.path("etc/default/nke-agent")); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Errorf("the link nke-agent is not a link any more")
	}
	if got := n.read(n.path("etc/default/nvke-agent")); got != string(files[2].Content) {
		t.Errorf("the target of the link has %q", got)
	}
	if n.status() != "done\n" {
		t.Errorf("status %q", n.status())
	}
	if got := n.read(filepath.Join(n.state, markerName)); got != "machine-1\n" {
		t.Errorf("marker %q", got)
	}
	if n.lines("count") != 2 {
		t.Errorf("the commands ran %d lines, want 2", n.lines("count"))
	}
	if got := n.read(filepath.Join(n.state, "output.log")); got != "to-the-log\nto-the-log-2\n" {
		t.Errorf("output.log %q", got)
	}
	if got := n.read(filepath.Join(n.state, "runcmd.sh")); !strings.Contains(got, "sh -lc 'echo one >> ") {
		t.Errorf("runcmd.sh has no command: %q", got)
	}
	if leftovers, _ := filepath.Glob(n.path("etc/spire-agent/*nvke-helper*")); len(leftovers) != 0 {
		t.Errorf("temporary files stay: %v", leftovers)
	}
	n.wantMode(n.state, 0o755)
	n.wantMode(n.path("etc/spire-agent"), 0o755)
	n.wantMode(filepath.Join(n.state, "status"), 0o644)
	n.wantMode(filepath.Join(n.state, markerName), 0o644)
	n.wantMode(filepath.Join(n.state, "runcmd.sh"), 0o600)

	// A second pass does nothing.
	before, _ := os.Stat(files[1].Path)
	second := n.run("machine-1", files, commands)
	if second.State != "done" || second.Mode != "repeat" || second.Detail != "files_written=0" {
		t.Fatalf("second run: %+v", second)
	}
	after, _ := os.Stat(files[1].Path)
	if !after.ModTime().Equal(before.ModTime()) {
		t.Errorf("the second pass wrote agent.conf again")
	}
	if n.lines("count") != 2 {
		t.Errorf("the commands ran again: %d lines", n.lines("count"))
	}

	// A new container has the /etc of the image: one file is absent, one has the image content.
	if err := os.Remove(files[1].Path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(n.path("etc/default/nvke-agent"), []byte("AGENT_ARGS=\"image\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	third := n.run("machine-1", files, commands)
	if third.State != "done" || third.Mode != "repeat" || third.Detail != "files_written=2" {
		t.Fatalf("third run: %+v", third)
	}
	if got := n.read(files[1].Path); got != string(files[1].Content) {
		t.Errorf("agent.conf after the repair: %q", got)
	}
	if n.lines("count") != 2 {
		t.Errorf("the commands ran again: %d lines", n.lines("count"))
	}

	// Another machine on the same state: the commands run for it, with a note.
	fourth := n.run("machine-2", files, commands)
	if fourth.State != "done" || fourth.Mode != "first" || len(fourth.Notes) != 1 {
		t.Fatalf("fourth run: %+v", fourth)
	}
	if n.lines("count") != 4 {
		t.Errorf("want 4 lines, got %d", n.lines("count"))
	}
}

func TestApplyScriptFailingCommand(t *testing.T) {
	n := newNode(t)
	files := []file{n.file("etc/a", "0644", "a\n")}
	count := n.path("count")
	commands := []string{"echo one >> '" + count + "'", "exit 3", "echo three >> '" + count + "'"}

	first := n.run("machine-1", files, commands)
	if first.State != "error" || first.Mode != "first" {
		t.Fatalf("first run: %+v", first)
	}
	if !strings.Contains(first.Detail, "command 2 of 3 failed (exit code 3)") {
		t.Errorf("detail: %q", first.Detail)
	}
	if n.status() != "error\n" {
		t.Errorf("status %q", n.status())
	}
	if n.lines("count") != 1 {
		t.Errorf("want 1 line, got %d", n.lines("count"))
	}

	second := n.run("machine-1", files, commands)
	if second.State != "error" || second.Mode != "repeat" || !strings.Contains(second.Detail, "an earlier run for this machine failed") {
		t.Fatalf("second run: %+v", second)
	}
	if n.lines("count") != 1 {
		t.Errorf("the commands ran again: %d lines", n.lines("count"))
	}
	if n.status() != "error\n" {
		t.Errorf("status %q", n.status())
	}
}

func TestApplyScriptFailingFile(t *testing.T) {
	n := newNode(t)
	bad := n.file("etc/a", "0644", "a\n")
	bad.Owner = "no-such-user-nvke-helper"
	first := n.run("machine-1", []file{bad}, []string{"echo one >> '" + n.path("count") + "'"})
	if first.State != "error" || first.Mode != "first" || !strings.Contains(first.Detail, "write_files failed") {
		t.Fatalf("first run: %+v", first)
	}
	if n.status() != "error\n" || n.lines("count") != 0 {
		t.Errorf("status %q, %d lines", n.status(), n.lines("count"))
	}
	if leftovers, _ := filepath.Glob(n.path("etc/*nvke-helper*")); len(leftovers) != 0 {
		t.Errorf("temporary files stay: %v", leftovers)
	}
}

func TestApplyScriptStoppedRun(t *testing.T) {
	n := newNode(t)
	if err := os.MkdirAll(n.state, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{markerName: "machine-1\n", "status": "running\n"} {
		if err := os.WriteFile(filepath.Join(n.state, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	result := n.run("machine-1", nil, []string{"echo one >> '" + n.path("count") + "'"})
	if result.State != "error" || result.Mode != "repeat" || !strings.Contains(result.Detail, "stopped before its end") {
		t.Fatalf("%+v", result)
	}
	if n.status() != "error\n" || n.lines("count") != 0 {
		t.Errorf("status %q, %d lines", n.status(), n.lines("count"))
	}
}

func TestApplyScriptNothingToWrite(t *testing.T) {
	n := newNode(t)
	result := n.run("machine-1", nil, nil)
	if result.State != "done" || result.Detail != "files_written=0 commands=0" {
		t.Fatalf("%+v", result)
	}
	if n.status() != "done\n" {
		t.Errorf("status %q", n.status())
	}
}

// A command that leaves a process behind must not hold the helper.
func TestApplyScriptBackgroundProcess(t *testing.T) {
	n := newNode(t)
	start := time.Now()
	result := n.run("machine-1", nil, []string{"sleep 15 &"})
	if result.State != "done" {
		t.Fatalf("%+v", result)
	}
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Errorf("the run waited %s for the background process", elapsed)
	}
}

func TestExecCommandReceivesTheScript(t *testing.T) {
	if _, err := os.Stat("/run"); err != nil {
		t.Skip("no /run")
	}
	if err := os.WriteFile("/run/.nvke-helper-test", nil, 0o600); err != nil {
		t.Skip("cannot write to /run")
	}
	os.Remove("/run/.nvke-helper-test")

	script := "rm -f \"$0\"\necho RESULT done first ok\n"
	command := execCommand(len(script))
	cmd := exec.Command(command[0], command[1:]...)
	// More bytes than the script on stdin: the receiver must take only the script.
	cmd.Stdin = strings.NewReader(script + "echo RESULT error first extra\n")
	output, err := cmd.Output()
	if err != nil {
		t.Fatalf("%v: %q", err, output)
	}
	if result, found := parseResult(string(output)); !found || result.State != "done" {
		t.Fatalf("%q", output)
	}

	// Fewer bytes than announced: nothing runs.
	short := exec.Command(command[0], command[1:]...)
	short.Stdin = strings.NewReader(script[:10])
	output, err = short.Output()
	if err == nil || strings.Contains(string(output), "RESULT") {
		t.Fatalf("a short script ran: %v %q", err, output)
	}
	if leftovers, _ := filepath.Glob("/run/nvke-lab-bootstrap-helper.*"); len(leftovers) != 0 {
		t.Errorf("files stay in /run: %v", leftovers)
	}
}

func TestBase64Lines(t *testing.T) {
	content := []byte(strings.Repeat("x", 200))
	text := base64Lines(content)
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if len(line) > 76 {
			t.Errorf("line of %d characters", len(line))
		}
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(text, "\n", ""))
	if err != nil || string(decoded) != string(content) {
		t.Errorf("round trip failed: %v", err)
	}
}
