// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package nodeimage

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A regular file stands for the volume device: blkid, dd and mkfs.ext4 take one.
func TestFormatIfEmpty(t *testing.T) {
	blkid, err := exec.LookPath("blkid")
	if err != nil {
		t.Skip("blkid is not installed")
	}
	if _, err := exec.LookPath("mkfs.ext4"); err != nil {
		t.Skip("mkfs.ext4 is not installed")
	}
	// uuid returns the UUID of the filesystem on a file, or "" for none.
	uuid := func(path string) string {
		out, _ := exec.CommandContext(t.Context(), blkid, "-p", "-o", "value", "-s", "UUID", path).Output()
		return strings.TrimSpace(string(out))
	}

	tests := map[string]struct {
		missing    bool   // the device does not exist
		filesystem bool   // the device has a filesystem before the call
		blkidExit  string // a blkid that only ends with this exit code. Empty is the real blkid
		wantErr    string
		wantFormat bool
	}{
		"an empty device is formatted": {wantFormat: true},
		"a filesystem stays":           {filesystem: true},
		// blkid ends with 2 for a device that it cannot read to the end.
		"a filesystem that blkid does not see stays":   {filesystem: true, blkidExit: "2", wantErr: "has an ext4 superblock"},
		"another answer of blkid stops the start":      {blkidExit: "8", wantErr: "blkid ended with exit code 8"},
		"a device that cannot be read stops the start": {missing: true, wantErr: "cannot be read"},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			device := filepath.Join(dir, "device")
			if !test.missing {
				require.NoError(t, os.WriteFile(device, nil, 0o600))
				require.NoError(t, os.Truncate(device, 32<<20))
			}
			if test.filesystem {
				require.NoError(t, exec.CommandContext(t.Context(), "mkfs.ext4", "-q", device).Run())
			}
			before := uuid(device)

			cmd := exec.CommandContext(t.Context(), "bash", "format-if-empty", device, "podvm-test")
			if test.blkidExit != "" {
				fake := filepath.Join(dir, "bin", "blkid")
				require.NoError(t, os.Mkdir(filepath.Dir(fake), 0o755))
				require.NoError(t, os.WriteFile(fake, []byte("#!/bin/sh\nexit "+test.blkidExit+"\n"), 0o755))
				cmd.Env = append(os.Environ(), "PATH="+filepath.Dir(fake)+":"+os.Getenv("PATH"))
			}
			output, err := cmd.CombinedOutput()

			if test.wantErr == "" {
				require.NoError(t, err, string(output))
			} else {
				require.Error(t, err)
				assert.Contains(t, string(output), test.wantErr)
			}
			if test.wantFormat {
				assert.NotEmpty(t, uuid(device), "the device has a filesystem now")
			} else {
				assert.Equal(t, before, uuid(device), "the device is as it was")
			}
		})
	}
}
