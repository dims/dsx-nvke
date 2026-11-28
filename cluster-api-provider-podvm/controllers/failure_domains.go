// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"slices"

	corev1 "k8s.io/api/core/v1"
	apiequality "k8s.io/apimachinery/pkg/api/equality"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// failureDomainsFromNodes returns one failure domain for each value of the
// label key on the nodes that can take a pod.
//
// When no such node carries the label, each host node is one failure domain,
// from the host name label. The list is sorted, so the status does not change
// between two reconciles of the same nodes.
func failureDomainsFromNodes(nodes []corev1.Node, labelKey string) []clusterv1.FailureDomain {
	values := labelValues(nodes, labelKey)
	if len(values) == 0 && labelKey != infrav1.HostNameLabelKey {
		values = labelValues(nodes, infrav1.HostNameLabelKey)
	}

	domains := make([]clusterv1.FailureDomain, 0, len(values))
	for _, value := range values {
		domains = append(domains, clusterv1.FailureDomain{Name: value, ControlPlane: ptr.To(true)})
	}
	return domains
}

// labelValues returns the sorted, distinct values of a label on the nodes that
// can take a pod.
func labelValues(nodes []corev1.Node, labelKey string) []string {
	values := make([]string, 0, len(nodes))
	for i := range nodes {
		node := &nodes[i]
		if !nodeTakesPods(node) {
			continue
		}
		if value := node.Labels[labelKey]; value != "" {
			values = append(values, value)
		}
	}
	slices.Sort(values)
	return slices.Compact(values)
}

// nodeTakesPods reports whether the scheduler can put a new pod of the
// provider on the node. The pods carry no toleration of their own, so a taint
// that keeps new pods away takes the node out of every failure domain.
func nodeTakesPods(node *corev1.Node) bool {
	if !node.DeletionTimestamp.IsZero() || node.Spec.Unschedulable {
		return false
	}
	for _, taint := range node.Spec.Taints {
		if taint.Effect == corev1.TaintEffectNoSchedule || taint.Effect == corev1.TaintEffectNoExecute {
			return false
		}
	}
	return true
}

// nodePlacementChanged lets a node event through only when it can change the
// failure domains. A node sends a status update every few seconds, and none of
// those change the labels, the taints or the unschedulable flag.
func nodePlacementChanged() predicate.Funcs {
	return predicate.Funcs{
		CreateFunc: func(event.CreateEvent) bool { return true },
		DeleteFunc: func(event.DeleteEvent) bool { return true },
		UpdateFunc: func(e event.UpdateEvent) bool {
			oldNode, oldOK := e.ObjectOld.(*corev1.Node)
			newNode, newOK := e.ObjectNew.(*corev1.Node)
			if !oldOK || !newOK {
				return true
			}
			return !apiequality.Semantic.DeepEqual(oldNode.Labels, newNode.Labels) ||
				!apiequality.Semantic.DeepEqual(oldNode.Spec.Taints, newNode.Spec.Taints) ||
				oldNode.Spec.Unschedulable != newNode.Spec.Unschedulable ||
				oldNode.DeletionTimestamp.IsZero() != newNode.DeletionTimestamp.IsZero()
		},
		GenericFunc: func(event.GenericEvent) bool { return false },
	}
}
