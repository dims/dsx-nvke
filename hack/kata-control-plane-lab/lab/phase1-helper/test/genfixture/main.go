// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// genfixture writes test user data in the exact form of the NVKE controller.
//
// The types, the YAML marshal code and the template are copies from the NVKE source at
// commit bcc4376f: controller/internal/clients/capi/bootstrap_userdata.go:24-66,150-163
// and controller/internal/clients/capi/capi_spire_agent.conf.tmpl. The values are fake:
// the join token is not a token of a SPIRE server, and the trust bundle is not a certificate.
//
// For each form it writes <form>.userdata.yaml (the value of the Secret key "value") and
// <form>.expected (one line for each file: sha256, mode, owner, path).
package main

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"text/template"

	"gopkg.in/yaml.v3"
)

//go:embed capi_spire_agent.conf.tmpl
var spireAgentConfigTemplateText string

type cloudInitConfig struct {
	WriteFiles []cloudInitFile `yaml:"write_files,omitempty"`
	RunCmd     []string        `yaml:"runcmd,omitempty"`
}

type cloudInitFile struct {
	Path        string `yaml:"path"`
	Owner       string `yaml:"owner,omitempty"`
	Permissions string `yaml:"permissions,omitempty"`
	Encoding    string `yaml:"encoding,omitempty"`
	Content     string `yaml:"content"`
}

func (f cloudInitFile) MarshalYAML() (interface{}, error) {
	node := &yaml.Node{Kind: yaml.MappingNode}
	appendMappingNode(node, "path", 0, f.Path, "")
	if f.Owner != "" {
		appendMappingNode(node, "owner", 0, f.Owner, "")
	}
	if f.Permissions != "" {
		appendMappingNode(node, "permissions", yaml.DoubleQuotedStyle, f.Permissions, "!!str")
	}
	if f.Encoding != "" {
		appendMappingNode(node, "encoding", 0, f.Encoding, "")
	}
	contentStyle := yaml.LiteralStyle
	if f.Encoding != "" {
		contentStyle = 0
	}
	appendMappingNode(node, "content", contentStyle, f.Content, "")
	return node, nil
}

func appendMappingNode(node *yaml.Node, key string, style yaml.Style, value, tag string) {
	valueNode := &yaml.Node{Kind: yaml.ScalarNode, Style: style, Value: value}
	if tag != "" {
		valueNode.Tag = tag
	}
	node.Content = append(node.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Value: key},
		valueNode,
	)
}

type spireAgentConfig struct {
	ServerAddress         string
	ServerPort            string
	TrustDomain           string
	TrustBundlePath       string
	SpireJoinToken        string
	AttestationMethod     string
	DSXIMDSEndpoint       string
	DSXIMDSPluginChecksum string
}

const (
	trustBundlePath = "/etc/spire-agent/initial-trust-bundle.pem" // constants.CAPISpireTrustBundlePath
	agentConfigPath = "/etc/spire-agent/agent.conf"               // constants.CAPISpireAgentConfigPath
	// The names for a node with no reported agent version (nodecontract.go:43-51).
	oldEnvFilePath = "/etc/default/nke-agent"
	oldUnitName    = "nke-agent.service"

	fakeJoinToken   = "11111111-2222-4333-8444-fake00000000"
	fakeTrustBundle = "-----BEGIN CERTIFICATE-----\nVGhpcyBpcyBub3QgYSBjZXJ0aWZpY2F0ZS4gSXQgaXMgdGVzdCBkYXRhIG9mIHRo\nZSBib290c3RyYXAgaGVscGVyLg==\n-----END CERTIFICATE-----\n"
	counterFile     = "/var/lib/nico-containers/helper-test/runcmd.count"
)

