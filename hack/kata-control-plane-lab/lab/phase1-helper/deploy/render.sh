#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Print the manifests of nvke-lab-bootstrap-helper. Use: HOSTS_NS=<namespace> ./render.sh | kubectl apply -f -
#
#   HOSTS_NS     namespace of the host pods (necessary). The helper gets pods/exec there
#   CAPI_NS      namespace of the ProvisionedMachines, the Machines and the bootstrap Secrets.
#                NVKE uses its management namespace, the chart value nvkeSystemNamespace.name
#   HELPER_NS    namespace of the helper. The manifest makes it
#   IMAGE        image name in the node
#   HOST_LABEL   label of a host pod. Its value is the hostname of the host in the inventory
#   CONTAINER    container of the host pod
#   STATIC_CONFIGMAP   test input only: a ConfigMap in HELPER_NS with the key machines.yaml.
#                      The helper then reads no ProvisionedMachine and no Machine
#
# The manifest makes no object in CAPI_NS or HOSTS_NS other than one Role and one RoleBinding.
# The helper has no host network, no hostPath volume, no privilege and no listener.
set -o errexit -o nounset -o pipefail

: "${HOSTS_NS:?set HOSTS_NS to the namespace of the host pods}"
CAPI_NS=${CAPI_NS:-nvke-system}
HELPER_NS=${HELPER_NS:-nvke-lab-bootstrap-helper}
IMAGE=${IMAGE:-docker.io/library/nvke-lab-bootstrap-helper:dev}
HOST_LABEL=${HOST_LABEL:-nvke.lab/host}
CONTAINER=${CONTAINER:-node}
STATIC_CONFIGMAP=${STATIC_CONFIGMAP:-}

static_arg=""
static_mount=""
static_volume=""
if [ -n "$STATIC_CONFIGMAP" ]; then
  static_arg='            - --static-file=/etc/nvke-lab-bootstrap-helper/machines.yaml'
  static_mount='          volumeMounts:
            - {name: static, mountPath: /etc/nvke-lab-bootstrap-helper, readOnly: true}'
  static_volume="      volumes:
        - name: static
          configMap: {name: ${STATIC_CONFIGMAP}}"
fi

cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${HELPER_NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nvke-lab-bootstrap-helper
  namespace: ${HELPER_NS}
---
# Read the machines and the bootstrap Secrets. A Role cannot name Secrets by a pattern, so
# the helper can get each Secret of this namespace by its name. It cannot list them.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nvke-lab-bootstrap-helper-capi
  namespace: ${CAPI_NS}
rules:
  - apiGroups: ["infrastructure.cluster.x-k8s.io"]
    resources: ["provisionedmachines"]
    verbs: ["list"]
  - apiGroups: ["cluster.x-k8s.io"]
    resources: ["machines"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nvke-lab-bootstrap-helper-capi
  namespace: ${CAPI_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: nvke-lab-bootstrap-helper-capi
subjects:
  - kind: ServiceAccount
    name: nvke-lab-bootstrap-helper
    namespace: ${HELPER_NS}
---
# Find the host pods and run the apply script in them.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nvke-lab-bootstrap-helper-hosts
  namespace: ${HOSTS_NS}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nvke-lab-bootstrap-helper-hosts
  namespace: ${HOSTS_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: nvke-lab-bootstrap-helper-hosts
subjects:
  - kind: ServiceAccount
    name: nvke-lab-bootstrap-helper
    namespace: ${HELPER_NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nvke-lab-bootstrap-helper
  namespace: ${HELPER_NS}
  labels: {app: nvke-lab-bootstrap-helper}
spec:
  replicas: 1
  # One helper at a time: the old pod stops before the new pod starts.
  strategy: {type: Recreate}
  selector:
    matchLabels: {app: nvke-lab-bootstrap-helper}
  template:
    metadata:
      labels: {app: nvke-lab-bootstrap-helper}
    spec:
      serviceAccountName: nvke-lab-bootstrap-helper
      enableServiceLinks: false
      terminationGracePeriodSeconds: 10
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: helper
          image: ${IMAGE}
          imagePullPolicy: Never
          args:
            - --capi-namespace=${CAPI_NS}
            - --hosts-namespace=${HOSTS_NS}
            - --host-label=${HOST_LABEL}
            - --container=${CONTAINER}
${static_arg}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 10m, memory: 32Mi}
            limits: {memory: 128Mi}
${static_mount}
${static_volume}
EOF
