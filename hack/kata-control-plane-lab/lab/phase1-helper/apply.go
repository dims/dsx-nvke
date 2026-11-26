// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	utilexec "k8s.io/client-go/util/exec"
)

// hostPod is the running container of one host.
type hostPod struct {
	Name        string
	UID         string
	Container   string
	ContainerID string
}

// errNotReady marks a state that the next pass can find changed: no pod yet, a pod that
// stops, a container that is not up.
var errNotReady = errors.New("not ready")

// applier finds the pod of a host and runs the apply script in it.
type applier struct {
	client         kubernetes.Interface
	restConfig     *rest.Config
	hostsNamespace string
	hostLabel      string
	container      string
	execTimeout    time.Duration
}

// findPod returns the pod that carries the host label with the given value.
func (a *applier) findPod(ctx context.Context, host string) (hostPod, error) {
	selector := labels.SelectorFromSet(labels.Set{a.hostLabel: host}).String()
	pods, err := a.client.CoreV1().Pods(a.hostsNamespace).List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return hostPod{}, fmt.Errorf("list pods with %s in %s: %w", selector, a.hostsNamespace, err)
	}
	var live []corev1.Pod
	for _, pod := range pods.Items {
		if pod.DeletionTimestamp == nil {
			live = append(live, pod)
		}
	}
	switch len(live) {
	case 0:
		return hostPod{}, fmt.Errorf("%w: no pod with the label %s in the namespace %s", errNotReady, selector, a.hostsNamespace)
	case 1:
	default:
		return hostPod{}, fmt.Errorf("%d pods have the label %s in the namespace %s, the helper needs one", len(live), selector, a.hostsNamespace)
	}

	pod := live[0]
	container := a.container
	if container == "" {
		container = pod.Spec.Containers[0].Name
	}
	for _, status := range pod.Status.ContainerStatuses {
		if status.Name != container {
			continue
		}
		if status.State.Running == nil {
			return hostPod{}, fmt.Errorf("%w: the container %s of the pod %s does not run", errNotReady, container, pod.Name)
		}
		return hostPod{Name: pod.Name, UID: string(pod.UID), Container: container, ContainerID: status.ContainerID}, nil
	}
	return hostPod{}, fmt.Errorf("%w: the pod %s has no status for the container %s", errNotReady, pod.Name, container)
}

// execResult is what the apply script reported.
type execResult struct {
	State  string // done, error or notready
	Mode   string // first or repeat
	Detail string
	Notes  []string
}

// runScript sends the script to the pod over the exec stream and waits for its end.
// The script goes through stdin. The helper logs only the RESULT and NOTE lines and
// the error stream of the script, which hold paths and counts and no file content.
func (a *applier) runScript(ctx context.Context, pod hostPod, script string) (execResult, error) {
	request := a.client.CoreV1().RESTClient().Post().
		Resource("pods").Namespace(a.hostsNamespace).Name(pod.Name).SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{
			Container: pod.Container,
			Command:   execCommand(len(script)),
			Stdin:     true,
			Stdout:    true,
			Stderr:    true,
		}, scheme.ParameterCodec)

	// SPDY needs only the verb "create" on pods/exec. A WebSocket exec also needs "get".
	executor, err := remotecommand.NewSPDYExecutor(a.restConfig, "POST", request.URL())
	if err != nil {
		return execResult{}, fmt.Errorf("prepare exec into %s: %w", pod.Name, err)
	}

	ctx, cancel := context.WithTimeout(ctx, a.execTimeout)
	defer cancel()
	var stdout, stderr bytes.Buffer
	streamErr := executor.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdin:  strings.NewReader(script),
		Stdout: &stdout,
		Stderr: &stderr,
	})

	result, found := parseResult(stdout.String())
	if found {
		return result, nil
	}
	errText := lastLines(stderr.String(), 3)
	var exitErr utilexec.CodeExitError
	if errors.As(streamErr, &exitErr) {
		return execResult{}, fmt.Errorf("the script in %s ended with exit code %d and no result: %s", pod.Name, exitErr.Code, errText)
	}
	if streamErr != nil {
		return execResult{}, fmt.Errorf("exec into %s: %w (%s)", pod.Name, streamErr, errText)
	}
	return execResult{}, fmt.Errorf("the script in %s ended with no result: %s", pod.Name, errText)
}

// parseResult reads the last RESULT line and each NOTE line of the script output.
func parseResult(output string) (execResult, bool) {
	var result execResult
	found := false
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "NOTE "):
			result.Notes = append(result.Notes, strings.TrimPrefix(line, "NOTE "))
		case strings.HasPrefix(line, "RESULT "):
			fields := strings.SplitN(strings.TrimPrefix(line, "RESULT "), " ", 3)
			if len(fields) < 2 {
				continue
			}
			result.State, result.Mode, result.Detail = fields[0], fields[1], ""
			if len(fields) == 3 {
				result.Detail = fields[2]
			}
			found = true
		}
	}
	return result, found
}

func lastLines(text string, count int) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) > count {
		lines = lines[len(lines)-count:]
	}
	return strings.Join(lines, " | ")
}
