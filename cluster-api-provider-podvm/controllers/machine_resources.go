// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	"sigs.k8s.io/controller-runtime/pkg/client"

	infrav1 "github.com/dsx-ai-factory/nvke/cluster-api-provider-podvm/api/v1alpha1"
)

// The contract between the provider and the node image. The image side reads
// these names, so a change here is a change of the contract.
const (
	// nodeContainerName is the name of the one container of a pod.
	nodeContainerName = "node"

	// varDevicePath and etcdDevicePath are the block devices of the two
	// volumes. The entry point of the image makes a filesystem on an empty
	// device and mounts the first at /var and the second at /var/lib/etcd.
	varDevicePath  = "/dev/podvm-var"
	etcdDevicePath = "/dev/podvm-etcd"

	// bootstrapMountPath holds the bootstrap data as the file "value". The
	// image runs its commands one time for each machine, and writes a file
	// that is outside the /var volume again at each start.
	bootstrapMountPath = "/etc/podvm/bootstrap"
	bootstrapDataKey   = "value"

	machineNameEnv   = "PODVM_MACHINE_NAME"
	nodeAddressEnv   = "PODVM_NODE_ADDRESS"
	nodeInterfaceEnv = "PODVM_NODE_INTERFACE"

	// nodeInterface is the name that Multus gives to the first interface of
	// the network annotation.
	nodeInterface = "net1"

	// networksAnnotation is the pod annotation that Multus reads.
	networksAnnotation = "k8s.v1.cni.cncf.io/networks"

	// nodeAgentPort is the secure port of nvke-agent. The startup probe of
	// each pod connects to it, so the container counts as started when the
	// agent accepts a connection. The NVKE controller calls the agent as soon
	// as it knows the address of a machine, and each failed call costs it a
	// retry wait that grows to minutes. So the provider reports the address
	// only for a started container.
	//
	// The probe runs each 2 seconds and gives the node 20 minutes to come up:
	// 600 failures of 2 seconds each. After that the kubelet starts the
	// container again.
	nodeAgentPort           = 15005
	startupPeriodSeconds    = 2
	startupFailureThreshold = 600

	// endpointReadyCommand is the program of the node image that the readiness
	// probe of a control plane pod runs in the container. It passes when the
	// endpoint gate file of the node does not exist and /readyz of the local
	// API server answers within 2 seconds with a status code below 400. A
	// Service of the caller then sends traffic only to a pod whose API server
	// is ready and whose node is not withdrawn.
	//
	// The node agent closes the gate before an operation that restarts the
	// API server and opens it after the operation. The probe is the health
	// check of the shared Service, so the gate takes the node out of the
	// Service while the API server still answers. A call from the kubelet to
	// port 6443 cannot see the gate, so the probe runs a program in the guest.
	//
	// The probe runs each 2 seconds, waits 3 seconds for an answer, and takes
	// a pod out after 3 failures in a row. So a pod is out after about 6
	// seconds of failed answers, and after about 9 seconds when each probe
	// runs into its time limit. One slow answer does not take a pod out: with
	// a time limit of 1 second and one failure, a slow disk took all three
	// pods of a control plane out at one time, and the shared address refused
	// every call.
	endpointReadyCommand      = "/usr/local/bin/podvm-endpoint-ready"
	readinessPeriodSeconds    = 2
	readinessTimeoutSeconds   = 3
	readinessFailureThreshold = 3

	// podTerminationGracePeriodSeconds is the time a pod gets to stop before
	// the kubelet kills it. A control plane node was seen not to stop by
	// itself in the default of 30 seconds, so each pod that is deleted costs
	// the whole wait: a reboot request, a pod that ended, and each machine of
	// a cluster delete. 20 seconds keeps that wait short, and a longer time
	// only delays the new pod. The node keeps its state on the two volumes.
	podTerminationGracePeriodSeconds = 20

	varVolumeName       = "var"
	etcdVolumeName      = "etcd"
	bootstrapVolumeName = "bootstrap"
)

// networkSelection is one entry of the network annotation.
type networkSelection struct {
	Name      string   `json:"name"`
	Namespace string   `json:"namespace"`
	IPs       []string `json:"ips"`
	MAC       string   `json:"mac"`
}

