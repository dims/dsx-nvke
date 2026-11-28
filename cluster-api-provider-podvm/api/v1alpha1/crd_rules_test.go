// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"k8s.io/apiextensions-apiserver/pkg/apis/apiextensions"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	crdvalidation "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/validation"
	structuralschema "k8s.io/apiextensions-apiserver/pkg/apiserver/schema"
	schemacel "k8s.io/apiextensions-apiserver/pkg/apiserver/schema/cel"
	structuraldefaulting "k8s.io/apiextensions-apiserver/pkg/apiserver/schema/defaulting"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/util/json"
	celconfig "k8s.io/apiserver/pkg/apis/cel"
	"sigs.k8s.io/yaml"
)

// These tests run the rules of the generated CRDs about a change of an object.
// The rules are CEL expressions that only the API server evaluates, so a test
// with a fake client cannot see them. The tests use the validators of the API
// server: they check that the API server accepts the CRD itself, they fill in
// the defaults, and they run the rules on an old and a new object.

const crdDirectory = "../../config/crd/bases/infrastructure.cluster.x-k8s.io_"

// crdRules holds the schema of one generated CRD and the validator of its
// rules.
type crdRules struct {
	structural *structuralschema.Structural
	validator  *schemacel.Validator
}

func loadCRDRules(t *testing.T, resource string) crdRules {
	t.Helper()
	data, err := os.ReadFile(crdDirectory + resource + ".yaml")
	require.NoError(t, err)
	var crd apiextensionsv1.CustomResourceDefinition
	require.NoError(t, yaml.UnmarshalStrict(data, &crd))
	apiextensionsv1.SetDefaults_CustomResourceDefinition(&crd)

	var internal apiextensions.CustomResourceDefinition
	require.NoError(t, apiextensionsv1.Convert_v1_CustomResourceDefinition_To_apiextensions_CustomResourceDefinition(&crd, &internal, nil))
	// The API server refuses a CRD with a rule that does not compile or that
	// can cost too much.
	require.Empty(t, crdvalidation.ValidateCustomResourceDefinition(context.Background(), &internal))

	validation := internal.Spec.Validation
	if validation == nil {
		require.Len(t, internal.Spec.Versions, 1)
		validation = internal.Spec.Versions[0].Schema
	}
	structural, err := structuralschema.NewStructural(validation.OpenAPIV3Schema)
	require.NoError(t, err)
	return crdRules{
		structural: structural,
		validator:  schemacel.NewValidator(structural, true, celconfig.PerCallLimit),
	}
}

// update returns what the rules say against a change of an object from old to
// changed, as one text.
func (r crdRules) update(t *testing.T, old, changed map[string]any) string {
	t.Helper()
	structuraldefaulting.Default(old, r.structural)
	structuraldefaulting.Default(changed, r.structural)
	errs, _ := r.validator.Validate(context.Background(), nil, r.structural, changed, old, celconfig.RuntimeCELCostBudget)
	messages := make([]string, 0, len(errs))
	for _, err := range errs {
		messages = append(messages, err.Error())
	}
	text := strings.Join(messages, "\n")
	// A rule that cannot run on the object is a fault of the test, and its
	// text also names the rule.
	require.NotContains(t, text, "evaluating rule")
	return text
}

// specOf returns the spec of an object, so that a test can change it.
func specOf(t *testing.T, object map[string]any) map[string]any {
	t.Helper()
	spec, ok := object["spec"].(map[string]any)
	require.True(t, ok, "the object has no spec")
	return spec
}

// parseObject reads an object the way the API server does: a whole number is
// an int64, which the rules need.
func parseObject(t *testing.T, text string) map[string]any {
	t.Helper()
	data, err := yaml.YAMLToJSON([]byte(text))
	require.NoError(t, err)
	object := map[string]any{}
	require.NoError(t, json.Unmarshal(data, &object))
	return object
}

// ruleCase changes the spec of an object and names the rule that must refuse
// the change. An empty refusal means that the API server takes the change.
type ruleCase struct {
	name    string
	change  func(spec map[string]any)
	refusal string
}

func runRuleCases(t *testing.T, resource, base string, cases []ruleCase) {
	t.Helper()
	rules := loadCRDRules(t, resource)
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			changed := parseObject(t, base)
			test.change(specOf(t, changed))

			got := rules.update(t, parseObject(t, base), changed)
			if test.refusal == "" {
				require.Empty(t, got)
				return
			}
			require.Contains(t, got, test.refusal)
		})
	}
}

const clusterObject = `
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: PodVMCluster
metadata:
  name: example
  namespace: nvke-system
spec:
  podNamespace: example-pods
  runtimeClassName: kata
  networkAttachment:
    name: nodenet
  addressRange:
    cidr: 198.51.100.64/26
    prefixLength: 24
  failureDomainLabelKey: topology.kubernetes.io/zone
  controlPlaneService:
    annotations:
      lb.example.com/address: 203.0.113.10
`

