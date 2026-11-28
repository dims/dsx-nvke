// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// Cluster API waits for this flag before it acts on any machine of the
// cluster, so reporting it is the first job of this reconciler.
func TestClusterReconcilerReportsProvisioned(t *testing.T) {
	reconciler, k8sClient := newClusterReconcilerForTest(t,
		newPodNamespace(),
		newInfraCluster(),
		newHostNode("host-b", nil),
		newHostNode("host-a", nil),
	)

	result, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
	require.NoError(t, err)
	require.Equal(t, ctrl.Result{}, result)

	infraCluster := getInfraCluster(t, k8sClient, testClusterName)
	require.NotNil(t, infraCluster.Status.Initialization.Provisioned)
	require.True(t, *infraCluster.Status.Initialization.Provisioned)
	requireReadyCondition(t, infraCluster.Status.Conditions, metav1.ConditionTrue, infrav1.ClusterSpecValidReason)
	// No node has a zone label, so each host node is one failure domain.
	require.Equal(t, []clusterv1.FailureDomain{
		{Name: "host-a", ControlPlane: ptr.To(true)},
		{Name: "host-b", ControlPlane: ptr.To(true)},
	}, infraCluster.Status.FailureDomains)
}

func TestClusterReconcilerRejectsAnUnusableSpec(t *testing.T) {
	tests := []struct {
		name       string
		mutate     func(infraCluster *infrav1.PodVMCluster)
		wantReason string
	}{
		{
			name:       "the pod namespace does not exist",
			mutate:     func(c *infrav1.PodVMCluster) { c.Spec.PodNamespace = "missing" },
			wantReason: infrav1.PodNamespaceNotFoundReason,
		},
		{
			name:       "the range is not a CIDR block",
			mutate:     func(c *infrav1.PodVMCluster) { c.Spec.AddressRange.CIDR = "172.28.1.0" },
			wantReason: infrav1.AddressRangeInvalidReason,
		},
		{
			name:       "the range is IPv6",
			mutate:     func(c *infrav1.PodVMCluster) { c.Spec.AddressRange.CIDR = "2001:db8::/64" },
			wantReason: infrav1.AddressRangeInvalidReason,
		},
		{
			name:       "the node network does not contain the range",
			mutate:     func(c *infrav1.PodVMCluster) { c.Spec.AddressRange.PrefixLength = 28 },
			wantReason: infrav1.AddressRangeInvalidReason,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			infraCluster := newInfraCluster()
			test.mutate(infraCluster)
			reconciler, k8sClient := newClusterReconcilerForTest(t, newPodNamespace(), infraCluster, newHostNode("host-a", nil))

			result, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
			require.NoError(t, err)
			require.Equal(t, retryAfter, result.RequeueAfter)

			updated := getInfraCluster(t, k8sClient, testClusterName)
			require.Nil(t, updated.Status.Initialization.Provisioned)
			require.Empty(t, updated.Status.FailureDomains)
			requireReadyCondition(t, updated.Status.Conditions, metav1.ConditionFalse, test.wantReason)
		})
	}
}

// Two clusters must never give out the same address. The older cluster keeps
// its range, so a new cluster cannot take addresses from machines that run.
func TestClusterReconcilerRejectsARangeThatOverlapsAnOlderCluster(t *testing.T) {
	// The names sort against the ages, so the test fails if the age is ignored.
	older := newInfraClusterNamed("zeta-older", "172.28.0.0/22")
	older.CreationTimestamp = metav1.NewTime(time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
	younger := newInfraClusterNamed("alpha-younger", testCIDR)
	younger.CreationTimestamp = metav1.NewTime(time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC))
	apart := newInfraClusterNamed("apart", "172.28.8.0/24")
	apart.CreationTimestamp = metav1.NewTime(time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC))

	reconciler, k8sClient := newClusterReconcilerForTest(t, newPodNamespace(), older, younger, apart)

	for _, name := range []string{"zeta-older", "alpha-younger", "apart"} {
		_, err := reconciler.Reconcile(context.Background(), clusterRequest(name))
		require.NoError(t, err)
	}

	requireReadyCondition(t, getInfraCluster(t, k8sClient, "zeta-older").Status.Conditions,
		metav1.ConditionTrue, infrav1.ClusterSpecValidReason)
	requireReadyCondition(t, getInfraCluster(t, k8sClient, "apart").Status.Conditions,
		metav1.ConditionTrue, infrav1.ClusterSpecValidReason)

	rejected := getInfraCluster(t, k8sClient, "alpha-younger")
	require.Nil(t, rejected.Status.Initialization.Provisioned)
	requireReadyCondition(t, rejected.Status.Conditions, metav1.ConditionFalse, infrav1.AddressRangeOverlapReason)
}

