// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"time"
)

const (
	// retryAfter is the wait before the provider looks again at a state that
	// only an operator or another controller can change, for example a
	// missing PodVMCluster or a full address range.
	retryAfter = 30 * time.Second
)
