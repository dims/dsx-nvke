// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package agent

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	yaml "gopkg.in/yaml.v2"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	kubernetesfake "k8s.io/client-go/kubernetes/fake"
	sigsyaml "sigs.k8s.io/yaml"

	"github.com/dsx-ai-factory/nvke/agent/internal/k8s"
	pb "github.com/dsx-ai-factory/nvke/agent/pkg/agent/proto"
)

func TestK8sAPIEncryptionStatusConstants(t *testing.T) {
	// Verify all status constants are properly defined
	assert.Equal(t, K8sAPIEncryptionStatusType("Enabled"), K8sAPIEncryptionEnabledStatus)
	assert.Equal(t, K8sAPIEncryptionStatusType("Pending"), K8sAPIEncryptionPendingStatus)
	assert.Equal(t, K8sAPIEncryptionStatusType("Error"), K8sAPIEncryptionErrorStatus)
	assert.Equal(t, K8sAPIEncryptionStatusType("NotConfigured"), K8sAPIEncryptionNotConfigured)
}

func TestK8sAPIEncryptionPhaseConstants(t *testing.T) {
	// Verify all phase constants are properly defined
	assert.Equal(t, K8sAPIEncryptionPhaseType("Initialize"), InitializeK8sAPIEncryptionPhase)
	assert.Equal(t, K8sAPIEncryptionPhaseType("InitializeError"), InitializeK8sAPIEncryptionErrorPhase)
	assert.Equal(t, K8sAPIEncryptionPhaseType("EncryptionInitialized"), K8sAPIEncryptionInitializedPhase)
	assert.Equal(t, K8sAPIEncryptionPhaseType("Configuring"), K8sAPIEncryptionPhaseConfiguring)
	assert.Equal(t, K8sAPIEncryptionPhaseType("Configured"), K8sAPIEncryptionPhaseConfigured)
	assert.Equal(t, K8sAPIEncryptionPhaseType("RewriteObjects"), RewriteObjectsEncryptionPhase)
	assert.Equal(t, K8sAPIEncryptionPhaseType("RewriteObjectsError"), RewriteObjectsErrorEncryptionPhase)
	assert.Equal(t, K8sAPIEncryptionPhaseType("ObjectsRewritten"), ObjectsRewrittenEncryptionPhase)
	assert.Equal(t, K8sAPIEncryptionPhaseType("RestartAPIServer"), RestartAPIServerEncryptionPhase)
	assert.Equal(t, K8sAPIEncryptionPhaseType("RestartAPIServerError"), RestartAPIServerErrorEncryptionPhase)
	assert.Equal(t, K8sAPIEncryptionPhaseType("RestartedAPIServer"), RestartedAPIServerEncryptionPhase)
}

func TestAPIEncryptionLabels(t *testing.T) {
	// Verify label constants are properly formatted
	assert.Equal(t, "nvke.nvidia.com/k8s-api-encryption-configured=true", APIEncryptionConfiguredLabel)
	assert.Equal(t, "nvke.nvidia.com/k8s-api-encryption-rewrite-complete=true", APIEncryptionRewriteCompleteLabel)
	assert.Equal(t, "nvke.nvidia.com/k8s-api-encryption-enabled=true", APIEncryptionEnabledLabel)
	assert.Equal(t, "nvke.nvidia.com/k8s-api-encryption-secondary-key-configured=true", APIEncryptionSecondaryKeyEnabledLabel)
}

func TestObjectsToEncrypt(t *testing.T) {
	// Verify the objects to encrypt list contains expected items
	expectedObjects := []string{
		"secrets",
		"configmaps",
		"persistentvolumeclaims",
		"persistentvolumes",
		"serviceaccounts",
		"events",
		"services",
	}

	assert.Equal(t, len(expectedObjects), len(objectsToEncrypt))
	for _, obj := range expectedObjects {
		assert.Contains(t, objectsToEncrypt, obj)
	}
}

func TestEncryptionConfigTemplateContainsRequiredFields(t *testing.T) {
	// Verify the encryption config template contains required fields
	assert.Contains(t, encryptionConfigTemplate, "apiVersion: apiserver.config.k8s.io/v1")
	assert.Contains(t, encryptionConfigTemplate, "kind: EncryptionConfiguration")
	assert.Contains(t, encryptionConfigTemplate, "resources:")
	assert.Contains(t, encryptionConfigTemplate, "providers:")
	assert.Contains(t, encryptionConfigTemplate, "secretbox:")
	assert.Contains(t, encryptionConfigTemplate, "keys:")
	assert.Contains(t, encryptionConfigTemplate, "{{ .EncryptionKey }}")
	assert.Contains(t, encryptionConfigTemplate, "{{- range .ObjectsToEncrypt }}")
	// identity: {} must be present as a fallback provider so the apiserver can
	// read existing plaintext data before the rewrite step encrypts it.
	assert.Contains(t, encryptionConfigTemplate, "- identity: {}")
}

