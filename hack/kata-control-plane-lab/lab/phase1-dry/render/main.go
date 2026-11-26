// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// Lab helper, not part of NVKE. It calls the kubeadm renderer of the NVKE controller, so that the
// lab sends the configuration and the files that the controller sends. The renderer is an internal
// package, so render.sh adds this file to the controller module as internal/labrender with the
// -overlay flag of go. The clone stays unchanged.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/dsx-ai-factory/nvke/controller/internal/kubeadmconfig"
)

// main writes the kubeadm configuration, one file for each prerequisite file, and files.txt
// (node path, local name, mode, owner) to the folder LAB_OUT.
// LAB_MODE=init (default): kubeadm-init.yaml from InitConfig.Render, as activities/kubeadm_init.go:105-133.
// LAB_MODE=join: kubeadm-join.yaml from NewJoinConfigFromString and JoinConfig.Render, as
// activities/kubeadm_join.go:119-141. The join string comes from the file LAB_JOIN_STRING_FILE.
func main() {
	out := os.Getenv("LAB_OUT")
	var artifacts *kubeadmconfig.BootstrapArtifacts
	var err error
	name := "kubeadm-init.yaml"
	if os.Getenv("LAB_MODE") == "join" {
		name = "kubeadm-join.yaml"
		joinString, readErr := os.ReadFile(os.Getenv("LAB_JOIN_STRING_FILE"))
		check(readErr)
		cfg, cfgErr := kubeadmconfig.NewJoinConfigFromString(os.Getenv("LAB_NODE_IP"), os.Getenv("LAB_NODE_NAME"), string(joinString))
		check(cfgErr)
		cfg.KubeadmContainerMode = os.Getenv("LAB_CONTAINER_MODE") == "true"
		cfg.KubernetesVersion = os.Getenv("LAB_K8S_VERSION")
		cfg.SystemReservedMemory = os.Getenv("LAB_SYSTEM_RESERVED_MEMORY")
		cfg.KubeReservedMemory = os.Getenv("LAB_KUBE_RESERVED_MEMORY")
		artifacts, err = cfg.Render()
	} else {
		cfg := &kubeadmconfig.InitConfig{
			NodeIP:                os.Getenv("LAB_NODE_IP"),
			APIServerEndpoint:     os.Getenv("LAB_ENDPOINT"),
			NodeName:              os.Getenv("LAB_NODE_NAME"),
			KubernetesVersion:     os.Getenv("LAB_K8S_VERSION"),
			PodSubnet:             os.Getenv("LAB_POD_CIDR"),
			ServiceSubnet:         os.Getenv("LAB_SERVICE_CIDR"),
			EtcdQuotaBackendBytes: kubeadmconfig.EtcdQuotaBackendBytes,
			Token:                 os.Getenv("LAB_TOKEN"),
			SkipKubeProxy:         os.Getenv("LAB_SKIP_KUBE_PROXY") == "true",
			KubeadmContainerMode:  os.Getenv("LAB_CONTAINER_MODE") == "true",
			SystemReservedMemory:  os.Getenv("LAB_SYSTEM_RESERVED_MEMORY"),
			KubeReservedMemory:    os.Getenv("LAB_KUBE_RESERVED_MEMORY"),
		}
		artifacts, err = cfg.Render()
	}
	check(err)
	check(os.WriteFile(filepath.Join(out, name), artifacts.ConfigYAML, 0o600))
	list := ""
	for _, f := range artifacts.Files {
		base := filepath.Base(f.Path)
		check(os.WriteFile(filepath.Join(out, base), f.Content, 0o600))
		list += fmt.Sprintf("%s %s %04o %s\n", f.Path, base, f.Mode, f.Owner)
	}
	check(os.WriteFile(filepath.Join(out, "files.txt"), []byte(list), 0o644))
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "labrender:", err)
		os.Exit(1)
	}
}
