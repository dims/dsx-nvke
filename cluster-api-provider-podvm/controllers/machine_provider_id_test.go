// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/url"
	"os"
	"strings"
	"syscall"
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

// The Node gets its provider ID only from a pod whose node agent answers.
func TestMachineReconcilerDoesNotLookAtTheTenantNodeBeforeTheNodeAgentAnswers(t *testing.T) {
	reconciler, k8sClient := newMachineReconcilerForTest(t, machineObjects(newInfraMachine(testMachineName))...)
	factory := &fakeTenantClientFactory{err: fmt.Errorf("must not be called")}
	reconciler.tenantClients = factory

	reconcileMachine(t, reconciler, testMachineName)
	for _, phase := range []corev1.PodPhase{corev1.PodPending, corev1.PodRunning} {
		setPodPhase(t, k8sClient, testMachineName, phase)
		reconcileMachine(t, reconciler, testMachineName)
	}

	require.Zero(t, factory.calls)
}

// The NVKE controller stops the API servers of a cluster before it deletes the
// Machines. A machine that is on its way out gets no look at its Node: the look
// would only find a closed port.
func TestMachineReconcilerDoesNotLookAtTheTenantNodeOfAMachineThatIsBeingDeleted(t *testing.T) {
	tests := []struct {
		name string
		// markDeleted gives one of the two objects a delete time.
		markDeleted func(t *testing.T, k8sClient client.Client)
	}{
		{
			name: "the owner Machine has a delete time",
			markDeleted: func(t *testing.T, k8sClient client.Client) {
				owner := &clusterv1.Machine{}
				require.NoError(t, k8sClient.Get(context.Background(),
					client.ObjectKey{Namespace: testNamespace, Name: testMachineName}, owner))
				// Cluster API holds the Machine with a finalizer until the
				// infrastructure machine is gone.
				owner.Finalizers = []string{clusterv1.MachineFinalizer}
				require.NoError(t, k8sClient.Update(context.Background(), owner))
				require.NoError(t, k8sClient.Delete(context.Background(), owner))
			},
		},
		{
			name: "the PodVMMachine has a delete time",
			markDeleted: func(t *testing.T, k8sClient client.Client) {
				require.NoError(t, k8sClient.Delete(context.Background(), getInfraMachine(t, k8sClient, testMachineName)))
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, _, factory := newMachineReconcilerWithTenant(t, "", nil)
			reconcileMachine(t, reconciler, testMachineName)
			require.Equal(t, 1, factory.calls)

			// From here on the API server of the cluster is down.
			factory.err = connectionRefused()
			test.markDeleted(t, reconciler.client)

			for range 3 {
				_, err := reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
				require.NoError(t, err)
			}
			require.Equal(t, 1, factory.calls)
		})
	}
}

