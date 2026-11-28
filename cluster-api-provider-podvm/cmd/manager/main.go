// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// Command manager runs the pod VM Cluster API infrastructure provider.
package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/selection"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
	"github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/controllers"
)

var version = "dev"

func main() {
	var metricsAddress string
	var probeAddress string
	var leaderElection bool
	var showVersion bool

	flag.StringVar(&metricsAddress, "metrics-bind-address", ":8080", "Address for the metrics endpoint.")
	flag.StringVar(&probeAddress, "health-probe-bind-address", ":8081", "Address for health probes.")
	flag.BoolVar(&leaderElection, "leader-elect", false, "Enable leader election.")
	flag.BoolVar(&showVersion, "version", false, "Print the version and exit.")
	flag.Parse()

	if showVersion {
		if _, err := fmt.Fprintf(os.Stdout, "cluster-api-provider-podvm %s\n", version); err != nil {
			os.Exit(1)
		}
		return
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctrllog.SetLogger(logr.FromSlogHandler(logger.Handler()))

	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(clusterv1.AddToScheme(scheme))
	utilruntime.Must(infrav1.AddToScheme(scheme))

	// The host cluster can hold many pods and Services, and the provider needs
	// only the ones it made. Every one of those carries the owner UID label.
	owned, err := labels.NewRequirement(infrav1.OwnerUIDLabel, selection.Exists, nil)
	exitOnError(logger, err, "build the selector of the objects of the provider")

	manager, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: scheme,
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				&corev1.Pod{}:     {Label: labels.NewSelector().Add(*owned)},
				&corev1.Service{}: {Label: labels.NewSelector().Add(*owned)},
			},
		},
		Metrics:                metricsserver.Options{BindAddress: metricsAddress},
		HealthProbeBindAddress: probeAddress,
		LeaderElection:         leaderElection,
		LeaderElectionID:       "podvm.infrastructure.cluster.x-k8s.io",
	})
	exitOnError(logger, err, "create manager")

	exitOnError(logger, controllers.NewClusterReconciler(
		manager.GetClient(),
		manager.GetAPIReader(),
		logger.With("controller", "podvm-cluster"),
	).SetupWithManager(manager), "register cluster controller")

	exitOnError(logger, controllers.NewMachineReconciler(
		manager.GetClient(),
		manager.GetAPIReader(),
		logger.With("controller", "podvm-machine"),
	).SetupWithManager(manager), "register machine controller")

	exitOnError(logger, manager.AddHealthzCheck("healthz", healthz.Ping), "register health check")
	exitOnError(logger, manager.AddReadyzCheck("readyz", healthz.Ping), "register readiness check")

	logger.Info("Starting pod VM controller manager", "version", version)
	exitOnError(logger, manager.Start(ctrl.SetupSignalHandler()), "run manager")
}

func exitOnError(logger *slog.Logger, err error, action string) {
	if err == nil {
		return
	}
	logger.Error("Pod VM controller manager failed", "action", action, "error", err)
	os.Exit(1)
}
