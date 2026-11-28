// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

const (
	testClusterUID  = "uid-" + testClusterName
	testServiceName = testClusterName + "-control-plane"
	// An address of a documentation range, which a load balancer gives to the
	// Service in these tests.
	testServiceAddress = "192.0.2.10"
)

// newInfraClusterWithService builds a PodVMCluster that asks for a control
// plane Service and that Cluster API already owns.
func newInfraClusterWithService() *infrav1.PodVMCluster {
	infraCluster := newInfraCluster()
	infraCluster.UID = testClusterUID
	infraCluster.OwnerReferences = []metav1.OwnerReference{ownerCluster(testClusterName)}
	infraCluster.Spec.ControlPlaneService = &infrav1.ControlPlaneServiceSpec{}
	return infraCluster
}

func ownerCluster(name string) metav1.OwnerReference {
	return metav1.OwnerReference{APIVersion: clusterv1.GroupVersion.String(), Kind: "Cluster", Name: name, UID: "uid-of-the-cluster"}
}

func reconcileCluster(t *testing.T, reconciler *ClusterReconciler) ctrl.Result {
	t.Helper()
	result, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
	require.NoError(t, err)
	return result
}

// reconcileUntilTheServiceIsMade runs the two first reconciles of a cluster
// with a control plane Service: the first adds the finalizer, the second makes
// the Service.
func reconcileUntilTheServiceIsMade(t *testing.T, reconciler *ClusterReconciler) {
	t.Helper()
	require.Equal(t, ctrl.Result{RequeueAfter: retryNow}, reconcileCluster(t, reconciler))
	reconcileCluster(t, reconciler)
}

func getService(t *testing.T, k8sClient client.Client, name string) *corev1.Service {
	t.Helper()
	service := &corev1.Service{}
	require.NoError(t, k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testPodNamespace, Name: name}, service))
	return service
}

func listServices(t *testing.T, k8sClient client.Client) []corev1.Service {
	t.Helper()
	services := &corev1.ServiceList{}
	require.NoError(t, k8sClient.List(context.Background(), services))
	return services.Items
}

// giveServiceAddress plays the part of the load balancer of the host cluster:
// it writes an address to the status of the Service.
func giveServiceAddress(t *testing.T, k8sClient client.Client, ingress corev1.LoadBalancerIngress) {
	t.Helper()
	service := getService(t, k8sClient, testServiceName)
	service.Status.LoadBalancer.Ingress = []corev1.LoadBalancerIngress{ingress}
	require.NoError(t, k8sClient.Status().Update(context.Background(), service))
}

// A caller that brings its own endpoint sets no field, and nothing changes for
// it: no Service, no finalizer, provisioned at once.
func TestClusterReconcilerMakesNoServiceWithNoField(t *testing.T) {
	infraCluster := newInfraCluster()
	infraCluster.OwnerReferences = []metav1.OwnerReference{ownerCluster(testClusterName)}
	reconciler, k8sClient := newClusterReconcilerForTest(t, newPodNamespace(), infraCluster)

	require.Equal(t, ctrl.Result{}, reconcileCluster(t, reconciler))

	require.Empty(t, listServices(t, k8sClient))
	updated := getInfraCluster(t, k8sClient, testClusterName)
	require.Empty(t, updated.Finalizers)
	require.True(t, *updated.Status.Initialization.Provisioned)
	requireReadyCondition(t, updated.Status.Conditions, metav1.ConditionTrue, infrav1.ClusterSpecValidReason)
}