func varClaimName(podName string) string        { return podName + "-var" }
func etcdClaimName(podName string) string       { return podName + "-etcd" }
func bootstrapSecretName(podName string) string { return podName + "-bootstrap" }

// ownedBy reports whether the provider made the object for this machine. The
// UID decides: a later PodVMMachine with the same name is another machine.
func ownedBy(obj client.Object, machine *infrav1.PodVMMachine) bool {
	return machine.UID != "" && obj.GetLabels()[infrav1.OwnerUIDLabel] == string(machine.UID)
}

// resourceConflict describes an object that has the name the provider needs
// and belongs to something else.
func resourceConflict(kind string, key client.ObjectKey) *machineProblem {
	return &machineProblem{
		reason:  infrav1.ResourceConflictReason,
		message: fmt.Sprintf("%s %s exists and does not belong to this PodVMMachine", kind, key),
	}
}

// createProblem says why a create call failed. A call that the API server
// rejected does not pass at the next try, and its cause is in the host
// cluster, so it goes into the Ready condition with the answer of the API
// server. Each other failure stays an error with a retry.
func createProblem(kind string, key client.ObjectKey, err error) error {
	if apierrors.IsForbidden(err) || apierrors.IsInvalid(err) || apierrors.IsBadRequest(err) {
		return &machineProblem{
			reason:  infrav1.CreateRejectedReason,
			message: fmt.Sprintf("The API server rejected %s %s: %v", kind, key, err),
		}
	}
	return fmt.Errorf("failed to create %s %s: %w", kind, key, err)
}

// resourceLabels returns the labels of every object that the provider makes
// for a machine.
func resourceLabels(machine *infrav1.PodVMMachine, ownerMachine *clusterv1.Machine) map[string]string {
	return map[string]string{
		clusterv1.ClusterNameLabel:  ownerMachine.Spec.ClusterName,
		infrav1.MachineNameLabel:    ownerMachine.Name,
		infrav1.OwnerNamespaceLabel: machine.Namespace,
		infrav1.OwnerNameLabel:      machine.Name,
		infrav1.OwnerUIDLabel:       string(machine.UID),
	}
}

// podKey returns the place of the pod that the status of the machine records.
func podKey(machine *infrav1.PodVMMachine) client.ObjectKey {
	return client.ObjectKey{Namespace: machine.Status.PodNamespace, Name: machine.Status.PodName}
}

// ownedPod returns the pod of the machine, or nil when it does not exist. A
// pod with that name that belongs to something else is a problem.
func (r *MachineReconciler) ownedPod(ctx context.Context, machine *infrav1.PodVMMachine) (*corev1.Pod, error) {
	key := podKey(machine)
	pod := &corev1.Pod{}
	if err := r.client.Get(ctx, key, pod); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("failed to get Pod %s: %w", key, err)
	}
	if !ownedBy(pod, machine) {
		return nil, resourceConflict("Pod", key)
	}
	return pod, nil
}

// nodeAgentAnswers reports whether the startup probe of the pod passed: the
// container "node" is started, so the node agent accepts connections.
func nodeAgentAnswers(pod *corev1.Pod) bool {
	for i := range pod.Status.ContainerStatuses {
		status := &pod.Status.ContainerStatuses[i]
		if status.Name == nodeContainerName {
			return ptr.Deref(status.Started, false)
		}
	}
	return false
}