func TestEncryptionConfigTemplateExistingClusterContainsRequiredFields(t *testing.T) {
	assert.Contains(t, encryptionConfigTemplateExistingCluster, "apiVersion: apiserver.config.k8s.io/v1")
	assert.Contains(t, encryptionConfigTemplateExistingCluster, "kind: EncryptionConfiguration")
	assert.Contains(t, encryptionConfigTemplateExistingCluster, "providers:")
	assert.Contains(t, encryptionConfigTemplateExistingCluster, "- identity: {}")
	assert.Contains(t, encryptionConfigTemplateExistingCluster, "secretbox:")
	assert.Contains(t, encryptionConfigTemplateExistingCluster, "{{ .EncryptionKey }}")
}

func TestVolumeEntryFormat(t *testing.T) {
	// Verify volume entry has correct format
	assert.Contains(t, volumeEntry, "hostPath:")
	assert.Contains(t, volumeEntry, "path: /etc/kubernetes/kube-api-encryption")
	assert.Contains(t, volumeEntry, "type: DirectoryOrCreate")
	assert.Contains(t, volumeEntry, "name: encryption-config")
}

func TestVolumeMountsEntryFormat(t *testing.T) {
	// Verify volume mounts entry has correct format
	assert.Contains(t, volumeMountsEntry, "mountPath: /etc/kubernetes/kube-api-encryption")
	assert.Contains(t, volumeMountsEntry, "name: encryption-config")
	assert.Contains(t, volumeMountsEntry, "readOnly: true")
}

func TestCreateAPIEncryptionConfig(t *testing.T) {
	tests := []struct {
		name          string
		encryptionKey string
		expectError   bool
	}{
		{
			name:          "successful config creation",
			encryptionKey: "dGVzdC1lbmNyeXB0aW9uLWtleS1iYXNlNjQ=",
			expectError:   false,
		},
		{
			name:          "empty encryption key",
			encryptionKey: "",
			expectError:   false, // Empty key is technically allowed at this level
		},
		{
			name:          "special characters in key",
			encryptionKey: "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=",
			expectError:   false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create a temp directory to use as chroot
			tmpDir := t.TempDir()

			server := &NodeAgentServer{
				Runner:     NewMockK8sEncryptionRunner(),
				Persister:  &MockPersister{},
				NodeStatus: &NodeStatus{},
				RootPath:   tmpDir, // Use temp dir as chroot
			}

			// Call the actual function
			err := server.createAPIEncryptionConfig(tc.encryptionKey, false, nil)

			if tc.expectError {
				assert.Error(t, err)
				return
			}

			assert.NoError(t, err)

			// Verify the directory was created
			encryptionDir := filepath.Join(tmpDir, "etc/kubernetes/kube-api-encryption")
			_, err = os.Stat(encryptionDir)
			assert.NoError(t, err, "encryption directory should exist")

			// Verify the config file was created
			configPath := filepath.Join(encryptionDir, "encryption-config.yaml")
			content, err := os.ReadFile(configPath)
			assert.NoError(t, err, "config file should be readable")

			// Verify content contains expected elements
			contentStr := string(content)
			assert.Contains(t, contentStr, "apiVersion: apiserver.config.k8s.io/v1")
			assert.Contains(t, contentStr, "kind: EncryptionConfiguration")
			assert.Contains(t, contentStr, "secretbox:")
			assert.Contains(t, contentStr, "current-primary-encryption-key")
			assert.Contains(t, contentStr, tc.encryptionKey)

			// Verify all objects to encrypt are present
			for _, obj := range objectsToEncrypt {
				assert.Contains(t, contentStr, obj, "config should contain object: %s", obj)
			}
		})
	}
}

func TestCreateAPIEncryptionConfig_ExistingClusterProviderOrder(t *testing.T) {
	tmpDir := t.TempDir()
	srv := &NodeAgentServer{RootPath: tmpDir}
	key := "dGVzdC1lbmNyeXB0aW9uLWtleS1iYXNlNjQ="
	err := srv.createAPIEncryptionConfig(key, true, nil)
	require.NoError(t, err)
	b, err := os.ReadFile(filepath.Join(tmpDir, "etc/kubernetes/kube-api-encryption/encryption-config.yaml"))
	require.NoError(t, err)
	var cfg EncryptionConfiguration
	require.NoError(t, yaml.Unmarshal(b, &cfg))
	assert.True(t, cfg.IdentityPrimarySecretboxSecondary())
	assert.NoError(t, cfg.ValidateSecretbox())
}

