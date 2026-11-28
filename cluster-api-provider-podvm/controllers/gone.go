// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// objectIsGone reports whether a write to an object of this provider failed
// because the object no longer exists.
//
// A reconcile reads its object from the cache and writes to the API server.
// The object can be gone in between for a normal reason: the reconcile before
// this one removed the last finalizer, or the object had no finalizer and
// someone deleted it. Then there is nothing left to do, and nothing to retry.
//
// A "not found" answer alone does not prove that. The API server gives the
// same answer for a resource it does not serve, for example the status of a
// CRD that has no status subresource, and that is a fault to report. So the
// API server is asked for the object itself. The object is gone when it does
// not exist, or when another object with the same name took its place.
//
// current is an empty object of the same kind to read into.
func objectIsGone(ctx context.Context, apiReader client.Reader, obj, current client.Object, writeErr error) bool {
	if !apierrors.IsNotFound(writeErr) {
		return false
	}
	err := apiReader.Get(ctx, client.ObjectKeyFromObject(obj), current)
	if err == nil {
		return current.GetUID() != obj.GetUID()
	}
	return apierrors.IsNotFound(err)
}