// Two clusters of the same second are ordered by name, so exactly one of them
// keeps the range. Without an order both would pass, or both would fail.
func TestIsOlderOrdersEveryPairOfClusters(t *testing.T) {
	created := metav1.NewTime(time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
	later := metav1.NewTime(created.Add(time.Second))

	tests := []struct {
		name string
		a, b *infrav1.PodVMCluster
		want bool
	}{
		{name: "created before", a: clusterAt("b", "ns", created), b: clusterAt("a", "ns", later), want: true},
		{name: "created after", a: clusterAt("a", "ns", later), b: clusterAt("b", "ns", created), want: false},
		{name: "same second, smaller name", a: clusterAt("a", "ns", created), b: clusterAt("b", "ns", created), want: true},
		{name: "same second, larger name", a: clusterAt("b", "ns", created), b: clusterAt("a", "ns", created), want: false},
		{name: "same second, smaller namespace", a: clusterAt("b", "ns-1", created), b: clusterAt("a", "ns-2", created), want: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			require.Equal(t, test.want, isOlder(test.a, test.b))
			require.Equal(t, !test.want, isOlder(test.b, test.a))
		})
	}
}

// A cluster whose machines are already running must keep the provisioned flag,
// or Cluster API stops acting on them.
func TestClusterReconcilerKeepsProvisionedWhenTheSpecTurnsUnusable(t *testing.T) {
	infraCluster := newInfraCluster()
	infraCluster.Status.Initialization.Provisioned = ptr.To(true)
	infraCluster.Status.FailureDomains = []clusterv1.FailureDomain{{Name: "host-a", ControlPlane: ptr.To(true)}}

	// The pod namespace is gone.
	reconciler, k8sClient := newClusterReconcilerForTest(t, infraCluster, newHostNode("host-a", nil))

	_, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
	require.NoError(t, err)

	updated := getInfraCluster(t, k8sClient, testClusterName)
	require.NotNil(t, updated.Status.Initialization.Provisioned)
	require.True(t, *updated.Status.Initialization.Provisioned)
	require.Len(t, updated.Status.FailureDomains, 1)
	requireReadyCondition(t, updated.Status.Conditions, metav1.ConditionFalse, infrav1.PodNamespaceNotFoundReason)
}

// The NVKE controller deletes the infrastructure cluster after the last
// Machine is gone and waits for it. The provider holds no finalizer, so the
// delete never waits, with or without machines.
func TestClusterReconcilerDoesNotBlockTheDeleteOfTheCluster(t *testing.T) {
	tests := []struct {
		name    string
		objects []client.Object
	}{
		{name: "no machine is left"},
		{name: "a machine is left", objects: []client.Object{newAllocatedInfraMachine(testMachineName, testFirstAddress)}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			objects := append([]client.Object{newPodNamespace(), newInfraCluster()}, test.objects...)
			reconciler, k8sClient := newClusterReconcilerForTest(t, objects...)

			_, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
			require.NoError(t, err)
			infraCluster := getInfraCluster(t, k8sClient, testClusterName)
			require.Empty(t, infraCluster.Finalizers)

			require.NoError(t, k8sClient.Delete(context.Background(), infraCluster))
			err = k8sClient.Get(context.Background(), client.ObjectKeyFromObject(infraCluster), infraCluster)
			require.True(t, apierrors.IsNotFound(err))

			result, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
			require.NoError(t, err)
			require.Equal(t, ctrl.Result{}, result)
		})
	}
}