func TestInitializeKubernetesAPIEncryptionNotControlPlane(t *testing.T) {
	mockRunner := NewMockK8sEncryptionRunner()

	server := &NodeAgentServer{
		Runner:    mockRunner,
		Persister: &MockPersister{},
		NodeStatus: &NodeStatus{
			Role: WorkerRole, // Not control plane
		},
	}

	req := &pb.InitializeKubernetesAPIEncryptionRequest{
		EncryptionKey: "test-key",
	}

	resp, err := server.InitializeKubernetesAPIEncryption(context.Background(), req)

	assert.Error(t, err)
	assert.Contains(t, err.Error(), "controlplane")
	assert.NotEmpty(t, resp.ErrorMessage)
	assert.Equal(t, K8sAPIEncryptionErrorStatus, server.NodeStatus.K8sAPIEncryption.Status)
}

func TestGetPodStatus(t *testing.T) {
	tests := []struct {
		name           string
		podName        string
		mockOutput     []byte
		mockError      error
		expectedStatus string
		expectError    bool
	}{
		{
			name:           "pod is running",
			podName:        "kube-apiserver-node1",
			mockOutput:     []byte("Running"),
			mockError:      nil,
			expectedStatus: "Running",
			expectError:    false,
		},
		{
			name:           "pod is pending",
			podName:        "kube-apiserver-node1",
			mockOutput:     []byte("Pending"),
			mockError:      nil,
			expectedStatus: "Pending",
			expectError:    false,
		},
		{
			name:           "kubectl fails",
			podName:        "kube-apiserver-node1",
			mockOutput:     []byte(""),
			mockError:      errors.New("pod not found"),
			expectedStatus: "",
			expectError:    true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			mockRunner := NewMockK8sEncryptionRunner()
			mockRunner.Outputs["kubectl"] = tc.mockOutput
			mockRunner.Errors["kubectl"] = tc.mockError

			server := &NodeAgentServer{
				Runner:     mockRunner,
				Persister:  &MockPersister{},
				NodeStatus: &NodeStatus{},
			}

			status, err := server.getPodStatus(tc.podName)

			if tc.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tc.expectedStatus, status)
			}
		})
	}
}

func TestApiServerPodIsRunning(t *testing.T) {
	tests := []struct {
		name        string
		mockOutput  []byte
		mockError   error
		expected    bool
		expectError bool
	}{
		{
			name:        "api server is running",
			mockOutput:  []byte("Running"),
			mockError:   nil,
			expected:    true,
			expectError: false,
		},
		{
			name:        "api server is not running",
			mockOutput:  []byte("Pending"),
			mockError:   nil,
			expected:    false,
			expectError: false,
		},
		{
			name:        "error checking status",
			mockOutput:  []byte(""),
			mockError:   errors.New("kubectl error"),
			expected:    false,
			expectError: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			mockRunner := NewMockK8sEncryptionRunner()
			mockRunner.Outputs["kubectl"] = tc.mockOutput
			mockRunner.Errors["kubectl"] = tc.mockError

			server := &NodeAgentServer{
				Runner:     mockRunner,
				Persister:  &MockPersister{},
				NodeStatus: &NodeStatus{},
			}

			result, err := server.apiServerPodIsRunning()

			if tc.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tc.expected, result)
			}
		})
	}
}

func TestVerifyNodeAPIEncryptionEnabled(t *testing.T) {
	tests := []struct {
		name        string
		mockOutput  []byte
		mockError   error
		expected    bool
		expectError bool
	}{
		{
			name:        "encryption is enabled",
			mockOutput:  []byte("... --encryption-provider-config=/etc/kubernetes/... ..."),
			mockError:   nil,
			expected:    true,
			expectError: false,
		},
		{
			name:        "encryption is not enabled",
			mockOutput:  []byte("... --other-flag=value ..."),
			mockError:   nil,
			expected:    false,
			expectError: false,
		},
		{
			name:        "kubectl fails",
			mockOutput:  []byte(""),
			mockError:   errors.New("kubectl error"),
			expected:    false,
			expectError: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			mockRunner := NewMockK8sEncryptionRunner()
			mockRunner.Outputs["kubectl"] = tc.mockOutput
			mockRunner.Errors["kubectl"] = tc.mockError

			server := &NodeAgentServer{
				Runner:     mockRunner,
				Persister:  &MockPersister{},
				NodeStatus: &NodeStatus{},
			}

			result, err := server.verifyNodeAPIEncryptionEnabled()

			if tc.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tc.expected, result)
			}
		})
	}
}

