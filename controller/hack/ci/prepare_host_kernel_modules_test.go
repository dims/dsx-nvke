// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package ci

import (
	"os/exec"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHostKernelPackageVersion(t *testing.T) {
	tests := []struct {
		name      string
		signature string
		release   string
		want      string
		wantError bool
	}{
		{
			name:      "Jammy AWS backport retains its distribution build",
			signature: "Ubuntu 6.8.0-1051.54~22.04.1-aws 6.8.12",
			release:   "6.8.0-1051-aws",
			want:      "6.8.0-1051.54~22.04.1\n",
		},
		{
			name:      "Noble AWS build with the same release is distinct",
			signature: "Ubuntu 6.8.0-1051.54-aws 6.8.12",
			release:   "6.8.0-1051-aws",
			want:      "6.8.0-1051.54\n",
		},
		{
			name:      "native generic build",
			signature: "Ubuntu 6.8.0-117.117-generic 6.8.12",
			release:   "6.8.0-117-generic",
			want:      "6.8.0-117.117\n",
		},
		{
			name:      "multi-part AWS flavor",
			signature: "Ubuntu 6.8.0-1051.54~22.04.1-aws-64k 6.8.12",
			release:   "6.8.0-1051-aws-64k",
			want:      "6.8.0-1051.54~22.04.1\n",
		},
		{
			name:      "mismatched ABI fails closed",
			signature: "Ubuntu 6.8.0-1051.54~22.04.1-aws 6.8.12",
			release:   "6.8.0-1052-aws",
			wantError: true,
		},
		{
			name:      "unidentified build fails closed",
			signature: "Linux 6.8.0-1051-aws",
			release:   "6.8.0-1051-aws",
			wantError: true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cmd := exec.CommandContext(t.Context(), "bash", "-c",
				`source ./prepare-host-kernel-modules.sh; host_kernel_package_version "$1" "$2"`,
				"--", tt.signature, tt.release)
			output, err := cmd.CombinedOutput()
			if tt.wantError {
				require.Error(t, err, string(output))
				return
			}
			require.NoError(t, err, string(output))
			assert.Equal(t, tt.want, string(output))
		})
	}
}

func TestHostKernelArchiveSuite(t *testing.T) {
	tests := []struct {
		name      string
		version   string
		runner    string
		want      string
		wantError bool
	}{
		{name: "Jammy host on Noble runner", version: "6.8.0-1051.54~22.04.1", runner: "noble", want: "jammy\n"},
		{name: "Noble backport", version: "6.17.0-1012.12~24.04.1", runner: "noble", want: "noble\n"},
		{name: "native build", version: "6.8.0-1051.54", runner: "noble", want: "noble\n"},
		{name: "unrecognized backport fails closed", version: "6.8.0-1051.54~custom.1", runner: "noble", wantError: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cmd := exec.CommandContext(t.Context(), "bash", "-c",
				`source ./prepare-host-kernel-modules.sh; host_kernel_archive_suite "$1" "$2"`,
				"--", tt.version, tt.runner)
			output, err := cmd.CombinedOutput()
			if tt.wantError {
				require.Error(t, err, string(output))
				return
			}
			require.NoError(t, err, string(output))
			assert.Equal(t, tt.want, string(output))
		})
	}
}

func TestHostKernelArchives(t *testing.T) {
	tests := []struct {
		name         string
		architecture string
		configured   string
		want         string
		wantError    bool
	}{
		{
			name:         "the runner's mirror comes before the public archive",
			architecture: "amd64",
			configured:   "http://us-east-2.ec2.archive.ubuntu.com/ubuntu/\nhttp://security.ubuntu.com/ubuntu/\n",
			want:         "http://us-east-2.ec2.archive.ubuntu.com/ubuntu\nhttp://archive.ubuntu.com/ubuntu\n",
		},
		{
			name:         "arm64 keeps ports mirrors only",
			architecture: "arm64",
			configured:   "http://us-east-2.ec2.archive.ubuntu.com/ubuntu/\nhttp://us-east-2.ec2.ports.ubuntu.com/ubuntu-ports/\n",
			want:         "http://us-east-2.ec2.ports.ubuntu.com/ubuntu-ports\nhttp://ports.ubuntu.com/ubuntu-ports\n",
		},
		{
			name:         "no configured mirror leaves the public archive",
			architecture: "amd64",
			want:         "http://archive.ubuntu.com/ubuntu\n",
		},
		{
			name:         "the public archive is listed once and other repositories are skipped",
			architecture: "amd64",
			configured:   "http://archive.ubuntu.com/ubuntu/\nhttps://apt.releases.teleport.dev/ubuntu/\nhttps://ppa.launchpadcontent.net/example/ppa/ubuntu/\n",
			want:         "http://archive.ubuntu.com/ubuntu\n",
		},
		{
			name:         "unsupported architecture fails closed",
			architecture: "riscv64",
			wantError:    true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cmd := exec.CommandContext(t.Context(), "bash", "-c",
				`source ./prepare-host-kernel-modules.sh; host_kernel_archives "$1" "$2"`,
				"--", tt.architecture, tt.configured)
			output, err := cmd.CombinedOutput()
			if tt.wantError {
				require.Error(t, err, string(output))
				return
			}
			require.NoError(t, err, string(output))
			assert.Equal(t, tt.want, string(output))
		})
	}
}
