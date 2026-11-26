// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"fmt"
	"os"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"sigs.k8s.io/yaml"
)

// boundMachine is one machine that holds a host.
type boundMachine struct {
	Name   string // name of the Cluster API Machine. NVKE uses the node name
	ID     string // UID of the Machine. The marker in the pod holds it
	Host   string // hostname of the host in the inventory. The host pod has it as a label
	Secret string // name of the bootstrap Secret, in the namespace of the Machine
}

// waiting is a machine that the helper cannot use yet, with the reason.
type waiting struct {
	Name   string
	Reason string
}

// source lists the machines that hold a host.
type source interface {
	list(ctx context.Context) ([]boundMachine, []waiting, error)
}

// The kind of the provisioned provider
// (cluster-api-provider-provisioned/api/v1alpha1/groupversion_info.go:26-32).
var provisionedMachineResource = schema.GroupVersionResource{
	Group:    "infrastructure.cluster.x-k8s.io",
	Version:  "v1alpha1",
	Resource: "provisionedmachines",
}

const machineGroup = "cluster.x-k8s.io"

// provisionedSource reads the ProvisionedMachines of one namespace.
type provisionedSource struct {
	client    dynamic.Interface
	namespace string
}

func (s *provisionedSource) list(ctx context.Context) ([]boundMachine, []waiting, error) {
	items, err := s.client.Resource(provisionedMachineResource).Namespace(s.namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, nil, fmt.Errorf("list ProvisionedMachines in %s: %w", s.namespace, err)
	}
	var bound []boundMachine
	var wait []waiting
	for i := range items.Items {
		item := &items.Items[i]
		machine, reason, err := s.boundMachineOf(ctx, item)
		if err != nil {
			return nil, nil, err
		}
		if reason != "" {
			wait = append(wait, waiting{Name: item.GetName(), Reason: reason})
			continue
		}
		bound = append(bound, machine)
	}
	return bound, wait, nil
}

// boundMachineOf reads what the helper needs from one ProvisionedMachine and its owner.
// The provider sets status.hostName and status.initialization.provisioned when the machine
// holds a host (cluster-api-provider-provisioned/controllers/machine_controller.go:492-509).
func (s *provisionedSource) boundMachineOf(ctx context.Context, item *unstructured.Unstructured) (boundMachine, string, error) {
	if item.GetDeletionTimestamp() != nil {
		return boundMachine{}, "the ProvisionedMachine is in deletion", nil
	}
	host, _, _ := unstructured.NestedString(item.Object, "status", "hostName")
	provisioned, _, _ := unstructured.NestedBool(item.Object, "status", "initialization", "provisioned")
	if host == "" || !provisioned {
		return boundMachine{}, "the ProvisionedMachine holds no host yet", nil
	}

	var owner *metav1.OwnerReference
	for _, reference := range item.GetOwnerReferences() {
		groupVersion, err := schema.ParseGroupVersion(reference.APIVersion)
		if err == nil && groupVersion.Group == machineGroup && reference.Kind == "Machine" {
			owner = &reference
			break
		}
	}
	if owner == nil {
		return boundMachine{}, "the ProvisionedMachine has no owner Machine yet", nil
	}
	groupVersion, _ := schema.ParseGroupVersion(owner.APIVersion)
	machine, err := s.client.Resource(groupVersion.WithResource("machines")).Namespace(s.namespace).Get(ctx, owner.Name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return boundMachine{}, "the owner Machine " + owner.Name + " does not exist", nil
	}
	if err != nil {
		return boundMachine{}, "", fmt.Errorf("get Machine %s/%s: %w", s.namespace, owner.Name, err)
	}
	if machine.GetUID() != owner.UID {
		return boundMachine{}, "the owner Machine " + owner.Name + " has another UID", nil
	}
	secret, _, _ := unstructured.NestedString(machine.Object, "spec", "bootstrap", "dataSecretName")
	if secret == "" {
		return boundMachine{}, "the Machine " + owner.Name + " has no spec.bootstrap.dataSecretName", nil
	}
	return boundMachine{Name: machine.GetName(), ID: string(machine.GetUID()), Host: host, Secret: secret}, "", nil
}

// staticSource reads the machines from a file. It is the input for a test with no
// Cluster API objects: the copy into the pod is the same.
//
//	machines:
//	  - name: node-1          # a name for the log
//	    id: test-1            # optional, the default is "static/<name>"
//	    host: host-1          # the value of the host label of the pod
//	    secret: node-1-bootstrap-data
type staticSource struct {
	path string
}

type staticFile struct {
	Machines []struct {
		Name   string `json:"name"`
		ID     string `json:"id"`
		Host   string `json:"host"`
		Secret string `json:"secret"`
	} `json:"machines"`
}

func (s *staticSource) list(context.Context) ([]boundMachine, []waiting, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, nil, fmt.Errorf("read the static file: %w", err)
	}
	var content staticFile
	if err := yaml.Unmarshal(data, &content); err != nil {
		return nil, nil, fmt.Errorf("parse the static file %s: %w", s.path, err)
	}
	var bound []boundMachine
	for _, entry := range content.Machines {
		if entry.Name == "" || entry.Host == "" || entry.Secret == "" {
			return nil, nil, fmt.Errorf("the static file %s has an entry with no name, host or secret", s.path)
		}
		id := entry.ID
		if id == "" {
			id = "static/" + entry.Name
		}
		bound = append(bound, boundMachine{Name: entry.Name, ID: id, Host: entry.Host, Secret: entry.Secret})
	}
	return bound, nil, nil
}