func TestPodVMClusterRulesAboutAChange(t *testing.T) {
	runRuleCases(t, "podvmclusters", clusterObject, []ruleCase{
		{name: "no change", change: func(map[string]any) {}},
		{
			name:    "another pod namespace",
			change:  func(spec map[string]any) { spec["podNamespace"] = "other-pods" },
			refusal: "podNamespace is immutable",
		},
		{
			name:    "another runtime class",
			change:  func(spec map[string]any) { spec["runtimeClassName"] = "kata-other" },
			refusal: "runtimeClassName is immutable",
		},
		{
			name:    "another network attachment",
			change:  func(spec map[string]any) { spec["networkAttachment"] = map[string]any{"name": "othernet"} },
			refusal: "networkAttachment is immutable",
		},
		{
			name: "the same network attachment name in another namespace",
			change: func(spec map[string]any) {
				spec["networkAttachment"] = map[string]any{"name": "nodenet", "namespace": "networks"}
			},
			refusal: "networkAttachment is immutable",
		},
		{
			name: "another address block",
			change: func(spec map[string]any) {
				spec["addressRange"] = map[string]any{"cidr": "198.51.100.128/26", "prefixLength": int64(24)}
			},
			refusal: "addressRange is immutable",
		},
		{
			name: "another prefix length of the node network",
			change: func(spec map[string]any) {
				spec["addressRange"] = map[string]any{"cidr": "198.51.100.64/26", "prefixLength": int64(16)}
			},
			refusal: "addressRange is immutable",
		},
		{
			name: "another annotation of the control plane Service",
			change: func(spec map[string]any) {
				spec["controlPlaneService"] = map[string]any{
					"annotations": map[string]any{"lb.example.com/address": "203.0.113.11"},
				}
			},
			refusal: "controlPlaneService is immutable",
		},
		{
			name:    "the control plane Service removed",
			change:  func(spec map[string]any) { delete(spec, "controlPlaneService") },
			refusal: "controlPlaneService cannot be added or removed",
		},
	})
}

func TestPodVMClusterRuleRefusesAControlPlaneServiceThatIsAdded(t *testing.T) {
	rules := loadCRDRules(t, "podvmclusters")
	old := parseObject(t, clusterObject)
	delete(specOf(t, old), "controlPlaneService")

	require.Contains(t, rules.update(t, old, parseObject(t, clusterObject)), "controlPlaneService cannot be added or removed")
}

const machineObject = `
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: PodVMMachine
metadata:
  name: example-cp-1
  namespace: nvke-system
spec:
  providerID: podvm://example-pods/example-cp-1
  image: registry.example.com/nvke/podvm-node:1.36.3
  resources:
    cpu: "4"
    memory: 8Gi
  volumes:
    var:
      storageClassName: block-storage
      size: 40Gi
    etcd:
      storageClassName: block-storage
      size: 10Gi
`

func TestPodVMMachineRulesAboutAChange(t *testing.T) {
	runRuleCases(t, "podvmmachines", machineObject, []ruleCase{
		{name: "no change", change: func(map[string]any) {}},
		{
			name:    "another image",
			change:  func(spec map[string]any) { spec["image"] = "registry.example.com/nvke/podvm-node:1.37.0" },
			refusal: "image is immutable",
		},
		{
			name: "another size",
			change: func(spec map[string]any) {
				spec["resources"] = map[string]any{"cpu": "8", "memory": "8Gi"}
			},
			refusal: "resources is immutable",
		},
		{
			name: "another volume size",
			change: func(spec map[string]any) {
				spec["volumes"] = map[string]any{
					"var":  map[string]any{"storageClassName": "block-storage", "size": "80Gi"},
					"etcd": map[string]any{"storageClassName": "block-storage", "size": "10Gi"},
				}
			},
			refusal: "volumes is immutable",
		},
		{
			name:    "another provider ID",
			change:  func(spec map[string]any) { spec["providerID"] = "podvm://example-pods/other" },
			refusal: "providerID is immutable once set",
		},
		{
			name:    "the provider ID removed",
			change:  func(spec map[string]any) { delete(spec, "providerID") },
			refusal: "providerID is immutable once set",
		},
		{
			name:   "another pull policy, which does not change what the node is",
			change: func(spec map[string]any) { spec["imagePullPolicy"] = "Always" },
		},
	})
}

// The provider sets the provider ID one time, on a machine that has none.
func TestPodVMMachineRuleTakesTheFirstProviderID(t *testing.T) {
	rules := loadCRDRules(t, "podvmmachines")
	old := parseObject(t, machineObject)
	delete(specOf(t, old), "providerID")

	require.Empty(t, rules.update(t, old, parseObject(t, machineObject)))
}

// A template has no rule about its image, its size and its volumes. The
// Cluster API contract asks a template that refuses a change for an exception
// for a dry run, and a rule of a CRD cannot make one.
func TestPodVMMachineTemplateTakesAChange(t *testing.T) {
	const templateObject = `
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: PodVMMachineTemplate
metadata:
  name: example-control-plane
  namespace: nvke-system
spec:
  template:
    spec:
      image: registry.example.com/nvke/podvm-node:1.36.3
      resources: {cpu: "4", memory: 8Gi}
      volumes:
        var: {storageClassName: block-storage, size: 40Gi}
        etcd: {storageClassName: block-storage, size: 10Gi}
`
	rules := loadCRDRules(t, "podvmmachinetemplates")
	changed := parseObject(t, templateObject)
	require.NoError(t, unstructured.SetNestedField(changed,
		"registry.example.com/nvke/podvm-node:1.37.0", "spec", "template", "spec", "image"))

	require.Empty(t, rules.update(t, parseObject(t, templateObject), changed))
}