func TestEncryptionConfigurationStructs(t *testing.T) {
	// Test that the encryption configuration structs can be properly marshaled/unmarshaled
	config := EncryptionConfiguration{
		ApiVersion: "apiserver.config.k8s.io/v1",
		Kind:       "EncryptionConfiguration",
		Resources: []ResourceConfig{
			{
				Resources: []string{"secrets", "configmaps"},
				Providers: []ProviderConfig{
					{
						Secretbox: &SecretboxConfig{
							Keys: []KeyConfig{
								{Name: "key1", Secret: "base64secret"},
							},
						},
					},
					{
						Identity: &IdentityConfig{},
					},
				},
			},
		},
	}

	assert.Equal(t, "apiserver.config.k8s.io/v1", config.ApiVersion)
	assert.Equal(t, "EncryptionConfiguration", config.Kind)
	assert.Len(t, config.Resources, 1)
	assert.Len(t, config.Resources[0].Resources, 2)
	assert.Len(t, config.Resources[0].Providers, 2)
	assert.NotNil(t, config.Resources[0].Providers[0].Secretbox)
	assert.NotNil(t, config.Resources[0].Providers[1].Identity)

	// Regression: marshaled YAML must not contain a top-level "providerConfig" field.
	// Kubernetes strict-decodes the config and will reject unknown fields, causing:
	// "strict decoding error: unknown field \"providerConfig\""
	yamlBytes, err := yaml.Marshal(config)
	assert.NoError(t, err)
	assert.NotContains(t, string(yamlBytes), "providerConfig")
}

func TestModifyAPIServerManifest(t *testing.T) {
	mockRunner := NewMockK8sEncryptionRunner()
	mockRunner.Outputs["bash"] = []byte("")
	mockRunner.Errors["bash"] = nil

	server := &NodeAgentServer{
		Runner:     mockRunner,
		Persister:  &MockPersister{},
		NodeStatus: &NodeStatus{},
	}

	err := server.modifyAPIServerManifest()
	assert.NoError(t, err)

	// Verify bash was called twice (for encryption-provider-config and automatic-reload)
	bashCalls := 0
	for _, call := range mockRunner.CalledWith {
		if len(call) > 0 && call[0] == "bash" {
			bashCalls++
		}
	}
	assert.Equal(t, 2, bashCalls)
}

func TestCreateVolumeMountEntries(t *testing.T) {
	mockRunner := NewMockK8sEncryptionRunner()
	mockRunner.Outputs["bash"] = []byte("")
	mockRunner.Errors["bash"] = nil

	server := &NodeAgentServer{
		Runner:     mockRunner,
		Persister:  &MockPersister{},
		NodeStatus: &NodeStatus{},
	}

	err := server.createVolumeMountEntries()
	assert.NoError(t, err)

	// Verify bash was called twice (for volume and volumeMounts)
	bashCalls := 0
	for _, call := range mockRunner.CalledWith {
		if len(call) > 0 && call[0] == "bash" {
			bashCalls++
		}
	}
	assert.Equal(t, 2, bashCalls)
}

