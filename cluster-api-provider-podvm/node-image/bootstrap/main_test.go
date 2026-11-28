// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// testOwner is the user that runs the test, as "user:group". A test cannot
// give a file to root.
func testOwner(t *testing.T) string {
	t.Helper()
	u, err := user.Current()
	require.NoError(t, err)
	g, err := user.LookupGroupId(u.Gid)
	require.NoError(t, err)
	return u.Username + ":" + g.Name
}

// testOptions returns options with every path in a temporary folder, and
// writes the bootstrap data there.
func testOptions(t *testing.T, data string) options {
	t.Helper()
	dir := t.TempDir()
	opts := options{
		machine:    "m1",
		dataPath:   filepath.Join(dir, "value"),
		stateDir:   filepath.Join(dir, "state"),
		statusFile: filepath.Join(dir, "status"),
		root:       filepath.Join(dir, "fs"),
	}
	require.NoError(t, os.WriteFile(opts.dataPath, []byte(data), 0o600))
	return opts
}

func runTestPhase(opts options, phase string) error {
	opts.phase = phase
	return run(opts)
}

func TestBootstrapRunsOneTimeForEachMachine(t *testing.T) {
	owner := testOwner(t)
	opts := testOptions(t, "")
	counter := filepath.Join(filepath.Dir(opts.dataPath), "count")
	// The form that the NVKE controller renders: a quoted mode, a literal block.
	data := "#cloud-config\nwrite_files:\n" +
		"    - path: /etc/a/one.conf\n      owner: " + owner + "\n      permissions: \"0640\"\n      content: |\n        one\n" +
		"    - path: /etc/a/two.conf\n      owner: " + owner + "\n      encoding: b64\n      content: dHdvCg==\n" +
		"runcmd:\n    - echo ran >>" + counter + "\n"
	require.NoError(t, os.WriteFile(opts.dataPath, []byte(data), 0o600))
	one, two := filepath.Join(opts.root, "etc/a/one.conf"), filepath.Join(opts.root, "etc/a/two.conf")

	require.NoError(t, runTestPhase(opts, "files"))
	assert.Equal(t, "running", readTrim(opts.statusFile))
	info, err := os.Stat(one)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o640), info.Mode().Perm())
	assert.Equal(t, "two", readTrim(two), "base64 content is decoded")
	require.NoError(t, runTestPhase(opts, "commands"))
	assert.Equal(t, "done", readTrim(opts.statusFile))

	// A new pod for the same machine: one file is gone, the other was changed.
	require.NoError(t, os.Remove(one))
	require.NoError(t, os.WriteFile(two, []byte("changed"), 0o600))
	require.NoError(t, runTestPhase(opts, "files"))
	require.NoError(t, runTestPhase(opts, "commands"))
	assert.Equal(t, "one", readTrim(one), "an absent file is written again")
	assert.Equal(t, "changed", readTrim(two), "a present file stays")
	assert.Equal(t, "ran", readTrim(counter), "the command runs one time")
	assert.Equal(t, "done", readTrim(opts.statusFile))

	// Another machine on the same volume: everything runs again.
	opts.machine = "m2"
	require.NoError(t, runTestPhase(opts, "files"))
	require.NoError(t, runTestPhase(opts, "commands"))
	assert.Equal(t, "two", readTrim(two))
	assert.Equal(t, "ran\nran", readTrim(counter))
}

func TestFailedCommandSetsStatusErrorAndDoesNotRunAgain(t *testing.T) {
	opts := testOptions(t, "")
	counter := filepath.Join(filepath.Dir(opts.dataPath), "count")
	data := "runcmd:\n  - echo ran >>" + counter + "; exit 3\n  - echo ran >>" + counter + "\n"
	require.NoError(t, os.WriteFile(opts.dataPath, []byte(data), 0o600))

	require.NoError(t, runTestPhase(opts, "files"))
	require.ErrorContains(t, runTestPhase(opts, "commands"), "runcmd 1 of 2")
	assert.Equal(t, "error", readTrim(opts.statusFile))
	require.ErrorContains(t, runTestPhase(opts, "commands"), "no command runs again")
	assert.Equal(t, "error", readTrim(opts.statusFile))
	assert.Equal(t, "ran", readTrim(counter), "no command runs after the failed one")
}

func TestInstallFileWritesThroughALink(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "var/agent")
	link := filepath.Join(root, "etc/default/agent")
	require.NoError(t, os.MkdirAll(filepath.Dir(target), 0o755))
	require.NoError(t, os.MkdirAll(filepath.Dir(link), 0o755))
	require.NoError(t, os.Symlink(target, link))

	require.NoError(t, installFile(root, writeFile{Path: "/etc/default/agent", Owner: testOwner(t), Content: "new"}))
	assert.Equal(t, "new", readTrim(target), "the target of the link gets the content")
	info, err := os.Lstat(link)
	require.NoError(t, err)
	assert.NotZero(t, info.Mode()&os.ModeSymlink, "the link stays a link")
}

