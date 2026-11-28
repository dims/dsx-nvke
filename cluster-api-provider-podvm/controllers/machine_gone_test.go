// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"fmt"
	"log/slog"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// A reconcile reads the machine from the cache and writes to the API server.
// The machine can be gone in between. The usual case is the end of a delete:
// the reconcile before removed the finalizer, and the cache does not show it
// yet. Each case here is one write that then gets "not found". The run must
// end with no error, with one line at the info level, and without making or
// deleting anything for a machine that no longer exists.
func TestMachineReconcilerEndsWhenTheMachineIsGoneAtAWrite(t *testing.T) {
	const rebootRequest = "2026-11-26T22:30:00Z"

	deleteInCache := func(t *testing.T, cache client.Client) {
		t.Helper()
		require.NoError(t, cache.Delete(context.Background(), getInfraMachine(t, cache, testMachineName)))
	}

	tests := []struct {
		name string
		// machine is the machine in the cache at the start.
		machine func() *infrav1.PodVMMachine
		// prepare brings the cache to the state before the write.
		prepare func(t *testing.T, reconciler *MachineReconciler, cache client.Client)
		// podObjects says whether the API server still has the pod, the
		// claims and the Secret copy that the cache shows.
		podObjects bool
		// check looks at the API server after the run.
		check func(t *testing.T, apiServer client.Client)
	}{
		{
			name: "the finalizer is added",
			machine: func() *infrav1.PodVMMachine {
				machine := newInfraMachine(testMachineName)
				machine.Finalizers = nil
				return machine
			},
		},
		{
			name: "a wait is reported in the Ready condition",
			machine: func() *infrav1.PodVMMachine {
				machine := newInfraMachine(testMachineName)
				machine.OwnerReferences = nil
				return machine
			},
		},
		{
			name: "the address is recorded",
			check: func(t *testing.T, apiServer client.Client) {
				// Nothing is made for a machine that is gone.
				requireGone(t, apiServer, &corev1.Pod{}, testMachineName)
				requireGone(t, apiServer, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))
				requireGone(t, apiServer, &corev1.PersistentVolumeClaim{}, etcdClaimName(testMachineName))
				requireGone(t, apiServer, &corev1.Secret{}, bootstrapSecretName(testMachineName))
			},
		},
		{
			name: "a reboot request is answered",
			prepare: func(t *testing.T, reconciler *MachineReconciler, cache client.Client) {
				reconcileUntilNodeAgentAnswers(t, reconciler, cache, testMachineName)
				setRebootAnnotation(t, cache, rebootRequest)
			},
			podObjects: true,
			check: func(t *testing.T, apiServer client.Client) {
				// The pod is not deleted for a machine that is gone.
				require.True(t, getPod(t, apiServer, testMachineName).DeletionTimestamp.IsZero())
			},
		},
		{
			name: "the address is reported",
			prepare: func(t *testing.T, reconciler *MachineReconciler, cache client.Client) {
				reconcileMachine(t, reconciler, testMachineName)
				startNodeAgent(t, cache, testMachineName)
			},
			podObjects: true,
		},
		{
			name: "the provider ID is set",
			prepare: func(t *testing.T, reconciler *MachineReconciler, cache client.Client) {
				reconcileMachine(t, reconciler, testMachineName)
				startNodeAgent(t, cache, testMachineName)
				machine := getInfraMachine(t, cache, testMachineName)
				machine.Status.Addresses = []clusterv1.MachineAddress{
					{Type: clusterv1.MachineInternalIP, Address: machine.Status.Address},
				}
				require.NoError(t, cache.Status().Update(context.Background(), machine))
			},
			podObjects: true,
		},
		{
			name: "the provisioned flag is set",
			prepare: func(t *testing.T, reconciler *MachineReconciler, cache client.Client) {
				reconcileUntilNodeAgentAnswers(t, reconciler, cache, testMachineName)
				machine := getInfraMachine(t, cache, testMachineName)
				machine.Status.Initialization.Provisioned = nil
				machine.Status.Conditions = nil
				require.NoError(t, cache.Status().Update(context.Background(), machine))
			},
			podObjects: true,
		},
		{
			name: "the delete reports that it waits for the pod",
			prepare: func(t *testing.T, reconciler *MachineReconciler, cache client.Client) {
				reconcileUntilNodeAgentAnswers(t, reconciler, cache, testMachineName)
				deleteInCache(t, cache)
			},
			podObjects: true,
			check: func(t *testing.T, apiServer client.Client) {
				// The delete calls went out before the write to the machine.
				requireGone(t, apiServer, &corev1.Pod{}, testMachineName)
				requireGone(t, apiServer, &corev1.PersistentVolumeClaim{}, varClaimName(testMachineName))
				requireGone(t, apiServer, &corev1.Secret{}, bootstrapSecretName(testMachineName))
			},
		},
		{
			// The case that was seen in a cluster: the delete was complete,
			// and a second run for the same machine found nothing to remove.
			name: "the finalizer is removed",
			prepare: func(t *testing.T, reconciler *MachineReconciler, cache client.Client) {
				reconcileUntilNodeAgentAnswers(t, reconciler, cache, testMachineName)
				deleteInCache(t, cache)
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			machine := newInfraMachine(testMachineName)
			if test.machine != nil {
				machine = test.machine()
			}
			reconciler, cache := newMachineReconcilerForTest(t, machineObjects(machine)...)
			if test.prepare != nil {
				test.prepare(t, reconciler, cache)
			}

			// From here on the cache still shows the machine, and the API
			// server no longer has it.
			apiServer := apiServerWithoutTheMachine(t, cache, test.podObjects)
			logs := &recordingHandler{}
			reconciler.client = &staleCacheClient{Client: cache, apiServer: apiServer}
			reconciler.apiReader = apiServer
			reconciler.logger = slog.New(logs)

			result, err := reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
			require.NoError(t, err)
			require.Equal(t, ctrl.Result{}, result)

			require.Equal(t, 1, logs.count(slog.LevelInfo, "PodVMMachine is gone"))
			require.Zero(t, logs.countAtOrAbove(slog.LevelWarn))

			err = apiServer.Get(context.Background(),
				client.ObjectKey{Namespace: testNamespace, Name: testMachineName}, &infrav1.PodVMMachine{})
			require.True(t, apierrors.IsNotFound(err), "the run made the machine again: %v", err)
			if test.check != nil {
				test.check(t, apiServer)
			}
		})
	}
}