// The Service is the shared endpoint of the API servers. It selects the two
// labels that the machine controller puts on a control plane pod, and it
// carries what the caller gives for the load balancer.
func TestClusterReconcilerMakesTheControlPlaneService(t *testing.T) {
	tests := []struct {
		name            string
		spec            infrav1.ControlPlaneServiceSpec
		wantAnnotations map[string]string
		wantClass       *string
		wantPolicy      corev1.ServiceExternalTrafficPolicy
	}{
		{name: "no setting"},
		{
			name: "the settings of the caller",
			spec: infrav1.ControlPlaneServiceSpec{
				Annotations:           map[string]string{"lb.example.com/address": testServiceAddress},
				LoadBalancerClass:     "example.com/load-balancer",
				ExternalTrafficPolicy: corev1.ServiceExternalTrafficPolicyLocal,
			},
			wantAnnotations: map[string]string{"lb.example.com/address": testServiceAddress},
			wantClass:       ptr.To("example.com/load-balancer"),
			wantPolicy:      corev1.ServiceExternalTrafficPolicyLocal,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			infraCluster := newInfraClusterWithService()
			infraCluster.Spec.ControlPlaneService = &test.spec
			reconciler, k8sClient := newClusterReconcilerForTest(t, newPodNamespace(), infraCluster)

			// The finalizer is there before the Service.
			require.Equal(t, ctrl.Result{RequeueAfter: retryNow}, reconcileCluster(t, reconciler))
			require.Equal(t, []string{"podvm.infrastructure.cluster.x-k8s.io/cluster-cleanup"},
				getInfraCluster(t, k8sClient, testClusterName).Finalizers)
			require.Empty(t, listServices(t, k8sClient))

			reconcileCluster(t, reconciler)

			service := getService(t, k8sClient, testServiceName)
			require.Equal(t, corev1.ServiceTypeLoadBalancer, service.Spec.Type)
			require.Equal(t, map[string]string{
				"cluster.x-k8s.io/cluster-name":  testClusterName,
				"cluster.x-k8s.io/control-plane": "",
			}, service.Spec.Selector)
			require.Equal(t, []corev1.ServicePort{{
				Name: "kube-apiserver", Protocol: corev1.ProtocolTCP, Port: 6443, TargetPort: intstr.FromInt32(6443),
			}}, service.Spec.Ports)
			require.Equal(t, map[string]string{
				"cluster.x-k8s.io/cluster-name":                         testClusterName,
				"podvm.infrastructure.cluster.x-k8s.io/owner-namespace": testNamespace,
				"podvm.infrastructure.cluster.x-k8s.io/owner-name":      testClusterName,
				"podvm.infrastructure.cluster.x-k8s.io/owner-uid":       testClusterUID,
			}, service.Labels)
			require.Equal(t, test.wantAnnotations, service.Annotations)
			require.Equal(t, test.wantClass, service.Spec.LoadBalancerClass)
			require.Equal(t, test.wantPolicy, service.Spec.ExternalTrafficPolicy)
		})
	}
}

// The first node of a cluster needs the endpoint. So the cluster is not
// provisioned before the load balancer gave the Service an address, and the
// flag stays once it is reported.
func TestClusterReconcilerIsProvisionedWhenTheServiceHasAnAddress(t *testing.T) {
	tests := []struct {
		name        string
		ingress     corev1.LoadBalancerIngress
		wantAddress string
	}{
		{name: "an address", ingress: corev1.LoadBalancerIngress{IP: testServiceAddress}, wantAddress: testServiceAddress},
		{name: "a host name", ingress: corev1.LoadBalancerIngress{Hostname: "api.example.com"}, wantAddress: "api.example.com"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, k8sClient := newClusterReconcilerForTest(t,
				newPodNamespace(), newInfraClusterWithService(), newHostNode("host-a", nil))
			reconcileUntilTheServiceIsMade(t, reconciler)

			// The Service exists and has no address.
			waiting := getInfraCluster(t, k8sClient, testClusterName)
			require.Nil(t, waiting.Status.Initialization.Provisioned)
			requireReadyCondition(t, waiting.Status.Conditions, metav1.ConditionFalse, infrav1.WaitingForLoadBalancerAddressReason)

			giveServiceAddress(t, k8sClient, test.ingress)
			require.Equal(t, ctrl.Result{}, reconcileCluster(t, reconciler))

			provisioned := getInfraCluster(t, k8sClient, testClusterName)
			require.True(t, *provisioned.Status.Initialization.Provisioned)
			require.Len(t, provisioned.Status.FailureDomains, 1)
			requireReadyCondition(t, provisioned.Status.Conditions, metav1.ConditionTrue, infrav1.ClusterSpecValidReason)
			require.Contains(t, readyMessage(t, provisioned), "the control plane Service has the address "+test.wantAddress)

			// The Service is lost. The provider makes it again, and the flag
			// that Cluster API already read stays.
			require.NoError(t, k8sClient.Delete(context.Background(), getService(t, k8sClient, testServiceName)))
			reconcileCluster(t, reconciler)

			after := getInfraCluster(t, k8sClient, testClusterName)
			require.True(t, *after.Status.Initialization.Provisioned)
			requireReadyCondition(t, after.Status.Conditions, metav1.ConditionFalse, infrav1.WaitingForLoadBalancerAddressReason)
			require.Empty(t, getService(t, k8sClient, testServiceName).Status.LoadBalancer.Ingress)
		})
	}
}

