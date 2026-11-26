#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Install the guest kernel with Open vSwitch as ONE MORE handler and RuntimeClass, next to the present
# ones: kata-clh-runtime-rs-fix-direct-ovs = the class of record (patched guest image, direct I/O) with
# the kernel /opt/kata-fix/vmlinux-6.18.62-211-ovs. The stock kernel, the stock handlers and the other
# lab handlers stay as they are. One more entry goes into the imports line of containerd in each node,
# and containerd restarts one time in each node (running pods continue).
# Removal: kubectl delete runtimeclass kata-clh-runtime-rs-fix-direct-ovs; in each node take
#   "/opt/kata-fix/containerd-kata-ovs.toml" out of the imports line of /etc/containerd/config.toml, restart
#   containerd, rm /opt/kata-fix/{vmlinux-6.18.62-211-ovs,config-6.18.62-211-ovs,configuration-clh-runtime-rs-fix-direct-ovs.toml,containerd-kata-ovs.toml}
set -euo pipefail
. /root/kata-cp/bin/env.sh
SRC=$W/kbuild/out/opt/kata/share/kata-containers
D=/opt/kata-fix
H=kata-clh-runtime-rs-fix-direct-ovs
sha256sum "$SRC/vmlinux-6.18.62-211" "$SRC/config-6.18.62-211"
cat >"$W/c3/containerd-kata-ovs.toml" <<TOML
# Runtime handler for the Kata guest kernel with Open vSwitch built in (lab, block C3).
# A copy of the handler kata-clh-runtime-rs-fix-direct with another ConfigPath.
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.$H]
runtime_type = "io.containerd.$H.v2"
runtime_path = "/opt/kata/runtime-rs/bin/containerd-shim-kata-v2"
privileged_without_host_devices = true
pod_annotations = ["io.katacontainers.config.hypervisor.default_memory", "io.katacontainers.config.hypervisor.default_vcpus", "io.katacontainers.config.hypervisor.enable_iommu", "io.katacontainers.config.hypervisor.kernel_params", "io.katacontainers.config.hypervisor.kernel_verity_params"]
container_annotations = ["io.kubernetes.container.terminationMessage*"]

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.$H.options]
ConfigPath = "$D/configuration-clh-runtime-rs-fix-direct-ovs.toml"
TOML
for NODE in $NODES; do
  n() { docker exec "$NODE" "$@"; }
  echo "===== $NODE"
  docker cp -q "$SRC/vmlinux-6.18.62-211" "$NODE:$D/vmlinux-6.18.62-211-ovs"
  docker cp -q "$SRC/config-6.18.62-211" "$NODE:$D/config-6.18.62-211-ovs"
  n sh -c "chown root:root $D/vmlinux-6.18.62-211-ovs $D/config-6.18.62-211-ovs; chmod 644 $D/vmlinux-6.18.62-211-ovs"
  n sh -c "sed 's|^kernel = .*|kernel = \"$D/vmlinux-6.18.62-211-ovs\"|' $D/configuration-clh-runtime-rs-fix-direct.toml >$D/configuration-clh-runtime-rs-fix-direct-ovs.toml; diff $D/configuration-clh-runtime-rs-fix-direct.toml $D/configuration-clh-runtime-rs-fix-direct-ovs.toml; true"
  docker cp -q "$W/c3/containerd-kata-ovs.toml" "$NODE:$D/containerd-kata-ovs.toml"
  n sh -c "grep -q '$D/containerd-kata-ovs.toml' /etc/containerd/config.toml || sed -i 's|, \"$D/containerd-kata-fix.toml\"\]|, \"$D/containerd-kata-fix.toml\", \"$D/containerd-kata-ovs.toml\"]|' /etc/containerd/config.toml"
  n grep -n '^imports' /etc/containerd/config.toml
  n grep -q "$D/containerd-kata-ovs.toml" /etc/containerd/config.toml || { echo "the imports line was not changed"; exit 1; }
  [ "$(n sh -c "containerd config dump 2>/dev/null | grep -c -E 'runtimes.$H\]$'")" = 1 ] || { echo "the handler is not in the merged configuration"; exit 1; }
  n systemctl restart containerd
  for _ in $(seq 60); do n crictl info >/dev/null 2>&1 && break; sleep 1; done
  n sh -c "crictl info | grep -o '\"$H\"' | sort -u"
done
cat <<YAML | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: $H
  labels: {lab.kata-fix: "true"}
handler: $H
overhead: {podFixed: {cpu: 250m, memory: 512Mi}}
scheduling: {nodeSelector: {katacontainers.io/kata-runtime: "true"}}
YAML
sleep 5
kubectl get nodes --no-headers | awk '{print $1, $2}' | tr '\n' ';'; echo
echo "== test pod with the new class on each worker"
for n in $WORKERS; do
  p=ovs-kernel-test-${n#kata-bb-}
  kubectl delete pod "$p" --ignore-not-found --wait=true >/dev/null 2>&1
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $p, labels: {lab: ovs-kernel-test}}
spec:
  runtimeClassName: $H
  restartPolicy: Never
  nodeSelector: {kubernetes.io/hostname: $n}
  terminationGracePeriodSeconds: 2
  containers:
    - name: c
      image: docker.io/$NODE_IMAGE
      imagePullPolicy: Never
      securityContext: {privileged: true}
      command: ["sh", "-c", "echo kernel \$(uname -r) \$(uname -v); echo openvswitch symbols in the kernel: \$(grep -c ' ovs_' /proc/kallsyms); echo /sys/module/openvswitch: \$(ls -d /sys/module/openvswitch 2>&1); ip link add gnv-test type geneve id 7 remote 192.0.2.1 && echo geneve link made: \$(ip -d link show gnv-test | grep -o 'geneve id [0-9]*') && ip link del gnv-test; sleep 3600"]
      resources: {limits: {cpu: "1", memory: 512Mi}}
YAML
done
for n in $WORKERS; do
  p=ovs-kernel-test-${n#kata-bb-}
  kubectl wait --for=condition=Ready "pod/$p" --timeout=180s >/dev/null 2>&1 || echo "FAIL: $p not ready"
  echo "$n: $(kubectl logs "$p" | tr '\n' ';')"
done
kubectl delete pod -l lab=ovs-kernel-test --wait=true >/dev/null 2>&1
echo "KERNEL INSTALL DONE"
