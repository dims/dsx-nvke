// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// Package controllers holds the reconcilers of the pod VM Cluster API
// infrastructure provider.
//
// The package imports nothing from the NVKE controller. Everything it needs
// comes from the Kubernetes API, from Cluster API, and from the sibling
// api/v1alpha1 package, so the provider can move to its own module or
// repository without a code change.
package controllers