// The Service selects the name of the Cluster, and its own name comes from
// that name. Without a usable name the provider makes no Service and says why.
func TestClusterReconcilerWaitsBeforeItMakesTheService(t *testing.T) {
	tests := []struct {
		name        string
		owners      []metav1.OwnerReference
		wantReason  string
		wantMessage string
	}{
		{
			name:       "Cluster API has not set the owner yet",
			wantReason: infrav1.WaitingForOwnerClusterReason,
		},
		{
			name: "the owner is a Cluster of another API group",
			owners: []metav1.OwnerReference{
				{APIVersion: "other.example.com/v1", Kind: "Cluster", Name: testClusterName, UID: "uid-of-another-owner"},
			},
			wantReason: infrav1.WaitingForOwnerClusterReason,
		},
		{
			name:        "the name of the Cluster starts with a digit",
			owners:      []metav1.OwnerReference{ownerCluster("1st")},
			wantReason:  infrav1.ControlPlaneServiceNameInvalidReason,
			wantMessage: `"1st-control-plane" is not a valid Service name`,
		},
		{
			name:        "the name of the Cluster has a dot",
			owners:      []metav1.OwnerReference{ownerCluster("team.one")},
			wantReason:  infrav1.ControlPlaneServiceNameInvalidReason,
			wantMessage: `"team.one-control-plane" is not a valid Service name`,
		},
		{
			name:        "the name of the Cluster is too long",
			owners:      []metav1.OwnerReference{ownerCluster(strings.Repeat("a", 50))},
			wantReason:  infrav1.ControlPlaneServiceNameInvalidReason,
			wantMessage: "at most 49 characters",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			infraCluster := newInfraClusterWithService()
			infraCluster.OwnerReferences = test.owners
			reconciler, k8sClient := newClusterReconcilerForTest(t, newPodNamespace(), infraCluster)

			reconcileCluster(t, reconciler)
			result := reconcileCluster(t, reconciler)

			require.Equal(t, ctrl.Result{RequeueAfter: retryAfter}, result)
			require.Empty(t, listServices(t, k8sClient))
			updated := getInfraCluster(t, k8sClient, testClusterName)
			require.Nil(t, updated.Status.Initialization.Provisioned)
			requireReadyCondition(t, updated.Status.Conditions, metav1.ConditionFalse, test.wantReason)
			require.Contains(t, readyMessage(t, updated), test.wantMessage)
		})
	}
}

// A name of 49 characters is the longest that still gives a Service name.
func TestClusterReconcilerTakesTheLongestClusterName(t *testing.T) {
	longest := strings.Repeat("a", 49)
	infraCluster := newInfraClusterWithService()
	infraCluster.OwnerReferences = []metav1.OwnerReference{ownerCluster(longest)}
	reconciler, k8sClient := newClusterReconcilerForTest(t, newPodNamespace(), infraCluster)

	reconcileUntilTheServiceIsMade(t, reconciler)

	services := listServices(t, k8sClient)
	require.Len(t, services, 1)
	require.Equal(t, longest+"-control-plane", services[0].Name)
	require.Len(t, services[0].Name, 63)
}

// A Service with the name that the provider needs and with another owner is
// never changed and never deleted. The cluster reports it and waits.
func TestClusterReconcilerReportsAServiceOfAnotherOwner(t *testing.T) {
	tests := []struct {
		name   string
		labels map[string]string
	}{
		{name: "a Service with no owner label"},
		{name: "a Service of an earlier cluster with the same name", labels: map[string]string{
			infrav1.OwnerUIDLabel: "uid-of-another-cluster",
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			foreign := &corev1.Service{
				ObjectMeta: metav1.ObjectMeta{Name: testServiceName, Namespace: testPodNamespace, Labels: test.labels},
				Spec:       corev1.ServiceSpec{Selector: map[string]string{"app": "other"}},
				Status: corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{
					Ingress: []corev1.LoadBalancerIngress{{IP: testServiceAddress}},
				}},
			}
			reconciler, k8sClient := newClusterReconcilerForTest(t, newPodNamespace(), newInfraClusterWithService(), foreign)
			before := getService(t, k8sClient, testServiceName)

			reconcileCluster(t, reconciler)
			result := reconcileCluster(t, reconciler)

			// The address of a foreign Service does not count.
			require.Equal(t, ctrl.Result{RequeueAfter: retryAfter}, result)
			updated := getInfraCluster(t, k8sClient, testClusterName)
			require.Nil(t, updated.Status.Initialization.Provisioned)
			requireReadyCondition(t, updated.Status.Conditions, metav1.ConditionFalse, infrav1.ControlPlaneServiceConflictReason)
			require.Equal(t, before, getService(t, k8sClient, testServiceName))

			// The delete of the cluster leaves the foreign Service.
			require.NoError(t, k8sClient.Delete(context.Background(), updated))
			require.Equal(t, ctrl.Result{}, reconcileCluster(t, reconciler))
			requireClusterGone(t, k8sClient)
			require.Equal(t, before, getService(t, k8sClient, testServiceName))
		})
	}
}

