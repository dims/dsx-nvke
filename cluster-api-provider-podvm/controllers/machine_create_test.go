// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"errors"
	"log/slog"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/apimachinery/pkg/util/validation/field"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// A create call that the API server rejects does not pass at the next try, and
// its cause is in the host cluster. The Ready condition carries the answer of
// the API server, so an operator does not read a wait.
func TestMachineReconcilerReportsACreateCallThatTheAPIServerRejects(t *testing.T) {
	tests := []struct {
		name string
		// answer is what the API server says to the create call of an object.
		answer func(obj client.Object) error
		// wantMessage is the text of the API server. Empty means that the
		// failure is not a rejection and stays an error.
		wantMessage string
	}{
		{
			name: "a pod with a RuntimeClass that does not exist",
			answer: func(obj client.Object) error {
				if _, isPod := obj.(*corev1.Pod); !isPod {
					return nil
				}
				return apierrors.NewForbidden(schema.GroupResource{Resource: "pods"}, obj.GetName(),
					errors.New(`pod rejected: RuntimeClass "kata-clh" not found`))
			},
			wantMessage: `pod rejected: RuntimeClass "kata-clh" not found`,
		},
		{
			name: "a volume claim over the quota of the pod namespace",
			answer: func(obj client.Object) error {
				if _, isClaim := obj.(*corev1.PersistentVolumeClaim); !isClaim {
					return nil
				}
				return apierrors.NewForbidden(schema.GroupResource{Resource: "persistentvolumeclaims"}, obj.GetName(),
					errors.New("exceeded quota: storage, requested: requests.storage=20Gi"))
			},
			wantMessage: "exceeded quota: storage",
		},
		{
			name: "a Secret copy that is not valid",
			answer: func(obj client.Object) error {
				if _, isSecret := obj.(*corev1.Secret); !isSecret {
					return nil
				}
				return apierrors.NewInvalid(schema.GroupKind{Kind: "Secret"}, obj.GetName(), field.ErrorList{
					field.TooLong(field.NewPath("metadata", "labels"), "", validation.LabelValueMaxLength),
				})
			},
			wantMessage: "metadata.labels: Too long",
		},
		{
			name: "an API server that fails is not a rejection",
			answer: func(obj client.Object) error {
				if _, isPod := obj.(*corev1.Pod); !isPod {
					return nil
				}
				return apierrors.NewInternalError(errors.New("etcd is not ready"))
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			k8sClient := newFakeClient(t, machineObjects(newInfraMachine(testMachineName))...)
			rejecting := &createAnswerClient{Client: k8sClient, answer: test.answer}
			reconciler := NewMachineReconciler(rejecting, k8sClient, slog.New(slog.DiscardHandler))

			result, err := reconciler.Reconcile(context.Background(), machineRequest(testMachineName))
			machine := getInfraMachine(t, k8sClient, testMachineName)
			requireGone(t, k8sClient, &corev1.Pod{}, testMachineName)

			if test.wantMessage == "" {
				require.ErrorContains(t, err, "failed to create Pod")
				requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, infrav1.WaitingForPodReason)
				return
			}
			require.NoError(t, err)
			require.Equal(t, ctrl.Result{RequeueAfter: retryAfter}, result)
			requireReadyCondition(t, machine.Status.Conditions, metav1.ConditionFalse, infrav1.CreateRejectedReason)
			require.Contains(t, machine.Status.Conditions[0].Message, test.wantMessage)

			// The host cluster is put right: the next reconcile makes the pod.
			rejecting.answer = func(client.Object) error { return nil }
			reconcileMachine(t, reconciler, testMachineName)
			require.Equal(t, testMachineName, getPod(t, k8sClient, testMachineName).Name)
			requireReadyCondition(t, getInfraMachine(t, k8sClient, testMachineName).Status.Conditions,
				metav1.ConditionFalse, infrav1.WaitingForPodReason)
		})
	}
}

// createAnswerClient gives each create call the answer of a test, and passes
// the call on when the answer is no error.
type createAnswerClient struct {
	client.Client
	answer func(obj client.Object) error
}

func (c *createAnswerClient) Create(ctx context.Context, obj client.Object, opts ...client.CreateOption) error {
	if err := c.answer(obj); err != nil {
		return err
	}
	return c.Client.Create(ctx, obj, opts...)
}