func TestRunRejectsBadInput(t *testing.T) {
	tests := map[string]struct {
		data    string
		machine string
		phase   string
		wantErr string
	}{
		"no machine name":        {machine: "", phase: "files", wantErr: "PODVM_MACHINE_NAME"},
		"unknown phase":          {machine: "m1", phase: "all", wantErr: "unknown phase"},
		"commands before files":  {machine: "m1", phase: "commands", wantErr: "files phase did not run"},
		"not a cloud-config":     {machine: "m1", phase: "files", data: "write_files: [", wantErr: "parsing the bootstrap data"},
		"runcmd entry is a list": {machine: "m1", phase: "files", data: "runcmd:\n  - [echo, 1]\n", wantErr: "parsing the bootstrap data"},
		"relative path":          {machine: "m1", phase: "files", data: "write_files:\n  - path: a/b\n", wantErr: "not absolute"},
		"unsupported encoding":   {machine: "m1", phase: "files", data: "write_files:\n  - path: /a\n    encoding: gzip\n", wantErr: "unsupported encoding"},
		"bad base64":             {machine: "m1", phase: "files", data: "write_files:\n  - path: /a\n    encoding: b64\n    content: '%'\n", wantErr: "decoding the content"},
		"bad mode":               {machine: "m1", phase: "files", data: "write_files:\n  - path: /a\n    permissions: u+x\n", wantErr: "octal mode"},
		"mode above 0777":        {machine: "m1", phase: "files", data: "write_files:\n  - path: /a\n    permissions: \"1777\"\n", wantErr: "up to 0777"},
		"bare mode above 0777":   {machine: "m1", phase: "files", data: "write_files:\n  - path: /a\n    permissions: 01777\n", wantErr: "up to 0777"},
		"unknown owner":          {machine: "m1", phase: "files", data: "write_files:\n  - path: /a\n    owner: no-such-user-of-this-test\n", wantErr: "unknown user"},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			opts := testOptions(t, test.data)
			opts.machine = test.machine
			require.ErrorContains(t, runTestPhase(opts, test.phase), test.wantErr)
			assert.Equal(t, "error", readTrim(opts.statusFile))
		})
	}
}

func TestRunFailsWithNoDataFile(t *testing.T) {
	opts := testOptions(t, "")
	require.NoError(t, os.Remove(opts.dataPath))
	require.ErrorContains(t, runTestPhase(opts, "files"), "reading the bootstrap data")
	assert.Equal(t, "error", readTrim(opts.statusFile))
}

// cloud-init takes the quoted text and the bare number, which YAML reads as
// an octal number.
func TestFileModes(t *testing.T) {
	for line, want := range map[string]os.FileMode{
		`permissions: "0640"`: 0o640,
		`permissions: "600"`:  0o600,
		`permissions: 0644`:   0o644,
		`permissions: 0600`:   0o600,
		`encoding: ""`:        0o644, // no mode: the default of cloud-init
	} {
		t.Run(line, func(t *testing.T) {
			opts := testOptions(t, "write_files:\n  - path: /a\n    owner: "+testOwner(t)+"\n    "+line+"\n")
			require.NoError(t, runTestPhase(opts, "files"))
			info, err := os.Stat(filepath.Join(opts.root, "a"))
			require.NoError(t, err)
			assert.Equal(t, want, info.Mode().Perm())
		})
	}
}

func TestFirstStartThatFailsRunsAgain(t *testing.T) {
	owner := testOwner(t)
	data := "write_files:\n  - path: /a\n    owner: " + owner + "\n    content: data\n  - path: /b\n    owner: " + owner + "\n    encoding: "
	opts := testOptions(t, data+"gzip\n")
	require.Error(t, runTestPhase(opts, "files"))

	// The first file was written before the failure. A full first start writes it again.
	a := filepath.Join(opts.root, "a")
	require.NoError(t, os.WriteFile(a, []byte("half"), 0o600))
	require.NoError(t, os.WriteFile(opts.dataPath, []byte(data+"b64\n"), 0o600))
	require.NoError(t, runTestPhase(opts, "files"))
	assert.Equal(t, "data", readTrim(a))
	assert.FileExists(t, filepath.Join(opts.root, "b"))
}

// A new container has the content of the image at each path outside the /var
// volume. /dev/shm stands for such a path: it is another filesystem than the
// temporary folder with the state.
func TestLaterStartWritesAFileOutsideTheVolumeAgain(t *testing.T) {
	opts := testOptions(t, "write_files:\n  - path: /a\n    owner: "+testOwner(t)+"\n    content: data\n")
	root, err := os.MkdirTemp("/dev/shm", "podvm-bootstrap-test-")
	if err != nil {
		t.Skip("no /dev/shm for a second filesystem")
	}
	t.Cleanup(func() { assert.NoError(t, os.RemoveAll(root)) })
	device := func(path string) uint64 {
		info, err := os.Stat(path)
		require.NoError(t, err)
		return uint64(info.Sys().(*syscall.Stat_t).Dev)
	}
	if device(root) == device(filepath.Dir(opts.dataPath)) {
		t.Skip("/dev/shm is the filesystem of the temporary folder")
	}
	opts.root = root
	a := filepath.Join(root, "a")

	require.NoError(t, runTestPhase(opts, "files"))
	require.NoError(t, os.WriteFile(a, []byte("image"), 0o600))
	require.NoError(t, runTestPhase(opts, "files"))
	assert.Equal(t, "data", readTrim(a))
}

// A test cannot give a file to another user. It can give it to another group
// of its own user.
func TestInstallFileSetsTheGroup(t *testing.T) {
	u, err := user.Current()
	require.NoError(t, err)
	groups, err := os.Getgroups()
	require.NoError(t, err)
	for _, gid := range groups {
		g, err := user.LookupGroupId(strconv.Itoa(gid))
		if err != nil || gid == os.Getgid() {
			continue
		}
		root := t.TempDir()
		require.NoError(t, installFile(root, writeFile{Path: "/a", Owner: u.Username + ":" + g.Name}))
		info, err := os.Stat(filepath.Join(root, "a"))
		require.NoError(t, err)
		assert.Equal(t, uint32(gid), info.Sys().(*syscall.Stat_t).Gid)
		return
	}
	t.Skip("the test user has no second group")
}