// render is renderBootstrapUserData for a node with SPIFFE on and the method joinToken.
// callerFiles and preKubeadmCommands are the bootstrapFiles and preKubeadmCommands of a
// cluster request. controllerFiles are the files of nodeAgentBootstrapFiles
// (controller/internal/temporal/activities/activities.go:64-91).
func render(callerFiles, controllerFiles []cloudInitFile, preKubeadmCommands []string) ([]cloudInitFile, string) {
	var agentConf bytes.Buffer
	tmpl := template.Must(template.New("capi-spire-agent-config").Parse(spireAgentConfigTemplateText))
	if err := tmpl.Execute(&agentConf, spireAgentConfig{
		AttestationMethod: "joinToken",
		ServerAddress:     "192.0.2.1", // TEST-NET-1: no host has it
		ServerPort:        "30081",
		TrustDomain:       "helper-test.invalid",
		TrustBundlePath:   trustBundlePath,
		SpireJoinToken:    fakeJoinToken,
	}); err != nil {
		log.Fatal(err)
	}

	files := append([]cloudInitFile(nil), callerFiles...)
	files = append(files,
		cloudInitFile{Path: trustBundlePath, Owner: "root:root", Permissions: "0644", Content: fakeTrustBundle},
		cloudInitFile{Path: agentConfigPath, Owner: "root:root", Permissions: "0644", Content: agentConf.String()},
	)
	files = append(files, controllerFiles...)

	runCommands := append([]string(nil), preKubeadmCommands...)
	runCommands = append(runCommands, "systemctl restart "+oldUnitName)

	yamlBytes, err := yaml.Marshal(cloudInitConfig{WriteFiles: files, RunCmd: runCommands})
	if err != nil {
		log.Fatal(err)
	}
	return files, "#cloud-config\n" + string(yamlBytes)
}

func main() {
	out := flag.String("out", "fixtures", "output folder")
	flag.Parse()
	if err := os.MkdirAll(*out, 0o755); err != nil {
		log.Fatal(err)
	}

	envFile := cloudInitFile{
		Path: oldEnvFilePath, Owner: "root:root", Permissions: "0644",
		Content: fmt.Sprintf("AGENT_ARGS=%q\n", strings.Join([]string{"--secure-server-port", "15005"}, " ")),
	}
	count := "mkdir -p " + filepath.Dir(counterFile) + " && echo ran >> " + counterFile

	forms := map[string]struct {
		callerFiles     []cloudInitFile
		controllerFiles []cloudInitFile
		commands        []string
	}{
		// What NVKE renders for the lab: no caller file, no caller command.
		"lab": {controllerFiles: []cloudInitFile{envFile}},
		// The lab form with a counter, to prove that the commands run one time.
		"count": {controllerFiles: []cloudInitFile{envFile}, commands: []string{count}},
		// Each feature of the format: caller files with other modes and owners, a base64
		// file as the controller CA of external mTLS, and caller commands with quotes.
		"full": {
			callerFiles: []cloudInitFile{
				{Path: "/etc/nvke-helper-test/custom.conf", Owner: "root:root", Permissions: "0600", Content: "hello"},
				{Path: "/etc/nvke-helper-test/sub dir/it's.conf", Owner: "etcd:etcd", Permissions: "0640", Content: "line 1\nline 2 with a $VAR and a 'quote'\n"},
			},
			controllerFiles: []cloudInitFile{
				{Path: "/etc/nke/controller-ca.crt", Owner: "root:root", Permissions: "0644", Encoding: "b64",
					Content: base64.StdEncoding.EncodeToString([]byte(fakeTrustBundle))},
				envFile,
			},
			commands: []string{count, "echo \"it's a 'quoted' command\""},
		},
		// A command in the middle fails. The command after it must not run.
		"fail": {
			controllerFiles: []cloudInitFile{envFile},
			commands:        []string{count, "echo this command fails >&2; exit 3", count},
		},
	}

	for name, form := range forms {
		files, userData := render(form.callerFiles, form.controllerFiles, form.commands)
		if err := os.WriteFile(filepath.Join(*out, name+".userdata.yaml"), []byte(userData), 0o600); err != nil {
			log.Fatal(err)
		}
		var expected strings.Builder
		for _, f := range files {
			content := []byte(f.Content)
			if f.Encoding != "" {
				decoded, err := base64.StdEncoding.DecodeString(f.Content)
				if err != nil {
					log.Fatal(err)
				}
				content = decoded
			}
			fmt.Fprintf(&expected, "%x %s %s %s\n", sha256.Sum256(content), strings.TrimPrefix(f.Permissions, "0"), f.Owner, f.Path)
		}
		if err := os.WriteFile(filepath.Join(*out, name+".expected"), []byte(expected.String()), 0o644); err != nil {
			log.Fatal(err)
		}
	}
}