// An API server that does not answer is not a failed reconcile. It is the
// state of a cluster before its first node is initialized and after its
// control plane nodes are reset. The provider says it in the Ready condition
// and in one line at the info level, and it looks again after a wait.
func TestMachineReconcilerWaitsForATenantAPIServerThatDoesNotAnswer(t *testing.T) {
	refused := connectionRefused()

	tests := []struct {
		name string
		// fail breaks one call to the new cluster.
		fail func(factory *fakeTenantClientFactory, tenantClient client.Client)
	}{
		{name: "the connection is refused at the read of the Node", fail: func(f *fakeTenantClientFactory, c client.Client) {
			f.client = &failingTenantClient{Client: c, getErr: refused}
		}},
		{name: "the connection is refused at the first discovery call", fail: func(f *fakeTenantClientFactory, c client.Client) {
			f.client = &failingTenantClient{Client: c, getErr: fmt.Errorf("failed to get API group resources: %w", refused)}
		}},
		{name: "the read of the Node runs into its time limit", fail: func(f *fakeTenantClientFactory, c client.Client) {
			f.client = &failingTenantClient{Client: c, getErr: fmt.Errorf("get node: %w", context.DeadlineExceeded)}
		}},
		{name: "the API server says that it cannot serve", fail: func(f *fakeTenantClientFactory, c client.Client) {
			f.client = &failingTenantClient{Client: c, getErr: apierrors.NewServiceUnavailable("etcd is not ready")}
		}},
		{name: "the connection is refused at the write of the Node", fail: func(f *fakeTenantClientFactory, c client.Client) {
			f.client = &failingTenantClient{Client: c, patchErr: refused}
		}},
		{name: "the connection is refused when the client is made", fail: func(f *fakeTenantClientFactory, _ client.Client) {
			f.err = refused
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, tenantClient, factory := newMachineReconcilerWithTenant(t, "", nil)
			logs := &recordingHandler{}
			reconciler.logger = slog.New(logs)
			test.fail(factory, tenantClient)

			result, err := reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
			require.NoError(t, err)
			require.Equal(t, ctrl.Result{RequeueAfter: retryAfter}, result)

			// The machine is ready and provisioned: its pod runs and its node
			// agent answers. The condition says what is not checked.
			machine := getInfraMachine(t, reconciler.client, testMachineName)
			require.Equal(t, testProviderID, machine.Spec.ProviderID)
			require.True(t, *machine.Status.Initialization.Provisioned)
			requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionTrue, infrav1.PodRunningReason)
			require.Contains(t, machine.Status.Conditions[0].Message, "The API server of the new cluster does not answer")
			require.Empty(t, getTenantNode(t, tenantClient).Spec.ProviderID)

			// One line at the info level, and nothing above it.
			require.Equal(t, 1, logs.count(slog.LevelInfo, "API server of the new cluster does not answer"))
			require.Zero(t, logs.countAtOrAbove(slog.LevelWarn))

			// The state is steady: the next look writes nothing.
			result, err = reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
			require.NoError(t, err)
			require.Equal(t, ctrl.Result{RequeueAfter: retryAfter}, result)
			require.Equal(t, machine.ResourceVersion, getInfraMachine(t, reconciler.client, testMachineName).ResourceVersion)

			// The API server answers again: the Node gets its provider ID, and
			// the condition no longer names the API server.
			factory.client, factory.err = tenantClient, nil
			result, err = reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
			require.NoError(t, err)
			require.Equal(t, ctrl.Result{}, result)
			require.Equal(t, testProviderID, getTenantNode(t, tenantClient).Spec.ProviderID)
			machine = getInfraMachine(t, reconciler.client, testMachineName)
			require.NotContains(t, machine.Status.Conditions[0].Message, "does not answer")
		})
	}
}

// An API server that answers and rejects the call is a failed reconcile.
// Waiting does not give the provider the rights it lacks.
func TestMachineReconcilerReportsATenantAPIServerThatRejectsTheCall(t *testing.T) {
	reconciler, tenantClient, factory := newMachineReconcilerWithTenant(t, "", nil)
	factory.client = &failingTenantClient{
		Client: tenantClient,
		getErr: apierrors.NewForbidden(schema.GroupResource{Resource: "nodes"}, testMachineName, fmt.Errorf("no rights")),
	}

	_, err := reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
	require.ErrorContains(t, err, "failed to get tenant Node")

	// The failed look does not hold back the provisioned flag.
	machine := getInfraMachine(t, reconciler.client, testMachineName)
	require.True(t, *machine.Status.Initialization.Provisioned)
}