// createPodResources makes what a pod needs and then the pod: the copy of the
// bootstrap Secret, the two volume claims, the pod. Each step leaves an object
// that exists as it is, so the pod of a lost pod gets the claims and the
// Secret of the pod before it.
func (r *MachineReconciler) createPodResources(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	ownerMachine *clusterv1.Machine,
	infraCluster *infrav1.PodVMCluster,
	logger *slog.Logger,
) error {
	labels := resourceLabels(machine, ownerMachine)

	if err := r.ensureBootstrapSecret(ctx, machine, ownerMachine, labels, logger); err != nil {
		return err
	}
	for _, claim := range []*corev1.PersistentVolumeClaim{
		buildClaim(machine, varClaimName(machine.Status.PodName), machine.Spec.Volumes.Var, labels),
		buildClaim(machine, etcdClaimName(machine.Status.PodName), machine.Spec.Volumes.Etcd, labels),
	} {
		if err := r.ensureClaim(ctx, machine, claim, logger); err != nil {
			return err
		}
	}

	pod, err := buildPod(machine, ownerMachine, infraCluster, labels)
	if err != nil {
		return err
	}
	if err := r.client.Create(ctx, pod); err != nil {
		if !apierrors.IsAlreadyExists(err) {
			return createProblem("Pod", client.ObjectKeyFromObject(pod), err)
		}
		// The cache did not show a pod that exists. It is either the pod this
		// provider made a moment ago, or a pod of something else.
		existing := &corev1.Pod{}
		key := client.ObjectKeyFromObject(pod)
		if err := r.apiReader.Get(ctx, key, existing); err != nil {
			return fmt.Errorf("failed to get Pod %s: %w", key, err)
		}
		if !ownedBy(existing, machine) {
			return resourceConflict("Pod", key)
		}
		return nil
	}

	logger.Info("Made the pod of the machine",
		"pod", pod.Name, "podNamespace", pod.Namespace, "address", machine.Status.Address,
		"failureDomain", ownerMachine.Spec.FailureDomain,
	)
	return nil
}

// ensureBootstrapSecret copies the bootstrap data of the owner Machine into
// the pod namespace, where the pod can mount it.
//
// It copies one time. A copy that exists stays as it is: the node applied the
// data at its first start, the join token in it worked one time, and the NVKE
// controller deletes the source when it deletes the Machine.
func (r *MachineReconciler) ensureBootstrapSecret(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	ownerMachine *clusterv1.Machine,
	labels map[string]string,
	logger *slog.Logger,
) error {
	key := client.ObjectKey{Namespace: machine.Status.PodNamespace, Name: bootstrapSecretName(machine.Status.PodName)}
	existing := &corev1.Secret{}
	err := r.apiReader.Get(ctx, key, existing)
	if err == nil {
		if !ownedBy(existing, machine) {
			return resourceConflict("Secret", key)
		}
		return nil
	}
	if !apierrors.IsNotFound(err) {
		return fmt.Errorf("failed to get Secret %s: %w", key, err)
	}

	sourceKey := client.ObjectKey{
		Namespace: ownerMachine.Namespace,
		Name:      ptr.Deref(ownerMachine.Spec.Bootstrap.DataSecretName, ""),
	}
	if sourceKey.Name == "" {
		return &machineProblem{
			reason:  infrav1.WaitingForBootstrapDataReason,
			message: "Waiting for spec.bootstrap.dataSecretName of the owner Machine",
		}
	}
	source := &corev1.Secret{}
	if err := r.apiReader.Get(ctx, sourceKey, source); err != nil {
		if apierrors.IsNotFound(err) {
			return &machineProblem{
				reason:  infrav1.BootstrapDataNotFoundReason,
				message: fmt.Sprintf("Bootstrap data Secret %s does not exist, and the pod namespace holds no copy", sourceKey),
			}
		}
		return fmt.Errorf("failed to get the bootstrap data Secret %s: %w", sourceKey, err)
	}
	value := source.Data[bootstrapDataKey]
	if len(value) == 0 {
		return &machineProblem{
			reason:  infrav1.BootstrapDataNotFoundReason,
			message: fmt.Sprintf("Bootstrap data Secret %s has no %q data", sourceKey, bootstrapDataKey),
		}
	}

	secretCopy := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Namespace: key.Namespace, Name: key.Name, Labels: labels},
		Type:       corev1.SecretTypeOpaque,
		Data:       map[string][]byte{bootstrapDataKey: value},
	}
	if err := r.client.Create(ctx, secretCopy); err != nil {
		// Also for "already exists": the next reconcile reads the object and
		// checks whose it is before a pod mounts it.
		return createProblem("Secret", key, err)
	}
	logger.Info("Copied the bootstrap data into the pod namespace", "secret", key.Name, "podNamespace", key.Namespace)
	return nil
}