func TestRestartAPIServer(t *testing.T) {
	tests := []struct {
		name        string
		mockError   error
		expectError bool
	}{
		{
			name:        "successful restart",
			mockError:   nil,
			expectError: false,
		},
		{
			name:        "kubectl delete fails",
			mockError:   errors.New("delete failed"),
			expectError: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			mockRunner := NewMockK8sEncryptionRunner()
			mockRunner.Outputs["kubectl"] = []byte("")
			mockRunner.Errors["kubectl"] = tc.mockError

			server := &NodeAgentServer{
				Runner:     mockRunner,
				Persister:  &MockPersister{},
				NodeStatus: &NodeStatus{},
			}

			err := server.restartAPIServer()

			if tc.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func writeMigrationEncryptionConfigFixture(t *testing.T, dir, keySecret string) {
	t.Helper()
	encDir := filepath.Join(dir, "etc/kubernetes/kube-api-encryption")
	require.NoError(t, os.MkdirAll(encDir, 0o755))
	cfg := EncryptionConfiguration{
		ApiVersion: "apiserver.config.k8s.io/v1",
		Kind:       "EncryptionConfiguration",
		Resources: []ResourceConfig{{
			Resources: []string{"secrets"},
			Providers: []ProviderConfig{
				{Identity: &IdentityConfig{}},
				{Secretbox: &SecretboxConfig{Keys: []KeyConfig{{Name: "current-primary-encryption-key", Secret: keySecret}}}},
			},
		}},
	}
	b, err := yaml.Marshal(cfg)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(encDir, "encryption-config.yaml"), b, 0o600))
}

func TestPromoteKubernetesAPIEncryptionProviders_success(t *testing.T) {
	tmpDir := t.TempDir()
	writeMigrationEncryptionConfigFixture(t, tmpDir, testKey1)
	srv := newEncryptionServer(t, tmpDir, ControlPlaneRole, NewMockK8sEncryptionRunner(), metricsWithBlockingWaitPath(0))
	_, err := srv.PromoteKubernetesAPIEncryptionProviders(context.Background(), &pb.PromoteKubernetesAPIEncryptionProvidersRequest{})
	require.NoError(t, err)
	cfg, err := srv.readEncryptionConfig()
	require.NoError(t, err)
	assert.True(t, cfg.SecretboxPrimaryIdentitySecondary())
}

func TestPromoteKubernetesAPIEncryptionProviders_idempotentAlreadyPromoted(t *testing.T) {
	tmpDir := t.TempDir()
	writeEncryptionConfigFixture(t, tmpDir, []KeyConfig{{Name: "current-primary-encryption-key", Secret: testKey1}})
	srv := newEncryptionServer(t, tmpDir, ControlPlaneRole, NewMockK8sEncryptionRunner(), metricsWithCount(0))
	_, err := srv.PromoteKubernetesAPIEncryptionProviders(context.Background(), &pb.PromoteKubernetesAPIEncryptionProvidersRequest{})
	require.NoError(t, err)
}

func TestPromoteKubernetesAPIEncryptionProviders_notControlPlane(t *testing.T) {
	srv := &NodeAgentServer{
		NodeStatus:     &NodeStatus{Role: WorkerRole},
		clientRegistry: newMetricsRegistry(t, metricsWithCount(0)),
	}
	_, err := srv.PromoteKubernetesAPIEncryptionProviders(context.Background(), &pb.PromoteKubernetesAPIEncryptionProvidersRequest{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "controlplane")
}

func TestPromoteKubernetesAPIEncryptionProviders_noClientRegistry(t *testing.T) {
	tmpDir := t.TempDir()
	writeMigrationEncryptionConfigFixture(t, tmpDir, testKey1)
	srv := &NodeAgentServer{
		RootPath:   tmpDir,
		NodeStatus: &NodeStatus{Role: ControlPlaneRole},
	}
	_, err := srv.PromoteKubernetesAPIEncryptionProviders(context.Background(), &pb.PromoteKubernetesAPIEncryptionProvidersRequest{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "metrics")
}

func TestPromoteKubernetesAPIEncryptionProviders_unexpectedLayout(t *testing.T) {
	tmpDir := t.TempDir()
	encDir := filepath.Join(tmpDir, "etc/kubernetes/kube-api-encryption")
	require.NoError(t, os.MkdirAll(encDir, 0o755))
	cfg := EncryptionConfiguration{
		ApiVersion: "apiserver.config.k8s.io/v1",
		Kind:       "EncryptionConfiguration",
		Resources: []ResourceConfig{{
			Resources: []string{"secrets"},
			Providers: []ProviderConfig{
				{Secretbox: &SecretboxConfig{Keys: []KeyConfig{{Name: "k", Secret: testKey1}}}},
			},
		}},
	}
	b, err := yaml.Marshal(cfg)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(encDir, "encryption-config.yaml"), b, 0o600))
	srv := newEncryptionServer(t, tmpDir, ControlPlaneRole, NewMockK8sEncryptionRunner(), metricsWithCount(0))
	_, err = srv.PromoteKubernetesAPIEncryptionProviders(context.Background(), &pb.PromoteKubernetesAPIEncryptionProvidersRequest{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "migration state")
}

// kubeadmClusterConfigurationV1beta4 returns a ClusterConfiguration in the form that kubeadm 1.36
// stores in the kubeadm-config ConfigMap, with the given apiServer section.
func kubeadmClusterConfigurationV1beta4(apiServer string) string {
	return apiServer + `apiVersion: kubeadm.k8s.io/v1beta4
caCertificateValidityPeriod: 87600h0m0s
certificateValidityPeriod: 8760h0m0s
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controlPlaneEndpoint: cluster.local:6443
controllerManager:
  extraArgs:
  - name: bind-address
    value: 127.0.0.1
  - name: profiling
    value: "false"
dns: {}
encryptionAlgorithm: RSA-2048
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
    - name: quota-backend-bytes
      value: "17179869184"
imageRepository: registry.k8s.io
kind: ClusterConfiguration
kubernetesVersion: v1.36.4
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
proxy: {}
scheduler:
  extraArgs:
  - name: profiling
    value: "false"
`
}

// The apiServer section that the NVKE controller renders into the kubeadm ClusterConfiguration, in
// parts. The parts with "Encryption" are what a cluster created with encryption has in addition.
const (
	apiServerArgs = `apiServer:
  extraArgs:
  - name: audit-policy-file
    value: /etc/kubernetes/policies/audit-policy.yaml
  - name: authentication-config
    value: /etc/kubernetes/oidc/auth-config.yaml
  - name: enable-admission-plugins
    value: NodeRestriction,DenyServiceExternalIPs
  - name: profiling
    value: "false"
`
	apiServerVolumes = `  extraVolumes:
  - hostPath: /var/log/kubernetes_audit
    mountPath: /var/log/kubernetes_audit
    name: audit-logs
    pathType: DirectoryOrCreate
  - hostPath: /etc/kubernetes/policies
    mountPath: /etc/kubernetes/policies
    name: audit-policies
    pathType: DirectoryOrCreate
    readOnly: true
  - hostPath: /etc/kubernetes/oidc
    mountPath: /etc/kubernetes/oidc
    name: oidc-auth-config
    pathType: DirectoryOrCreate
    readOnly: true
`
	apiServerEncryptionArgs = `  - name: encryption-provider-config
    value: /etc/kubernetes/kube-api-encryption/encryption-config.yaml
  - name: encryption-provider-config-automatic-reload
    value: "true"
`
	apiServerEncryptionVolume = `  - hostPath: /etc/kubernetes/kube-api-encryption
    mountPath: /etc/kubernetes/kube-api-encryption
    name: enc
    pathType: DirectoryOrCreate
    readOnly: true
`

	// A cluster created without encryption.
	apiServerWithoutEncryption = apiServerArgs + apiServerVolumes

	// The same cluster after encryption is turned on: the agent adds its entries at the end of each list.
	apiServerEncryptedLater = apiServerArgs + apiServerEncryptionArgs + apiServerVolumes + apiServerEncryptionVolume

	// An API server that has no other settings than encryption.
	apiServerOnlyEncryption = "apiServer:\n  extraArgs:\n" + apiServerEncryptionArgs + "  extraVolumes:\n" + apiServerEncryptionVolume

	// A cluster created with encryption, in the order that the controller renders.
	apiServerCreatedWithEncryption = `apiServer:
  extraArgs:
  - name: audit-policy-file
    value: /etc/kubernetes/policies/audit-policy.yaml
  - name: authentication-config
    value: /etc/kubernetes/oidc/auth-config.yaml
  - name: enable-admission-plugins
    value: NodeRestriction,DenyServiceExternalIPs
  - name: encryption-provider-config
    value: /etc/kubernetes/kube-api-encryption/encryption-config.yaml
  - name: encryption-provider-config-automatic-reload
    value: "true"
  - name: profiling
    value: "false"
  extraVolumes:
  - hostPath: /var/log/kubernetes_audit
    mountPath: /var/log/kubernetes_audit
    name: audit-logs
    pathType: DirectoryOrCreate
  - hostPath: /etc/kubernetes/policies
    mountPath: /etc/kubernetes/policies
    name: audit-policies
    pathType: DirectoryOrCreate
    readOnly: true
  - hostPath: /etc/kubernetes/kube-api-encryption
    mountPath: /etc/kubernetes/kube-api-encryption
    name: enc
    pathType: DirectoryOrCreate
    readOnly: true
  - hostPath: /etc/kubernetes/oidc
    mountPath: /etc/kubernetes/oidc
    name: oidc-auth-config
    pathType: DirectoryOrCreate
    readOnly: true
`
)

func parseClusterConfiguration(t *testing.T, document string) map[string]any {
	t.Helper()
	var parsed map[string]any
	require.NoError(t, sigsyaml.Unmarshal([]byte(document), &parsed))
	return parsed
}

func updateKubeadmConfigForTest(t *testing.T, data map[string]string) (*kubernetesfake.Clientset, error) {
	t.Helper()
	var objects []runtime.Object
	if data != nil {
		objects = append(objects, &v1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Namespace: kubeSystemNamespace, Name: kubeadmConfigMapName},
			Data:       data,
		})
	}
	clientset := kubernetesfake.NewSimpleClientset(objects...)
	k8s.SetClientsetForTest(clientset)
	t.Cleanup(func() { k8s.SetClientsetForTest(nil) })

	server := &NodeAgentServer{
		Runner:     NewMockK8sEncryptionRunner(),
		Persister:  &MockPersister{},
		NodeStatus: &NodeStatus{Role: ControlPlaneRole, IsMaster: true},
	}
	return clientset, server.updateEncryptionEntryForKubeadmConfigMap()
}

