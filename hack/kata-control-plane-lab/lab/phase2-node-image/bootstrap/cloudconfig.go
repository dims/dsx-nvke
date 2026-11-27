// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"sigs.k8s.io/yaml"
)

// cloudConfig is the part of a cloud-config that NVKE renders into the Secret
// "<node>-bootstrap-data" (controller/internal/clients/capi/bootstrap_userdata.go:24-35).
// nico-sim reads the same two keys (controller/nico-sim/internal/container/docker.go:28-39).
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

// permissions accepts the quoted form that NVKE writes ("0644") and the bare
// form of a hand-made file (0644, which YAML 1.1 reads as the number 420).
type permissions string

func (p *permissions) UnmarshalJSON(data []byte) error {
	var text string
	if err := json.Unmarshal(data, &text); err == nil {
		*p = permissions(strings.TrimSpace(text))
		return nil
	}
	var number int64
	if err := json.Unmarshal(data, &number); err != nil {
		return fmt.Errorf("permissions must be a string or a number: %s", string(data))
	}
	*p = permissions("0" + strconv.FormatInt(number, 8))
	return nil
}

// file is one write_files entry after the checks, with the content decoded.
type file struct {
	Path    string
	Mode    string
	Owner   string
	Content []byte
}

const (
	defaultMode  = "0644"      // the default of cloud-init for write_files
	defaultOwner = "root:root" // the default of cloud-init for write_files
)

var (
	modePattern  = regexp.MustCompile(`^[0-7]{3,4}$`)
	ownerPattern = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?$`)
)

// parseCloudConfig reads the user data of a bootstrap Secret. It returns the
// files in the order of the Secret and the commands with no empty entry.
func parseCloudConfig(userData []byte) ([]file, []string, error) {
	var cfg cloudConfig
	if text := strings.TrimSpace(string(userData)); text != "" {
		// The first line "#cloud-config" is a YAML comment.
		if err := yaml.Unmarshal([]byte(text), &cfg); err != nil {
			return nil, nil, fmt.Errorf("parse cloud-config: %w", err)
		}
	}

	files := make([]file, 0, len(cfg.WriteFiles))
	for _, entry := range cfg.WriteFiles {
		path := strings.TrimSpace(entry.Path)
		if path == "" {
			continue // nico-sim skips an entry with no path
		}
		if !strings.HasPrefix(path, "/") || strings.ContainsAny(path, "\n\x00") {
			return nil, nil, fmt.Errorf("write_files path %q is not an absolute path", path)
		}
		content, err := decodeContent(entry)
		if err != nil {
			return nil, nil, fmt.Errorf("decode %s: %w", path, err)
		}
		mode := string(entry.Permissions)
		if mode == "" {
			mode = defaultMode
		}
		if !modePattern.MatchString(mode) {
			return nil, nil, fmt.Errorf("write_files %s: permissions %q are not an octal mode", path, mode)
		}
		owner := strings.TrimSpace(entry.Owner)
		if owner == "" {
			owner = defaultOwner
		}
		if !ownerPattern.MatchString(owner) {
			return nil, nil, fmt.Errorf("write_files %s: owner %q is not user or user:group", path, owner)
		}
		files = append(files, file{Path: path, Mode: mode, Owner: owner, Content: content})
	}

	commands := make([]string, 0, len(cfg.RunCmd))
	for _, command := range cfg.RunCmd {
		if strings.TrimSpace(command) != "" {
			commands = append(commands, command)
		}
	}
	return files, commands, nil
}

// decodeContent accepts the encodings that nico-sim accepts (docker.go:223-236).
func decodeContent(entry writeFile) ([]byte, error) {
	switch entry.Encoding {
	case "":
		return []byte(entry.Content), nil
	case "b64", "base64":
		decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(entry.Content))
		if err != nil {
			return nil, fmt.Errorf("decode base64 content: %w", err)
		}
		return decoded, nil
	default:
		return nil, fmt.Errorf("unsupported cloud-config encoding %q", entry.Encoding)
	}
}
