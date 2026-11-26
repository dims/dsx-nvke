// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

const otherProviderID = "podvm://other-pods/other-machine"

func TestMachineReconcilerCopiesProviderIDToTenantNode(t *testing.T) {
	reconciler, tenantClient, _ := newMachineReconcilerWithTenant(t, "", nil)

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{}, result)
	require.Equal(t, testProviderID, getTenantNode(t, tenantClient).Spec.ProviderID)
	requireReadyCondition(t, getInfraMachine(t, reconciler.client, testMachineName).Status.Conditions,
		metav1.ConditionTrue, infrav1.PodRunningReason)
}

func TestMachineReconcilerKeepsMatchingTenantNodeProviderID(t *testing.T) {
	reconciler, tenantClient, _ := newMachineReconcilerWithTenant(t, testProviderID, nil)

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{}, result)
	require.Equal(t, testProviderID, getTenantNode(t, tenantClient).Spec.ProviderID)
}

func TestMachineReconcilerRejectsDifferentTenantNodeProviderID(t *testing.T) {
	reconciler, tenantClient, _ := newMachineReconcilerWithTenant(t, otherProviderID, nil)

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{}, result)
	require.Equal(t, otherProviderID, getTenantNode(t, tenantClient).Spec.ProviderID)

	machine := getInfraMachine(t, reconciler.client, testMachineName)
	requireReadyCondition(t, machine.Status.Conditions,
		metav1.ConditionFalse, infrav1.NodeProviderIDConflictReason)
	// The pod runs, so the machine is still provisioned.
	require.True(t, *machine.Status.Initialization.Provisioned)

	// The conflict is a steady state: the next reconcile writes nothing.
	reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, machine.ResourceVersion, getInfraMachine(t, reconciler.client, testMachineName).ResourceVersion)
}

func TestMachineReconcilerDoesNotOverwriteAConcurrentTenantNodeProviderID(t *testing.T) {
	reconciler, tenantClient, factory := newMachineReconcilerWithTenant(t, "", nil)
	factory.client = &concurrentNodeUpdateClient{
		Client:     tenantClient,
		providerID: otherProviderID,
	}

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, ctrl.Result{RequeueAfter: retryNow}, result)
	require.Equal(t, otherProviderID, getTenantNode(t, tenantClient).Spec.ProviderID)
}

func TestMachineReconcilerWaitsForTenantNode(t *testing.T) {
	reconciler, tenantClient, _ := newMachineReconcilerWithTenant(t, "", nil)
	require.NoError(t, tenantClient.Delete(context.Background(), getTenantNode(t, tenantClient)))

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, retryAfter, result.RequeueAfter)
}

func TestMachineReconcilerWaitsForTenantKubeconfig(t *testing.T) {
	notFound := apierrors.NewNotFound(schema.GroupResource{Resource: "secrets"}, "test-kubeconfig")
	reconciler, _, factory := newMachineReconcilerWithTenant(t, "", notFound)

	result := reconcileMachine(t, reconciler, testMachineName)
	require.Equal(t, retryAfter, result.RequeueAfter)
	require.Equal(t, 1, factory.calls)
}

// The API server of a new cluster does not exist before its first node is
// initialized, and that node can be this pod. A failed look at the Node must
// not hold back the provisioned flag.
func TestMachineReconcilerReportsProvisionedWhenTheTenantClientFails(t *testing.T) {
	reconciler, _, _ := newMachineReconcilerWithTenant(t, "", fmt.Errorf("invalid kubeconfig"))

	_, err := reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
	require.ErrorContains(t, err, "failed to create tenant client")

	machine := getInfraMachine(t, reconciler.client, testMachineName)
	require.Equal(t, testProviderID, machine.Spec.ProviderID)
	require.True(t, *machine.Status.Initialization.Provisioned)
	requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionTrue, infrav1.PodRunningReason)
}

// The Node gets its provider ID only from a pod that runs.
func TestMachineReconcilerDoesNotLookAtTheTenantNodeBeforeThePodRuns(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	factory := &fakeTenantClientFactory{err: fmt.Errorf("must not be called")}
	reconciler.tenantClients = factory

	reconcileMachine(t, reconciler, testMachineName)
	setPodPhase(t, k8sClient, testMachineName, corev1.PodPending)
	reconcileMachine(t, reconciler, testMachineName)

	require.Zero(t, factory.calls)
}

type fakeTenantClientFactory struct {
	client client.Client
	err    error
	calls  int
}

type concurrentNodeUpdateClient struct {
	client.Client
	providerID string
	updated    bool
}

func (c *concurrentNodeUpdateClient) Patch(
	ctx context.Context,
	obj client.Object,
	patch client.Patch,
	opts ...client.PatchOption,
) error {
	if !c.updated {
		node := &corev1.Node{}
		if err := c.Get(ctx, client.ObjectKeyFromObject(obj), node); err != nil {
			return err
		}
		node.Spec.ProviderID = c.providerID
		if err := c.Update(ctx, node); err != nil {
			return err
		}
		c.updated = true
	}
	return c.Client.Patch(ctx, obj, patch, opts...)
}

func (f *fakeTenantClientFactory) ClientForCluster(context.Context, *clusterv1.Cluster) (client.Client, error) {
	f.calls++
	return f.client, f.err
}

// newMachineReconcilerWithTenant builds a machine whose pod runs, and a new
// cluster with the Node of that machine.
func newMachineReconcilerWithTenant(
	t *testing.T,
	nodeProviderID string,
	factoryErr error,
) (*MachineReconciler, client.Client, *fakeTenantClientFactory) {
	t.Helper()

	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	tenantClient := fake.NewClientBuilder().WithScheme(newTestScheme(t)).WithObjects(&corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: testMachineName},
		Spec:       corev1.NodeSpec{ProviderID: nodeProviderID},
	}).Build()
	factory := &fakeTenantClientFactory{client: tenantClient, err: factoryErr}
	reconciler.tenantClients = factory

	// The first reconcile makes the pod. The Node is not looked at yet.
	reconcileMachine(t, reconciler, testMachineName)
	require.Zero(t, factory.calls)
	setPodPhase(t, k8sClient, testMachineName, corev1.PodRunning)
	return reconciler, tenantClient, factory
}

func getTenantNode(t *testing.T, tenantClient client.Client) *corev1.Node {
	t.Helper()
	node := &corev1.Node{}
	require.NoError(t, tenantClient.Get(context.Background(), client.ObjectKey{Name: testMachineName}, node))
	return node
}

var _ tenantClientFactory = (*fakeTenantClientFactory)(nil)