func storedClusterConfiguration(t *testing.T, clientset *kubernetesfake.Clientset) string {
	t.Helper()
	cm, err := clientset.CoreV1().ConfigMaps(kubeSystemNamespace).Get(context.Background(), kubeadmConfigMapName, metav1.GetOptions{})
	require.NoError(t, err)
	return cm.Data["ClusterConfiguration"]
}

func TestUpdateEncryptionEntryForKubeadmConfigMap(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "cluster created without encryption keeps every API server setting and gains the flags and the directory volume",
			input: kubeadmClusterConfigurationV1beta4(apiServerWithoutEncryption),
			want:  kubeadmClusterConfigurationV1beta4(apiServerEncryptedLater),
		},
		{
			name:  "cluster created with encryption stays as the controller rendered it",
			input: kubeadmClusterConfigurationV1beta4(apiServerCreatedWithEncryption),
			want:  kubeadmClusterConfigurationV1beta4(apiServerCreatedWithEncryption),
		},
		{
			name: "volume for the file that nothing creates, written by an earlier agent, is removed",
			input: kubeadmClusterConfigurationV1beta4(`apiServer:
  extraArgs:
  - name: encryption-provider-config
    value: /etc/kubernetes/kube-api-encryption/encryption-config.yaml
  - name: encryption-provider-config-automatic-reload
    value: "true"
  extraVolumes:
  - hostPath: /etc/kubernetes/encryption-config.yaml
    mountPath: /etc/kubernetes/encryption-config.yaml
    name: encryption-config
    pathType: File
    readOnly: true
  - hostPath: /etc/kubernetes/kube-api-encryption
    mountPath: /etc/kubernetes/kube-api-encryption
    name: enc
    pathType: DirectoryOrCreate
    readOnly: true
`),
			want: kubeadmClusterConfigurationV1beta4(apiServerOnlyEncryption),
		},
		{
			name: "volume named encryption-config on another host path is kept",
			input: kubeadmClusterConfigurationV1beta4(`apiServer:
  extraVolumes:
  - hostPath: /srv/operator/encryption
    mountPath: /srv/operator/encryption
    name: encryption-config
    pathType: Directory
`),
			want: kubeadmClusterConfigurationV1beta4(`apiServer:
  extraArgs:
  - name: encryption-provider-config
    value: /etc/kubernetes/kube-api-encryption/encryption-config.yaml
  - name: encryption-provider-config-automatic-reload
    value: "true"
  extraVolumes:
  - hostPath: /srv/operator/encryption
    mountPath: /srv/operator/encryption
    name: encryption-config
    pathType: Directory
  - hostPath: /etc/kubernetes/kube-api-encryption
    mountPath: /etc/kubernetes/kube-api-encryption
    name: enc
    pathType: DirectoryOrCreate
    readOnly: true
`),
		},
		{
			name: "encryption flag and volume with other values are replaced, not doubled",
			input: kubeadmClusterConfigurationV1beta4(`apiServer:
  extraArgs:
  - name: encryption-provider-config
    value: /etc/kubernetes/encryption-config.yaml
  - name: profiling
    value: "false"
  extraVolumes:
  - hostPath: /etc/kubernetes/other
    mountPath: /etc/kubernetes/other
    name: enc
    pathType: Directory
`),
			want: kubeadmClusterConfigurationV1beta4(`apiServer:
  extraArgs:
  - name: encryption-provider-config
    value: /etc/kubernetes/kube-api-encryption/encryption-config.yaml
  - name: profiling
    value: "false"
  - name: encryption-provider-config-automatic-reload
    value: "true"
  extraVolumes:
  - hostPath: /etc/kubernetes/kube-api-encryption
    mountPath: /etc/kubernetes/kube-api-encryption
    name: enc
    pathType: DirectoryOrCreate
    readOnly: true
`),
		},
		{
			name: "API server settings other than flags and volumes are kept",
			input: kubeadmClusterConfigurationV1beta4(`apiServer:
  certSANs:
  - api.example.com
  extraEnvs:
  - name: GOMAXPROCS
    value: "8"
`),
			want: kubeadmClusterConfigurationV1beta4(`apiServer:
  certSANs:
  - api.example.com
  extraEnvs:
  - name: GOMAXPROCS
    value: "8"
` + strings.TrimPrefix(apiServerOnlyEncryption, "apiServer:\n")),
		},
		{
			name:  "empty apiServer section gets the flags and the volume",
			input: kubeadmClusterConfigurationV1beta4("apiServer: {}\n"),
			want:  kubeadmClusterConfigurationV1beta4(apiServerOnlyEncryption),
		},
		{
			name:  "missing apiServer section gets the flags and the volume",
			input: kubeadmClusterConfigurationV1beta4(""),
			want:  kubeadmClusterConfigurationV1beta4(apiServerOnlyEncryption),
		},
		{
			name: "v1beta3 cluster gets the flags in the map form",
			input: `apiServer:
  extraArgs:
    audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
    profiling: "false"
  extraVolumes:
  - hostPath: /etc/kubernetes/policies
    mountPath: /etc/kubernetes/policies
    name: audit-policies
    pathType: DirectoryOrCreate
    readOnly: true
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
controllerManager:
  extraArgs:
    profiling: "false"
kind: ClusterConfiguration
kubernetesVersion: v1.30.4
`,
			want: `apiServer:
  extraArgs:
    audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
    encryption-provider-config: /etc/kubernetes/kube-api-encryption/encryption-config.yaml
    encryption-provider-config-automatic-reload: "true"
    profiling: "false"
  extraVolumes:
  - hostPath: /etc/kubernetes/policies
    mountPath: /etc/kubernetes/policies
    name: audit-policies
    pathType: DirectoryOrCreate
    readOnly: true
  - hostPath: /etc/kubernetes/kube-api-encryption
    mountPath: /etc/kubernetes/kube-api-encryption
    name: enc
    pathType: DirectoryOrCreate
    readOnly: true
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
controllerManager:
  extraArgs:
    profiling: "false"
kind: ClusterConfiguration
kubernetesVersion: v1.30.4
`,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			clientset, err := updateKubeadmConfigForTest(t, map[string]string{"ClusterConfiguration": tc.input})
			require.NoError(t, err)

			got := storedClusterConfiguration(t, clientset)
			assert.Equal(t, parseClusterConfiguration(t, tc.want), parseClusterConfiguration(t, got))
			assert.NotContains(t, got, "/etc/kubernetes/encryption-config.yaml", "no volume or flag may name the file that nothing creates")
		})
	}
}