// The API server answers "not found" also for a resource that it does not
// serve, for example the status of a CRD with no status subresource. The
// machine exists then, and the provider must report the fault. If it took
// every "not found" for a machine that is gone, it would stop without a word.
func TestMachineReconcilerReportsANotFoundAnswerForAMachineThatExists(t *testing.T) {
	notServed := apierrors.NewNotFound(schema.GroupResource{Group: infrav1.GroupName, Resource: "podvmmachines"}, "")

	tests := []struct {
		name      string
		machine   func() *infrav1.PodVMMachine
		prepare   func(t *testing.T, cache client.Client)
		client    func(cache client.Client) client.Client
		wantError string
	}{
		{
			name: "the status write",
			machine: func() *infrav1.PodVMMachine {
				machine := newInfraMachine(testMachineName)
				machine.OwnerReferences = nil
				return machine
			},
			client: func(cache client.Client) client.Client {
				return &rejectingClient{Client: cache, statusPatchErr: notServed}
			},
			wantError: "failed to update the status of PodVMMachine",
		},
		{
			name: "the write that adds the finalizer",
			machine: func() *infrav1.PodVMMachine {
				machine := newInfraMachine(testMachineName)
				machine.Finalizers = nil
				return machine
			},
			client: func(cache client.Client) client.Client {
				return &rejectingClient{Client: cache, patchErr: notServed}
			},
			wantError: "failed to add the PodVMMachine finalizer",
		},
		{
			name:    "the write that removes the finalizer",
			machine: func() *infrav1.PodVMMachine { return newInfraMachine(testMachineName) },
			prepare: func(t *testing.T, cache client.Client) {
				require.NoError(t, cache.Delete(context.Background(), getInfraMachine(t, cache, testMachineName)))
			},
			client: func(cache client.Client) client.Client {
				return &rejectingClient{Client: cache, patchErr: notServed}
			},
			wantError: "failed to remove the finalizer from PodVMMachine",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reconciler, cache := newMachineReconcilerForTest(t, machineObjects(test.machine())...)
			if test.prepare != nil {
				test.prepare(t, cache)
			}
			reconciler.client = test.client(cache)

			_, err := reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
			require.ErrorContains(t, err, test.wantError)
		})
	}
}

