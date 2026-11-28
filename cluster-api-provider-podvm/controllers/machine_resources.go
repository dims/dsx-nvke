// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"encoding/json"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"

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