// A control-plane node that joins later builds its kube-apiserver manifest from kubeadm-config, so
// a cluster that gets encryption later must hold the same API server settings as a cluster created
// with encryption. Only the order of the entries may differ.
func TestUpdateEncryptionEntryForKubeadmConfigMapMatchesClusterCreatedWithEncryption(t *testing.T) {
	clientset, err := updateKubeadmConfigForTest(t, map[string]string{
		"ClusterConfiguration": kubeadmClusterConfigurationV1beta4(apiServerWithoutEncryption),
	})
	require.NoError(t, err)

	got := parseClusterConfiguration(t, storedClusterConfiguration(t, clientset))
	want := parseClusterConfiguration(t, kubeadmClusterConfigurationV1beta4(apiServerCreatedWithEncryption))

	apiServerList := func(config map[string]any, field string) []any {
		t.Helper()
		apiServer, ok := config["apiServer"].(map[string]any)
		require.True(t, ok, "apiServer section")
		list, ok := apiServer[field].([]any)
		require.True(t, ok, "apiServer.%s list", field)
		return list
	}
	assert.ElementsMatch(t, apiServerList(want, "extraArgs"), apiServerList(got, "extraArgs"))
	assert.ElementsMatch(t, apiServerList(want, "extraVolumes"), apiServerList(got, "extraVolumes"))

	delete(got, "apiServer")
	delete(want, "apiServer")
	assert.Equal(t, want, got, "settings outside the apiServer section")
}