func TestObjectIsGone(t *testing.T) {
	notFound := apierrors.NewNotFound(schema.GroupResource{Group: infrav1.GroupName, Resource: "podvmmachines"}, testMachineName)
	machine := newInfraMachine(testMachineName)
	replaced := newInfraMachine(testMachineName)
	replaced.UID = types.UID("uid-of-a-later-machine")

	tests := []struct {
		name     string
		writeErr error
		// stored is what the API server holds under the name of the machine.
		stored  *infrav1.PodVMMachine
		readErr error
		want    bool
	}{
		{name: "the write got not found and the object does not exist", writeErr: notFound, want: true},
		{name: "the write got not found and a later object has the name", writeErr: notFound, stored: replaced, want: true},
		{name: "the write got not found and the object exists", writeErr: notFound, stored: machine, want: false},
		{name: "the write got not found and the read fails", writeErr: notFound, readErr: fmt.Errorf("no answer"), want: false},
		{name: "the write got a conflict", writeErr: apierrors.NewConflict(schema.GroupResource{}, testMachineName, nil), want: false},
		{name: "the write got another error", writeErr: fmt.Errorf("no answer"), want: false},
		{name: "the write got no error", writeErr: nil, want: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var objects []client.Object
			if test.stored != nil {
				objects = append(objects, test.stored.DeepCopy())
			}
			var apiReader client.Reader = newFakeClient(t, objects...)
			if test.readErr != nil {
				apiReader = &failingReader{err: test.readErr}
			}

			gone := objectIsGone(context.Background(), apiReader, machine, &infrav1.PodVMMachine{}, test.writeErr)
			require.Equal(t, test.want, gone)
		})
	}
}

// A PodVMCluster has no finalizer, so it is gone the moment it is deleted. A
// reconcile that still saw it in the cache ends with no error.
func TestClusterReconcilerEndsWhenTheClusterIsGoneAtTheWrite(t *testing.T) {
	cache := newFakeClient(t, newPodNamespace(), newInfraCluster(), newHostNode("host-a", nil))
	apiServer := newFakeClient(t, newPodNamespace(), newHostNode("host-a", nil))
	logs := &recordingHandler{}
	reconciler := NewClusterReconciler(&staleCacheClient{Client: cache, apiServer: apiServer}, apiServer, slog.New(logs))

	result, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
	require.NoError(t, err)
	require.Equal(t, ctrl.Result{}, result)
	require.Equal(t, 1, logs.count(slog.LevelInfo, "PodVMCluster is gone"))
	require.Zero(t, logs.countAtOrAbove(slog.LevelWarn))
}

// The same "not found" for a PodVMCluster that exists is a fault to report.
func TestClusterReconcilerReportsANotFoundAnswerForAClusterThatExists(t *testing.T) {
	cache := newFakeClient(t, newPodNamespace(), newInfraCluster(), newHostNode("host-a", nil))
	notServed := apierrors.NewNotFound(schema.GroupResource{Group: infrav1.GroupName, Resource: "podvmclusters"}, "")
	reconciler := NewClusterReconciler(&rejectingClient{Client: cache, statusPatchErr: notServed}, cache, slog.New(slog.DiscardHandler))

	_, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
	require.ErrorContains(t, err, "failed to update the status of PodVMCluster")
}

// staleCacheClient reads from a cache and writes to the API server, the way
// the client of a manager does. The cache can still show an object that the
// API server no longer has.
type staleCacheClient struct {
	client.Client
	apiServer client.Client
}

