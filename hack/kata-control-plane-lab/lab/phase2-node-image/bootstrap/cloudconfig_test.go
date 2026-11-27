// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"strings"
	"testing"
)

// These two tests are copies from helper_test.go of the lab bootstrap helper (phase 1, step 4).

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
