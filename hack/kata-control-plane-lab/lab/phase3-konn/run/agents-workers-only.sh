# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The agent on the workers only, for a comparison (the first form of the design). One patch of the
# agent DaemonSet in the NEW cluster: a node affinity for nodes with no control plane label.
D=/root/kata-cp/logs/p3/k-3
gk() { /root/kata-cp/bin/kubectl --kubeconfig /root/kata-cp/secrets/d-k-3/kubeconfig-kata-cp1 --request-timeout=40s "$@"; }
{
echo "== agents on the workers only, at $(date -u +%FT%TZ)"
gk -n kube-system patch daemonset konnectivity-agent --type=json -p '[{"op":"add","path":"/spec/template/spec/affinity","value":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/control-plane","operator":"DoesNotExist"}]}]}}}}]' | tail -1
gk -n kube-system rollout status daemonset/konnectivity-agent --timeout=150s | tail -1
sleep 25
gk -n kube-system get pods -l k8s-app=konnectivity-agent -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready --no-headers
p=$(awk '$3=="cp" {print $1; exit}' "$D/tnodes.txt")
while read -r i name role ip; do
  [ "$role" = cp ] || continue
  srv="https://$ip:6443"
  for wi in $(awk '$3=="worker" {print $1}' "$D/tnodes.txt"); do
    okp=0; oks=0
    for _ in 1 2 3 4 5 6; do
      case "$(gk --server "$srv" get --raw "/api/v1/namespaces/default/pods/p3-t-$wi:8080/proxy/ping.py" </dev/null 2>&1 | head -1)" in "# ICMP echo"*) okp=$((okp + 1)) ;; esac
      case "$(gk --server "$srv" get --raw "/api/v1/namespaces/default/services/p3-t-$wi:80/proxy/ping.py" </dev/null 2>&1 | head -1)" in "# ICMP echo"*) oks=$((oks + 1)) ;; esac
    done
    echo "API server of $name to the pod p3-t-$wi on a worker: pod proxy $okp of 6, Service proxy $oks of 6; logs [$(gk --server "$srv" -n default logs "p3-t-$wi" --tail=1 </dev/null 2>&1 | tail -1 | cut -c1-60)]"
  done
  echo "API server of $name: logs of the pod p3-t-$p on a control plane node: [$(gk --server "$srv" -n default logs "p3-t-$p" --tail=1 </dev/null 2>&1 | tail -1 | cut -c1-200)]"
  echo "API server of $name: pod proxy to the pod p3-t-$p on a control plane node: [$(gk --server "$srv" get --raw "/api/v1/namespaces/default/pods/p3-t-$p:8080/proxy/ping.py" </dev/null 2>&1 | head -1 | cut -c1-160)]"
done <"$D/tnodes.txt"
} 2>&1 | tee "$D/agents-workers-only.txt"
