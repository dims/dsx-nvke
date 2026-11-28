// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	storagev1 "k8s.io/api/storage/v1"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/kube-openapi/pkg/validation/spec"
	"k8s.io/kube-openapi/pkg/validation/strfmt"
	"k8s.io/kube-openapi/pkg/validation/validate"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// The samples under config/samples are what a person copies first. These tests
// keep them valid against the generated CRDs and in step with each other.
//
// The check is the OpenAPI schema of the CRD, run by the validator that the
// API server uses for a custom resource, and a decode into the Go type that
// rejects an unknown field. It does not run the CEL rules of the CRDs. They
// are rules about a change of an object, and a sample is a new object.
const (
	samplesDirectory = "../config/samples"
	crdDirectory     = "../config/crd/bases"

	clusterCRD         = "infrastructure.cluster.x-k8s.io_podvmclusters.yaml"
	machineTemplateCRD = "infrastructure.cluster.x-k8s.io_podvmmachinetemplates.yaml"
)

// readJSON reads a YAML or JSON file as JSON.
func readJSON(t *testing.T, directory, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(directory, name))
	require.NoError(t, err)
	converted, err := yaml.ToJSON(data)
	require.NoError(t, err)
	return converted
}

// crdValidator builds the validator for the one version of a generated CRD.
func crdValidator(t *testing.T, crdFile string) *validate.SchemaValidator {
	t.Helper()
	var crd struct {
		Spec struct {
			Versions []struct {
				Schema struct {
					OpenAPIV3Schema spec.Schema `json:"openAPIV3Schema"`
				} `json:"schema"`
			} `json:"versions"`
		} `json:"spec"`
	}
	require.NoError(t, json.Unmarshal(readJSON(t, crdDirectory, crdFile), &crd))
	require.Len(t, crd.Spec.Versions, 1)
	schema := crd.Spec.Versions[0].Schema.OpenAPIV3Schema
	require.NotEmpty(t, schema.Properties, "the CRD %s has no schema", crdFile)
	return validate.NewSchemaValidator(&schema, nil, "", strfmt.Default)
}

// schemaErrors returns what the schema of the CRD says against an object.
func schemaErrors(t *testing.T, validator *validate.SchemaValidator, object []byte) []error {
	t.Helper()
	var content map[string]any
	require.NoError(t, json.Unmarshal(object, &content))
	return validator.Validate(content).Errors
}

// decodeStrict decodes an object into its Go type and fails on a field that
// the type does not have.
func decodeStrict(object []byte, into any) error {
	decoder := json.NewDecoder(bytes.NewReader(object))
	decoder.DisallowUnknownFields()
	return decoder.Decode(into)
}

// sampleClusterRequest is the part of an NVKE cluster request that names this
// provider.
type sampleClusterRequest struct {
	Name                 string `json:"name"`
	ControlPlaneEndpoint string `json:"controlPlaneEndpoint"`
	ControlPlaneConfig   struct {
		Infra struct {
			MachineTemplate json.RawMessage `json:"machineTemplate"`
		} `json:"infra"`
	} `json:"controlPlaneConfig"`
	Infra struct {
		Cluster json.RawMessage `json:"cluster"`
	} `json:"infra"`
}

func readSampleClusterRequest(t *testing.T) sampleClusterRequest {
	t.Helper()
	var request sampleClusterRequest
	require.NoError(t, json.Unmarshal(readJSON(t, samplesDirectory, "nvke-cluster-request.json"), &request))
	return request
}

func TestSamplesPassTheSchemaOfTheirCRD(t *testing.T) {
	request := readSampleClusterRequest(t)

	tests := []struct {
		name   string
		crd    string
		object []byte
		into   any
	}{
		{
			name:   "podvmcluster.yaml",
			crd:    clusterCRD,
			object: readJSON(t, samplesDirectory, "podvmcluster.yaml"),
			into:   &infrav1.PodVMCluster{},
		},
		{
			name:   "podvmmachinetemplate.yaml",
			crd:    machineTemplateCRD,
			object: readJSON(t, samplesDirectory, "podvmmachinetemplate.yaml"),
			into:   &infrav1.PodVMMachineTemplate{},
		},
		{
			name:   "infra.cluster of nvke-cluster-request.json",
			crd:    clusterCRD,
			object: request.Infra.Cluster,
			into:   &infrav1.PodVMCluster{},
		},
		{
			name:   "controlPlaneConfig.infra.machineTemplate of nvke-cluster-request.json",
			crd:    machineTemplateCRD,
			object: request.ControlPlaneConfig.Infra.MachineTemplate,
			into:   &infrav1.PodVMMachineTemplate{},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			require.Empty(t, schemaErrors(t, crdValidator(t, test.crd), test.object))
			require.NoError(t, decodeStrict(test.object, test.into))
		})
	}
}

