// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// nvke-lab-bootstrap-helper copies the bootstrap data of a Cluster API Machine into the pod
// that is the host of that Machine.
//
// NVKE makes the Secret "<node>-bootstrap-data" for each node, and the provisioned provider
// does not deliver it to a host. For each ProvisionedMachine that holds a host, the helper
// finds the pod with the label of that host, writes the files of the Secret into the pod,
// runs its commands one time, and writes the cloud-init status that nvke-agent reads.
// It does for a pod what applyCloudConfig of nico-sim does for a container
// (controller/nico-sim/internal/container/docker.go:136-198 in the NVKE source).
//
// The helper is a lab tool for phase 1. A PodMachine provider replaces it in phase 2.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// secretKey is the key of the user data in a bootstrap Secret
// (controller/internal/clients/shared/machine.go:159-161).
const secretKey = "value"

// outcome is the state of one machine after a pass.
type outcome int

const (
	pending outcome = iota // the next pass must look again
	applied                // the cloud-init status is "done". Nothing more to do
	failed                 // the cloud-init status is "error". Nothing more to do
)

type helper struct {
	log           *slog.Logger
	client        kubernetes.Interface
	source        source
	applier       *applier
	capiNamespace string
	stateDir      string
	waitSystemd   bool

	// handled holds the keys that need no more work, with their result. A key is the machine
	// ID, the pod UID, the container ID and the resourceVersion of the Secret. A new
	// container, a new pod or a changed Secret gives a new key, and the helper then looks
	// into the pod again.
	handled map[string]outcome
	// last holds the last log line of each machine, so that a state is logged one time.
	last map[string]string
}

func main() {
	var (
		kubeconfig     = flag.String("kubeconfig", "", "kubeconfig file. Empty: the service account of the pod")
		capiNamespace  = flag.String("capi-namespace", "nvke-system", "namespace of the ProvisionedMachines, the Machines and the bootstrap Secrets")
		hostsNamespace = flag.String("hosts-namespace", "", "namespace of the host pods (necessary)")
		hostLabel      = flag.String("host-label", "nvke.lab/host", "label of a host pod. Its value is the hostname of the host in the inventory")
		container      = flag.String("container", "", "container of the host pod. Empty: the first container")
		stateDir       = flag.String("state-dir", defaultStateDir, "folder in the pod for the cloud-init status and the marker of the helper")
		interval       = flag.Duration("interval", 5*time.Second, "time between two passes")
		execTimeout    = flag.Duration("exec-timeout", 5*time.Minute, "longest time for the files and commands of one machine")
		staticFile     = flag.String("static-file", "", "test input: a file that lists machine, host and Secret. The helper then reads no ProvisionedMachine")
		waitSystemd    = flag.Bool("wait-systemd", true, "change nothing in a pod while its systemd is not up")
		once           = flag.Bool("once", false, "make one pass and stop. Exit code 1: a machine still needs work. Exit code 3: a machine has the status error")
	)
	flag.Parse()
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))

	if *hostsNamespace == "" {
		logger.Error("the flag --hosts-namespace is necessary")
		os.Exit(2)
	}
	restConfig, err := loadConfig(*kubeconfig)
	if err != nil {
		logger.Error("no Kubernetes configuration", "err", err)
		os.Exit(2)
	}
	client, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		logger.Error("no Kubernetes client", "err", err)
		os.Exit(2)
	}

	var machines source
	if *staticFile != "" {
		machines = &staticSource{path: *staticFile}
	} else {
		dynamicClient, err := dynamic.NewForConfig(restConfig)
		if err != nil {
			logger.Error("no dynamic Kubernetes client", "err", err)
			os.Exit(2)
		}
		machines = &provisionedSource{client: dynamicClient, namespace: *capiNamespace}
	}

	h := &helper{
		log:    logger,
		client: client,
		source: machines,
		applier: &applier{
			client:         client,
			restConfig:     restConfig,
			hostsNamespace: *hostsNamespace,
			hostLabel:      *hostLabel,
			container:      *container,
			execTimeout:    *execTimeout,
		},
		capiNamespace: *capiNamespace,
		stateDir:      *stateDir,
		waitSystemd:   *waitSystemd,
		handled:       map[string]outcome{},
		last:          map[string]string{},
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	logger.Info("start", "capiNamespace", *capiNamespace, "hostsNamespace", *hostsNamespace, "hostLabel", *hostLabel,
		"staticFile", *staticFile, "interval", interval.String())

	for {
		pendingCount, failedCount := h.pass(ctx)
		if *once {
			switch {
			case pendingCount > 0:
				os.Exit(1)
			case failedCount > 0:
				os.Exit(3)
			}
			return
		}
		select {
		case <-ctx.Done():
			logger.Info("stop")
			return
		case <-time.After(*interval):
		}
	}
}

func loadConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig != "" {
		return clientcmd.BuildConfigFromFlags("", kubeconfig)
	}
	return rest.InClusterConfig()
}

// pass looks at each machine one time. It returns the number of machines that still need
// work and the number of machines with the status "error".
func (h *helper) pass(ctx context.Context) (pendingCount, failedCount int) {
	bound, wait, err := h.source.list(ctx)
	if err != nil {
		h.report("", slog.LevelWarn, "cannot list the machines", "err", err.Error())
		return 1, 0
	}
	h.report("", slog.LevelInfo, "machines", "bound", len(bound), "notBound", len(wait))
	for _, w := range wait {
		h.report(w.Name, slog.LevelInfo, "wait", "machine", w.Name, "reason", w.Reason)
	}

	seen := map[string]bool{}
	for _, machine := range bound {
		key, result := h.handle(ctx, machine)
		if key != "" {
			seen[key] = true
		}
		switch result {
		case pending:
			pendingCount++
		case failed:
			failedCount++
		}
	}
	for key := range h.handled {
		if !seen[key] {
			delete(h.handled, key)
		}
	}
	return pendingCount, failedCount
}

// handle does the work for one machine. It returns the key of the state that it saw and
// the result for that state.
func (h *helper) handle(ctx context.Context, machine boundMachine) (string, outcome) {
	attrs := []any{"machine", machine.Name, "host", machine.Host}

	pod, err := h.applier.findPod(ctx, machine.Host)
	if err != nil {
		level := slog.LevelWarn
		if errors.Is(err, errNotReady) {
			level = slog.LevelInfo
		}
		h.report(machine.Name, level, "wait for the host pod", append(attrs, "reason", err.Error())...)
		return "", pending
	}
	attrs = append(attrs, "pod", pod.Name)

	secret, err := h.client.CoreV1().Secrets(h.capiNamespace).Get(ctx, machine.Secret, metav1.GetOptions{})
	if err != nil {
		h.report(machine.Name, slog.LevelWarn, "cannot read the bootstrap Secret", append(attrs, "secret", machine.Secret, "err", err.Error())...)
		return "", pending
	}
	key := strings.Join([]string{machine.ID, pod.UID, pod.ContainerID, secret.ResourceVersion}, "|")
	if result, ok := h.handled[key]; ok {
		return key, result
	}

	userData, ok := secret.Data[secretKey]
	if !ok {
		h.report(machine.Name, slog.LevelError, "the bootstrap Secret has no key \""+secretKey+"\"", append(attrs, "secret", machine.Secret)...)
		return key, pending
	}
	files, commands, err := parseCloudConfig(userData)
	if err != nil {
		// The error text of the parser can quote the document, so it is not logged.
		h.report(machine.Name, slog.LevelError, "the bootstrap Secret is not a cloud-config that the helper can use",
			append(attrs, "secret", machine.Secret, "reason", safeParseError(err))...)
		return key, pending
	}

	script := buildApplyScript(scriptOptions{MachineID: machine.ID, StateDir: h.stateDir, WaitSystemd: h.waitSystemd}, files, commands)
	result, err := h.applier.runScript(ctx, pod, script)
	if err != nil {
		h.report(machine.Name, slog.LevelWarn, "the run in the pod gave no result, try again", append(attrs, "err", err.Error())...)
		return key, pending
	}
	for _, note := range result.Notes {
		h.log.Warn("note from the pod", append(attrs, "note", note)...)
	}
	attrs = append(attrs, "secret", machine.Secret, "files", len(files), "commands", len(commands), "run", result.Mode, "detail", result.Detail)
	switch result.State {
	case "done":
		message := "bootstrap data applied, cloud-init status is done"
		if result.Mode == "repeat" {
			message = "the commands of this machine ran before, files checked, cloud-init status is done"
		}
		h.report(machine.Name, slog.LevelInfo, message, attrs...)
		h.handled[key] = applied
		return key, applied
	case "error":
		h.report(machine.Name, slog.LevelError, "bootstrap data failed, cloud-init status is error", attrs...)
		h.handled[key] = failed
		return key, failed
	default:
		h.report(machine.Name, slog.LevelInfo, "the pod is not ready for the bootstrap data", attrs...)
		return key, pending
	}
}

// report logs a line for a machine only when it differs from the last line of that machine.
func (h *helper) report(name string, level slog.Level, message string, attrs ...any) {
	text := fmt.Sprint(level, message, attrs)
	if h.last[name] == text {
		return
	}
	h.last[name] = text
	h.log.Log(context.Background(), level, message, attrs...)
}

// safeParseError keeps the errors of the helper and hides the text of the YAML parser.
func safeParseError(err error) string {
	text := err.Error()
	if strings.HasPrefix(text, "parse cloud-config:") {
		return "the YAML text does not parse"
	}
	return text
}