func TestClusterReconcilerSkipsAMissingCluster(t *testing.T) {
	reconciler, _ := newClusterReconcilerForTest(t)

	result, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
	require.NoError(t, err)
	require.Zero(t, result.RequeueAfter)
}

func TestFailureDomainsFromNodes(t *testing.T) {
	zone := infrav1.DefaultFailureDomainLabelKey
	tainted := newHostNode("host-tainted", map[string]string{zone: "zone-c"})
	tainted.Spec.Taints = []corev1.Taint{{Key: "node-role.kubernetes.io/control-plane", Effect: corev1.TaintEffectNoSchedule}}
	evicting := newHostNode("host-evicting", map[string]string{zone: "zone-d"})
	evicting.Spec.Taints = []corev1.Taint{{Key: "node.kubernetes.io/unreachable", Effect: corev1.TaintEffectNoExecute}}
	cordoned := newHostNode("host-cordoned", map[string]string{zone: "zone-e"})
	cordoned.Spec.Unschedulable = true
	softTaint := newHostNode("host-soft", map[string]string{zone: "zone-f"})
	softTaint.Spec.Taints = []corev1.Taint{{Key: "example.com/prefer-not", Effect: corev1.TaintEffectPreferNoSchedule}}

	tests := []struct {
		name     string
		nodes    []corev1.Node
		labelKey string
		want     []string
	}{
		{
			name: "one domain for each zone, sorted",
			nodes: []corev1.Node{
				*newHostNode("host-1", map[string]string{zone: "zone-b"}),
				*newHostNode("host-2", map[string]string{zone: "zone-a"}),
				*newHostNode("host-3", map[string]string{zone: "zone-b"}),
			},
			labelKey: zone,
			want:     []string{"zone-a", "zone-b"},
		},
		{
			name: "one domain for each host node when no node has the label",
			nodes: []corev1.Node{
				*newHostNode("host-2", nil),
				*newHostNode("host-1", nil),
			},
			labelKey: zone,
			want:     []string{"host-1", "host-2"},
		},
		{
			name: "a node with no zone label is in no domain when other nodes have one",
			nodes: []corev1.Node{
				*newHostNode("host-1", map[string]string{zone: "zone-a"}),
				*newHostNode("host-2", nil),
			},
			labelKey: zone,
			want:     []string{"zone-a"},
		},
		{
			name: "a label key of the operator",
			nodes: []corev1.Node{
				*newHostNode("host-1", map[string]string{"example.com/rack": "rack-7", zone: "zone-a"}),
			},
			labelKey: "example.com/rack",
			want:     []string{"rack-7"},
		},
		{
			name: "the host name label as the key",
			nodes: []corev1.Node{
				*newHostNode("host-1", map[string]string{zone: "zone-a"}),
			},
			labelKey: infrav1.HostNameLabelKey,
			want:     []string{"host-1"},
		},
		{
			name: "a node that takes no new pod is in no domain",
			nodes: []corev1.Node{
				*newHostNode("host-1", map[string]string{zone: "zone-a"}),
				*tainted, *evicting, *cordoned, *softTaint,
			},
			labelKey: zone,
			want:     []string{"zone-a", "zone-f"},
		},
		{
			name:     "no node, no domain",
			labelKey: zone,
			want:     []string{},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			domains := failureDomainsFromNodes(test.nodes, test.labelKey)

			names := make([]string, 0, len(domains))
			for _, domain := range domains {
				names = append(names, domain.Name)
				// The NVKE controller places a control plane machine only in a
				// domain that says it can hold one.
				require.NotNil(t, domain.ControlPlane)
				require.True(t, *domain.ControlPlane)
			}
			require.Equal(t, test.want, names)
		})
	}
}