func TestUpdateEncryptionEntryForKubeadmConfigMapRejectsUnknownShapes(t *testing.T) {
	unknownVersion := strings.Replace(kubeadmClusterConfigurationV1beta4(apiServerWithoutEncryption), "v1beta4", "v1beta9", 1)
	tests := []struct {
		name    string
		data    map[string]string
		wantErr string
	}{
		{
			name:    "missing kubeadm-config ConfigMap",
			data:    nil,
			wantErr: "not found",
		},
		{
			name:    "ConfigMap without a ClusterConfiguration",
			data:    map[string]string{},
			wantErr: "unsupported kubeadm ClusterConfiguration apiVersion",
		},
		{
			name:    "ClusterConfiguration of an unknown kubeadm API version",
			data:    map[string]string{"ClusterConfiguration": unknownVersion},
			wantErr: `unsupported kubeadm ClusterConfiguration apiVersion "kubeadm.k8s.io/v1beta9"`,
		},
		{
			name: "v1beta4 ClusterConfiguration with extraArgs in the v1beta3 map form",
			data: map[string]string{"ClusterConfiguration": kubeadmClusterConfigurationV1beta4(`apiServer:
  extraArgs:
    profiling: "false"
`)},
			wantErr: `field "extraArgs" has unexpected type`,
		},
		{
			name: "ClusterConfiguration with extraVolumes that is not a list",
			data: map[string]string{"ClusterConfiguration": kubeadmClusterConfigurationV1beta4(`apiServer:
  extraVolumes:
    name: audit-logs
`)},
			wantErr: `field "extraVolumes" has unexpected type`,
		},
		{
			name:    "ClusterConfiguration that is not YAML",
			data:    map[string]string{"ClusterConfiguration": "apiServer: [unclosed"},
			wantErr: "parsing kubeadm ClusterConfiguration",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			clientset, err := updateKubeadmConfigForTest(t, tc.data)
			require.ErrorContains(t, err, tc.wantErr)

			for _, action := range clientset.Actions() {
				assert.NotEqual(t, "update", action.GetVerb(), "a ClusterConfiguration of an unknown shape must not be rewritten")
			}
		})
	}
}