// The check above proves nothing when the validator accepts everything. Each
// of these changes of the PodVMCluster sample must be rejected.
func TestSampleCheckRejectsABrokenObject(t *testing.T) {
	tests := []struct {
		name       string
		mutate     func(spec map[string]any)
		wantSchema bool
		wantDecode bool
	}{
		{
			name:       "a required field is missing",
			mutate:     func(spec map[string]any) { delete(spec, "runtimeClassName") },
			wantSchema: true,
		},
		{
			name: "a value is not in its enum",
			mutate: func(spec map[string]any) {
				spec["controlPlaneService"] = map[string]any{"externalTrafficPolicy": "Sometimes"}
			},
			wantSchema: true,
		},
		{
			name:       "a value does not match its pattern",
			mutate:     func(spec map[string]any) { spec["podNamespace"] = "Not_A_Namespace" },
			wantSchema: true,
		},
		{
			name:       "a field that the kind does not have",
			mutate:     func(spec map[string]any) { spec["controlPlaneEndpoint"] = "203.0.113.10:6443" },
			wantDecode: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var object map[string]any
			require.NoError(t, json.Unmarshal(readJSON(t, samplesDirectory, "podvmcluster.yaml"), &object))
			test.mutate(object["spec"].(map[string]any))
			broken, err := json.Marshal(object)
			require.NoError(t, err)

			require.Equal(t, test.wantSchema, len(schemaErrors(t, crdValidator(t, clusterCRD), broken)) > 0)
			require.Equal(t, test.wantDecode, decodeStrict(broken, &infrav1.PodVMCluster{}) != nil)
		})
	}
}

// A person uses the samples together, so they must name each other.
func TestSamplesFitTogether(t *testing.T) {
	infraCluster := &infrav1.PodVMCluster{}
	require.NoError(t, decodeStrict(readJSON(t, samplesDirectory, "podvmcluster.yaml"), infraCluster))
	template := &infrav1.PodVMMachineTemplate{}
	require.NoError(t, decodeStrict(readJSON(t, samplesDirectory, "podvmmachinetemplate.yaml"), template))
	request := readSampleClusterRequest(t)

	// The request carries the two objects with the same spec.
	requestCluster := &infrav1.PodVMCluster{}
	require.NoError(t, decodeStrict(request.Infra.Cluster, requestCluster))
	require.Equal(t, infraCluster.Spec, requestCluster.Spec)
	requestTemplate := &infrav1.PodVMMachineTemplate{}
	require.NoError(t, decodeStrict(request.ControlPlaneConfig.Infra.MachineTemplate, requestTemplate))
	require.Equal(t, template.Spec, requestTemplate.Spec)

	// The provider accepts the address range, and the name of the cluster
	// gives a valid name for the control plane Service.
	_, err := parseAddressRange(infraCluster.Spec.AddressRange)
	require.NoError(t, err)
	require.Equal(t, infraCluster.Name, request.Name)
	require.Empty(t, validation.IsDNS1035Label(request.Name+controlPlaneServiceSuffix))

	// The endpoint of the request is the address that the Service asks the
	// load balancer for, with the port of the Service.
	require.NotNil(t, infraCluster.Spec.ControlPlaneService)
	host, port, err := net.SplitHostPort(request.ControlPlaneEndpoint)
	require.NoError(t, err)
	require.Contains(t, infraCluster.Spec.ControlPlaneService.Annotations, "metallb.io/loadBalancerIPs")
	require.Equal(t, infraCluster.Spec.ControlPlaneService.Annotations["metallb.io/loadBalancerIPs"], host)
	require.Equal(t, "6443", port)

	// The storage class is the one that both volumes of the template name, and
	// it binds a volume when the pod has a host node.
	class := &storagev1.StorageClass{}
	require.NoError(t, decodeStrict(readJSON(t, samplesDirectory, "storageclass.yaml"), class))
	require.Equal(t, class.Name, template.Spec.Template.Spec.Volumes.Var.StorageClassName)
	require.Equal(t, class.Name, template.Spec.Template.Spec.Volumes.Etcd.StorageClassName)
	require.NotNil(t, class.VolumeBindingMode)
	require.Equal(t, storagev1.VolumeBindingWaitForFirstConsumer, *class.VolumeBindingMode)

	// The network attachment is the one that the cluster names, and it takes
	// the address and the hardware address from the annotation of the pod.
	var attachment struct {
		Metadata struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
		} `json:"metadata"`
		Spec struct {
			Config string `json:"config"`
		} `json:"spec"`
	}
	require.NoError(t, json.Unmarshal(readJSON(t, samplesDirectory, "networkattachmentdefinition.yaml"), &attachment))
	require.Equal(t, infraCluster.Spec.NetworkAttachment.Name, attachment.Metadata.Name)
	require.Equal(t, infraCluster.NetworkAttachmentNamespace(), attachment.Metadata.Namespace)

	var config struct {
		Plugins []struct {
			Capabilities map[string]bool `json:"capabilities"`
			IPAM         struct {
				Type string `json:"type"`
			} `json:"ipam"`
		} `json:"plugins"`
	}
	require.NoError(t, json.Unmarshal([]byte(attachment.Spec.Config), &config))
	require.Len(t, config.Plugins, 1)
	require.True(t, config.Plugins[0].Capabilities["ips"])
	require.True(t, config.Plugins[0].Capabilities["mac"])
	require.Equal(t, "static", config.Plugins[0].IPAM.Type)
}