// The failure domains follow the nodes: a reconcile after a node change
// publishes the new list.
func TestClusterReconcilerFollowsTheNodes(t *testing.T) {
	zone := infrav1.DefaultFailureDomainLabelKey
	reconciler, k8sClient := newClusterReconcilerForTest(t,
		newPodNamespace(),
		newInfraCluster(),
		newHostNode("host-a", map[string]string{zone: "zone-a"}),
	)

	_, err := reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
	require.NoError(t, err)
	require.Equal(t, []clusterv1.FailureDomain{{Name: "zone-a", ControlPlane: ptr.To(true)}},
		getInfraCluster(t, k8sClient, testClusterName).Status.FailureDomains)

	require.NoError(t, k8sClient.Create(context.Background(), newHostNode("host-b", map[string]string{zone: "zone-b"})))
	_, err = reconciler.Reconcile(context.Background(), clusterRequest(testClusterName))
	require.NoError(t, err)
	require.Equal(t, []clusterv1.FailureDomain{
		{Name: "zone-a", ControlPlane: ptr.To(true)},
		{Name: "zone-b", ControlPlane: ptr.To(true)},
	}, getInfraCluster(t, k8sClient, testClusterName).Status.FailureDomains)
}

func TestNodeToClustersMapsANodeToEveryCluster(t *testing.T) {
	reconciler, _ := newClusterReconcilerForTest(t,
		newInfraClusterNamed("first", testCIDR),
		newInfraClusterNamed("second", "172.28.2.0/24"),
	)

	requests := reconciler.nodeToClusters(context.Background(), newHostNode("host-a", nil))
	require.ElementsMatch(t, []ctrl.Request{clusterRequest("first"), clusterRequest("second")}, requests)
}

// A node writes its status every few seconds. Only a change that can move a
// failure domain may start a reconcile of every cluster.
func TestNodePlacementChanged(t *testing.T) {
	base := newHostNode("host-a", map[string]string{infrav1.DefaultFailureDomainLabelKey: "zone-a"})

	tests := []struct {
		name   string
		mutate func(node *corev1.Node)
		want   bool
	}{
		{name: "a status update", mutate: func(n *corev1.Node) {
			n.Status.Conditions = []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue}}
		}, want: false},
		{name: "a label change", mutate: func(n *corev1.Node) {
			n.Labels[infrav1.DefaultFailureDomainLabelKey] = "zone-b"
		}, want: true},
		{name: "a new taint", mutate: func(n *corev1.Node) {
			n.Spec.Taints = []corev1.Taint{{Key: "example.com/drain", Effect: corev1.TaintEffectNoSchedule}}
		}, want: true},
		{name: "a cordon", mutate: func(n *corev1.Node) { n.Spec.Unschedulable = true }, want: true},
	}

	changed := nodePlacementChanged()
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			updated := base.DeepCopy()
			test.mutate(updated)
			require.Equal(t, test.want, changed.Update(event.UpdateEvent{ObjectOld: base, ObjectNew: updated}))
		})
	}

	require.True(t, changed.Create(event.CreateEvent{Object: base}))
	require.True(t, changed.Delete(event.DeleteEvent{Object: base}))
	require.False(t, changed.Generic(event.GenericEvent{Object: base}))
}

func newClusterReconcilerForTest(t *testing.T, objects ...client.Object) (*ClusterReconciler, client.Client) {
	t.Helper()
	k8sClient := newFakeClient(t, objects...)
	return NewClusterReconciler(k8sClient, k8sClient, slog.New(slog.DiscardHandler)), k8sClient
}

func clusterRequest(name string) ctrl.Request {
	return ctrl.Request{NamespacedName: types.NamespacedName{Namespace: testNamespace, Name: name}}
}

func clusterAt(name, namespace string, created metav1.Time) *infrav1.PodVMCluster {
	return &infrav1.PodVMCluster{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace, CreationTimestamp: created}}
}

func getInfraCluster(t *testing.T, k8sClient client.Client, name string) *infrav1.PodVMCluster {
	t.Helper()
	infraCluster := &infrav1.PodVMCluster{}
	require.NoError(t, k8sClient.Get(context.Background(),
		client.ObjectKey{Namespace: testNamespace, Name: name}, infraCluster))
	return infraCluster
}

// newHostNode builds a node of the host cluster. The kubelet sets the host
// name label on every node.
func newHostNode(name string, labels map[string]string) *corev1.Node {
	nodeLabels := map[string]string{infrav1.HostNameLabelKey: name}
	for key, value := range labels {
		nodeLabels[key] = value
	}
	return &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: nodeLabels}}
}