func (c *staleCacheClient) Create(ctx context.Context, obj client.Object, opts ...client.CreateOption) error {
	return c.apiServer.Create(ctx, obj, opts...)
}

func (c *staleCacheClient) Delete(ctx context.Context, obj client.Object, opts ...client.DeleteOption) error {
	return c.apiServer.Delete(ctx, obj, opts...)
}

func (c *staleCacheClient) Patch(ctx context.Context, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
	return c.apiServer.Patch(ctx, obj, patch, opts...)
}

func (c *staleCacheClient) Status() client.SubResourceWriter {
	return c.apiServer.Status()
}

// rejectingClient answers a write to an object of this provider with a given
// error, and leaves every read and every other write alone.
type rejectingClient struct {
	client.Client
	patchErr       error
	statusPatchErr error
}

func (c *rejectingClient) Patch(ctx context.Context, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
	if c.patchErr != nil && isProviderObject(obj) {
		return c.patchErr
	}
	return c.Client.Patch(ctx, obj, patch, opts...)
}

func (c *rejectingClient) Status() client.SubResourceWriter {
	if c.statusPatchErr == nil {
		return c.Client.Status()
	}
	return &rejectingStatusWriter{SubResourceWriter: c.Client.Status(), err: c.statusPatchErr}
}

type rejectingStatusWriter struct {
	client.SubResourceWriter
	err error
}

func (w *rejectingStatusWriter) Patch(ctx context.Context, obj client.Object, patch client.Patch, opts ...client.SubResourcePatchOption) error {
	if isProviderObject(obj) {
		return w.err
	}
	return w.SubResourceWriter.Patch(ctx, obj, patch, opts...)
}

func isProviderObject(obj client.Object) bool {
	switch obj.(type) {
	case *infrav1.PodVMMachine, *infrav1.PodVMCluster:
		return true
	}
	return false
}

// failingReader fails every read.
type failingReader struct {
	err error
}

func (r *failingReader) Get(context.Context, client.ObjectKey, client.Object, ...client.GetOption) error {
	return r.err
}

func (r *failingReader) List(context.Context, client.ObjectList, ...client.ListOption) error {
	return r.err
}

// apiServerWithoutTheMachine builds the state of the API server from the state
// of the cache: every object but the PodVMMachine. With podObjects false the
// pod, the claims and the Secret copy of the machine are gone as well.
func apiServerWithoutTheMachine(t *testing.T, cache client.Client, podObjects bool) client.Client {
	t.Helper()
	ctx := context.Background()
	var objects []client.Object

	namespaces := &corev1.NamespaceList{}
	require.NoError(t, cache.List(ctx, namespaces))
	for i := range namespaces.Items {
		objects = append(objects, &namespaces.Items[i])
	}
	infraClusters := &infrav1.PodVMClusterList{}
	require.NoError(t, cache.List(ctx, infraClusters))
	for i := range infraClusters.Items {
		objects = append(objects, &infraClusters.Items[i])
	}
	clusters := &clusterv1.ClusterList{}
	require.NoError(t, cache.List(ctx, clusters))
	for i := range clusters.Items {
		objects = append(objects, &clusters.Items[i])
	}
	owners := &clusterv1.MachineList{}
	require.NoError(t, cache.List(ctx, owners))
	for i := range owners.Items {
		objects = append(objects, &owners.Items[i])
	}
	secrets := &corev1.SecretList{}
	require.NoError(t, cache.List(ctx, secrets))
	for i := range secrets.Items {
		if secrets.Items[i].Namespace != testPodNamespace || podObjects {
			objects = append(objects, &secrets.Items[i])
		}
	}
	if podObjects {
		pods := &corev1.PodList{}
		require.NoError(t, cache.List(ctx, pods))
		for i := range pods.Items {
			objects = append(objects, &pods.Items[i])
		}
		claims := &corev1.PersistentVolumeClaimList{}
		require.NoError(t, cache.List(ctx, claims))
		for i := range claims.Items {
			objects = append(objects, &claims.Items[i])
		}
	}

	for _, obj := range objects {
		obj.SetResourceVersion("")
	}
	return newFakeClient(t, objects...)
}