func TestTenantAPIServerGaveNoAnswer(t *testing.T) {
	refused := connectionRefused()

	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "connection refused", err: refused, want: true},
		{name: "connection refused, wrapped two times", err: fmt.Errorf("failed to get tenant Node: %w", fmt.Errorf("discovery: %w", refused)), want: true},
		{name: "connection reset", err: &url.Error{Op: "Get", URL: "https://tenant.example.invalid", Err: syscall.ECONNRESET}, want: true},
		{name: "end of file in the middle of an answer", err: &url.Error{Op: "Get", URL: "https://tenant.example.invalid", Err: io.ErrUnexpectedEOF}, want: true},
		{name: "no route to the host", err: &url.Error{Op: "Get", URL: "https://tenant.example.invalid", Err: &net.OpError{
			Op: "dial", Net: "tcp", Err: os.NewSyscallError("connect", syscall.EHOSTUNREACH),
		}}, want: true},
		{name: "the name of the endpoint does not resolve", err: &url.Error{Op: "Get", URL: "https://tenant.example.invalid", Err: &net.OpError{
			Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "no such host", Name: "tenant.example.invalid", IsNotFound: true},
		}}, want: true},
		{name: "time limit of the call", err: context.DeadlineExceeded, want: true},
		{name: "service unavailable", err: apierrors.NewServiceUnavailable("not ready"), want: true},
		{name: "server timeout", err: apierrors.NewServerTimeout(schema.GroupResource{Resource: "nodes"}, "get", 1), want: true},
		{name: "gateway timeout", err: apierrors.NewTimeoutError("timeout", 1), want: true},
		{name: "forbidden", err: apierrors.NewForbidden(schema.GroupResource{Resource: "nodes"}, "n", fmt.Errorf("no")), want: false},
		{name: "unauthorized", err: apierrors.NewUnauthorized("no"), want: false},
		{name: "not found", err: apierrors.NewNotFound(schema.GroupResource{Resource: "nodes"}, "n"), want: false},
		{name: "an error with no cause in the network", err: fmt.Errorf("invalid kubeconfig"), want: false},
		{name: "the manager stops", err: context.Canceled, want: false},
		{name: "no error", err: nil, want: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			require.Equal(t, test.want, tenantAPIServerGaveNoAnswer(test.err))
		})
	}
}

// connectionRefused builds the error that client-go returns when nothing
// listens on the API server port.
func connectionRefused() error {
	return &url.Error{
		Op:  "Get",
		URL: "https://tenant.example.invalid:6443/api/v1/nodes/" + testMachineName,
		Err: &net.OpError{Op: "dial", Net: "tcp", Err: os.NewSyscallError("connect", syscall.ECONNREFUSED)},
	}
}

// failingTenantClient fails the read or the write of an object of the new
// cluster with a given error.
type failingTenantClient struct {
	client.Client
	getErr   error
	patchErr error
}

func (c *failingTenantClient) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	if c.getErr != nil {
		return c.getErr
	}
	return c.Client.Get(ctx, key, obj, opts...)
}

func (c *failingTenantClient) Patch(ctx context.Context, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
	if c.patchErr != nil {
		return c.patchErr
	}
	return c.Client.Patch(ctx, obj, patch, opts...)
}

// recordingHandler keeps the log records of a reconcile.
type recordingHandler struct {
	records []slog.Record
}

func (h *recordingHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *recordingHandler) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *recordingHandler) WithGroup(string) slog.Handler            { return h }
func (h *recordingHandler) Handle(_ context.Context, record slog.Record) error {
	h.records = append(h.records, record)
	return nil
}

func (h *recordingHandler) count(level slog.Level, message string) int {
	count := 0
	for _, record := range h.records {
		if record.Level == level && strings.Contains(record.Message, message) {
			count++
		}
	}
	return count
}

func (h *recordingHandler) countAtOrAbove(level slog.Level) int {
	count := 0
	for _, record := range h.records {
		if record.Level >= level {
			count++
		}
	}
	return count
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

// newMachineReconcilerWithTenant builds a machine whose pod runs with a node
// agent that answers, and a new cluster with the Node of that machine.
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
	startNodeAgent(t, k8sClient, testMachineName)
	return reconciler, tenantClient, factory
}

func getTenantNode(t *testing.T, tenantClient client.Client) *corev1.Node {
	t.Helper()
	node := &corev1.Node{}
	require.NoError(t, tenantClient.Get(context.Background(), client.ObjectKey{Name: testMachineName}, node))
	return node
}

var _ tenantClientFactory = (*fakeTenantClientFactory)(nil)