// ensureClaim makes one volume claim when it does not exist. A claim that
// exists stays as it is: it holds the state of the node.
func (r *MachineReconciler) ensureClaim(
	ctx context.Context,
	machine *infrav1.PodVMMachine,
	claim *corev1.PersistentVolumeClaim,
	logger *slog.Logger,
) error {
	key := client.ObjectKeyFromObject(claim)
	existing := &corev1.PersistentVolumeClaim{}
	err := r.apiReader.Get(ctx, key, existing)
	if err == nil {
		if !ownedBy(existing, machine) {
			return resourceConflict("PersistentVolumeClaim", key)
		}
		return nil
	}
	if !apierrors.IsNotFound(err) {
		return fmt.Errorf("failed to get PersistentVolumeClaim %s: %w", key, err)
	}

	if err := r.client.Create(ctx, claim); err != nil {
		return createProblem("PersistentVolumeClaim", key, err)
	}
	logger.Info("Made a volume claim", "claim", key.Name, "podNamespace", key.Namespace)
	return nil
}

// buildClaim builds one volume claim with the volume mode Block. The node
// image makes the filesystem, so the provider never asks for one.
func buildClaim(
	machine *infrav1.PodVMMachine,
	name string,
	volume infrav1.PodVMVolume,
	labels map[string]string,
) *corev1.PersistentVolumeClaim {
	claim := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Namespace: machine.Status.PodNamespace, Name: name, Labels: labels},
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
			VolumeMode:  ptr.To(corev1.PersistentVolumeBlock),
			Resources: corev1.VolumeResourceRequirements{
				Requests: corev1.ResourceList{corev1.ResourceStorage: volume.Size.DeepCopy()},
			},
		},
	}
	if volume.StorageClassName != "" {
		claim.Spec.StorageClassName = ptr.To(volume.StorageClassName)
	}
	return claim
}

// buildPod builds the pod of a machine. Everything in it is a function of the
// machine, its owner and the cluster, so a new pod for the same machine is the
// same pod: same name, same claims, same address, same hardware address.
func buildPod(
	machine *infrav1.PodVMMachine,
	ownerMachine *clusterv1.Machine,
	infraCluster *infrav1.PodVMCluster,
	labels map[string]string,
) (*corev1.Pod, error) {
	podName := machine.Status.PodName
	nodeAddress := fmt.Sprintf("%s/%d", machine.Status.Address, infraCluster.Spec.AddressRange.PrefixLength)

	networks, err := json.Marshal([]networkSelection{{
		Name:      infraCluster.Spec.NetworkAttachment.Name,
		Namespace: infraCluster.NetworkAttachmentNamespace(),
		IPs:       []string{nodeAddress},
		MAC:       machine.Status.HardwareAddress,
	}})
	if err != nil {
		return nil, fmt.Errorf("failed to encode the network annotation of Pod %s: %w", podName, err)
	}

	podLabels := make(map[string]string, len(labels)+1)
	for key, value := range labels {
		podLabels[key] = value
	}
	controlPlaneValue, isControlPlane := ownerMachine.Labels[clusterv1.MachineControlPlaneLabel]
	if isControlPlane {
		podLabels[clusterv1.MachineControlPlaneLabel] = controlPlaneValue
	}

	container := corev1.Container{
		Name:            nodeContainerName,
		Image:           machine.Spec.Image,
		ImagePullPolicy: machine.Spec.ImagePullPolicy,
		SecurityContext: &corev1.SecurityContext{Privileged: ptr.To(true)},
		Env: []corev1.EnvVar{
			{Name: machineNameEnv, Value: ownerMachine.Name},
			{Name: nodeAddressEnv, Value: nodeAddress},
			{Name: nodeInterfaceEnv, Value: nodeInterface},
		},
		// Requests are equal to limits. The Kata runtime sizes the virtual
		// machine from the limits.
		Resources: corev1.ResourceRequirements{
			Limits:   machineResourceList(machine.Spec.Resources),
			Requests: machineResourceList(machine.Spec.Resources),
		},
		VolumeDevices: []corev1.VolumeDevice{
			{Name: varVolumeName, DevicePath: varDevicePath},
			{Name: etcdVolumeName, DevicePath: etcdDevicePath},
		},
		VolumeMounts: []corev1.VolumeMount{
			{Name: bootstrapVolumeName, MountPath: bootstrapMountPath, ReadOnly: true},
		},
		// For each machine, control plane or not: the node agent runs on
		// every node.
		StartupProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{TCPSocket: &corev1.TCPSocketAction{
				Port: intstr.FromInt32(nodeAgentPort),
			}},
			PeriodSeconds:    startupPeriodSeconds,
			FailureThreshold: startupFailureThreshold,
		},
	}
	if isControlPlane {
		container.ReadinessProbe = &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{Exec: &corev1.ExecAction{
				Command: []string{endpointReadyCommand},
			}},
			PeriodSeconds:    readinessPeriodSeconds,
			TimeoutSeconds:   readinessTimeoutSeconds,
			FailureThreshold: readinessFailureThreshold,
		}
	}

	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:   machine.Status.PodNamespace,
			Name:        podName,
			Labels:      podLabels,
			Annotations: map[string]string{networksAnnotation: string(networks)},
		},
		Spec: corev1.PodSpec{
			RuntimeClassName: ptr.To(infraCluster.Spec.RuntimeClassName),
			// The node needs no token of the host cluster and no Service
			// variables of the pod namespace.
			AutomountServiceAccountToken:  ptr.To(false),
			EnableServiceLinks:            ptr.To(false),
			RestartPolicy:                 corev1.RestartPolicyAlways,
			TerminationGracePeriodSeconds: ptr.To(int64(podTerminationGracePeriodSeconds)),
			Affinity:                      podAffinity(ownerMachine, infraCluster),
			Containers:                    []corev1.Container{container},
			Volumes: []corev1.Volume{
				{Name: varVolumeName, VolumeSource: corev1.VolumeSource{
					PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: varClaimName(podName)},
				}},
				{Name: etcdVolumeName, VolumeSource: corev1.VolumeSource{
					PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: etcdClaimName(podName)},
				}},
				{Name: bootstrapVolumeName, VolumeSource: corev1.VolumeSource{
					Secret: &corev1.SecretVolumeSource{
						SecretName: bootstrapSecretName(podName),
						Items:      []corev1.KeyToPath{{Key: bootstrapDataKey, Path: bootstrapDataKey}},
					},
				}},
			},
		},
	}, nil
}