// The finalizer holds the cluster until its Service is gone. The delete
// removes the Service that this cluster made, and no other.
func TestClusterReconcilerDeletesOnlyItsOwnService(t *testing.T) {
	otherLabels := map[string]string{infrav1.OwnerUIDLabel: "uid-of-another-cluster"}
	others := []client.Object{
		&corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: "other-control-plane", Namespace: testPodNamespace, Labels: otherLabels}},
		&corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: "unrelated", Namespace: testPodNamespace}},
		// The same owner label in another namespace than the pod namespace.
		&corev1.Service{ObjectMeta: metav1.ObjectMeta{
			Name: testServiceName, Namespace: "another-namespace",
			Labels: map[string]string{infrav1.OwnerUIDLabel: testClusterUID},
		}},
	}
	objects := append([]client.Object{newPodNamespace(), newInfraClusterWithService()}, others...)
	reconciler, k8sClient := newClusterReconcilerForTest(t, objects...)
	reconcileUntilTheServiceIsMade(t, reconciler)

	// A load balancer holds its Service with a finalizer while it cleans up.
	service := getService(t, k8sClient, testServiceName)
	service.Finalizers = []string{"lb.example.com/cleanup"}
	require.NoError(t, k8sClient.Update(context.Background(), service))

	require.NoError(t, k8sClient.Delete(context.Background(), getInfraCluster(t, k8sClient, testClusterName)))

	for range 2 {
		require.Equal(t, ctrl.Result{RequeueAfter: deleteRetry}, reconcileCluster(t, reconciler))
		require.False(t, getService(t, k8sClient, testServiceName).DeletionTimestamp.IsZero())
		require.Contains(t, getInfraCluster(t, k8sClient, testClusterName).Finalizers, clusterFinalizer)
	}

	// The load balancer lets the Service go.
	service = getService(t, k8sClient, testServiceName)
	service.Finalizers = nil
	require.NoError(t, k8sClient.Update(context.Background(), service))

	require.Equal(t, ctrl.Result{}, reconcileCluster(t, reconciler))
	requireClusterGone(t, k8sClient)

	left := listServices(t, k8sClient)
	require.Len(t, left, len(others))
	for _, other := range others {
		require.NoError(t, k8sClient.Get(context.Background(), client.ObjectKeyFromObject(other), &corev1.Service{}),
			"Service %s/%s must stay", other.GetNamespace(), other.GetName())
	}

	// A late event for the cluster that is gone is not an error.
	require.Equal(t, ctrl.Result{}, reconcileCluster(t, reconciler))
}

func TestServiceToCluster(t *testing.T) {
	tests := []struct {
		name   string
		labels map[string]string
		want   []ctrl.Request
	}{
		{
			name: "a Service of the provider",
			labels: map[string]string{
				infrav1.OwnerNamespaceLabel: testNamespace,
				infrav1.OwnerNameLabel:      testClusterName,
			},
			want: []ctrl.Request{{NamespacedName: types.NamespacedName{Namespace: testNamespace, Name: testClusterName}}},
		},
		{name: "a Service of something else", labels: map[string]string{"app": "other"}},
		{name: "a Service with half of the owner", labels: map[string]string{infrav1.OwnerNameLabel: testClusterName}},
		{name: "a Service with no label"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: "service", Namespace: testPodNamespace, Labels: test.labels}}
			require.Equal(t, test.want, serviceToCluster(context.Background(), service))
		})
	}
}

func readyMessage(t *testing.T, infraCluster *infrav1.PodVMCluster) string {
	t.Helper()
	for _, condition := range infraCluster.Status.Conditions {
		if condition.Type == infrav1.ReadyCondition {
			return condition.Message
		}
	}
	t.Fatalf("no %s condition found in %v", infrav1.ReadyCondition, infraCluster.Status.Conditions)
	return ""
}

func requireClusterGone(t *testing.T, k8sClient client.Client) {
	t.Helper()
	err := k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testNamespace, Name: testClusterName}, &infrav1.PodVMCluster{})
	require.True(t, apierrors.IsNotFound(err), "the PodVMCluster still exists: %v", err)
}