// machineResourceList returns the CPU and the memory of a machine as a
// resource list of its own, so limits and requests share no quantity.
func machineResourceList(resources infrav1.PodVMResources) corev1.ResourceList {
	return corev1.ResourceList{
		corev1.ResourceCPU:    resources.CPU.DeepCopy(),
		corev1.ResourceMemory: resources.Memory.DeepCopy(),
	}
}

// podAffinity places a pod.
//
// The failure domain of the Machine becomes a required node rule. The value
// names a value of the failure domain label of the cluster, or a host node
// when the cluster published its host nodes as failure domains. The rule
// accepts both, so it does not depend on which of the two the cluster
// published at the time.
//
// The pods of one cluster prefer different host nodes. The rule is a
// preference: a strict rule would keep the extra pod of a rollout from
// starting when every host node already has a pod.
func podAffinity(ownerMachine *clusterv1.Machine, infraCluster *infrav1.PodVMCluster) *corev1.Affinity {
	affinity := &corev1.Affinity{
		PodAntiAffinity: &corev1.PodAntiAffinity{
			PreferredDuringSchedulingIgnoredDuringExecution: []corev1.WeightedPodAffinityTerm{{
				Weight: 100,
				PodAffinityTerm: corev1.PodAffinityTerm{
					LabelSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{clusterv1.ClusterNameLabel: ownerMachine.Spec.ClusterName},
					},
					TopologyKey: infrav1.HostNameLabelKey,
				},
			}},
		},
	}

	failureDomain := ownerMachine.Spec.FailureDomain
	if failureDomain == "" {
		return affinity
	}

	labelKeys := []string{infraCluster.FailureDomainLabelKey()}
	if labelKeys[0] != infrav1.HostNameLabelKey {
		labelKeys = append(labelKeys, infrav1.HostNameLabelKey)
	}
	// Node selector terms are alternatives: a node matches when one of them
	// matches.
	terms := make([]corev1.NodeSelectorTerm, 0, len(labelKeys))
	for _, labelKey := range labelKeys {
		terms = append(terms, corev1.NodeSelectorTerm{
			MatchExpressions: []corev1.NodeSelectorRequirement{{
				Key:      labelKey,
				Operator: corev1.NodeSelectorOpIn,
				Values:   []string{failureDomain},
			}},
		})
	}
	affinity.NodeAffinity = &corev1.NodeAffinity{
		RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{NodeSelectorTerms: terms},
	}
	return affinity
}
