# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# after-delete <run>: what is left after the DELETE of the cluster of a run (read only).
run=$1; D=/root/kata-cp/logs/p3/$run
K="/root/kata-cp/bin/kubectl --kubeconfig /root/kata-cp/secrets/kubeconfig"
since=$(cut -c1-19 "$D/post-time.txt")Z
{
echo "== after the DELETE of $run, at $(date -u +%FT%TZ)"
grep -E "DELETE through|RESULT delete|^ok |^FAIL" "$D/delete.out" | cut -c1-200
echo "worker containers: [$(docker ps -a --filter label=nvidia.com/nico-containers.managed=true --format '{{.Names}}={{.State}}' | tr '\n' ' ')]"
echo "instances of the simulator: $(docker exec kata-bb-control-plane curl -sS --max-time 5 -H 'Authorization: Bearer example-token' http://172.29.2.5:18080/v2/org/novxwn552ssc/forge/instance | jq -c '[.[] | {name, status}]')"
echo "simulator calls that change an instance: $(docker logs p3-nico-sim 2>&1 | grep -E 'method=(POST|PATCH|DELETE)' | sed -E 's/^(..:..:..) .*method=([A-Z]+) path=[^ ]* status=([0-9]+).*/\1 \2 \3/' | tr '\n' ';')"
echo "objects in nvke-system: [$($K -n nvke-system get clusters.cluster.x-k8s.io,machines.cluster.x-k8s.io,podvmclusters,podvmmachines,nicomachines,nicoclusters -o name 2>&1 | tr '\n' ' ')]"
echo "Secrets in nvke-system with the cluster name: [$($K -n nvke-system get secrets -o name 2>&1 | grep -c kata-cp1)]"
echo "Docker rules for a worker address: $(iptables-save 2>/dev/null | grep -E -- '-d 172\.2[89]\.' | grep -v -E '172\.29\.2\.5/|172\.29\.0\.[2-5]/|172\.28\.0\.[2-5]/' | grep -c DROP)"
echo "pods in d: [$($K -n d get pods -o name 2>&1 | tr '\n' ' ')] claims in d: [$($K -n d get pvc -o name 2>&1 | tr '\n' ' ')]"
echo "lab volumes: $($K get pv -l podvm.lab/use --no-headers 2>&1 | awk '{print $5}' | sort | uniq -c | tr '\n' ' ')"
echo "objects of CAPNICo in each namespace: [$($K get nicomachines,nicoclusters,nicomachinetemplates -A -o name 2>&1 | tr '\n' ' ')]"
echo "objects of the pod provider in each namespace: [$($K get podvmmachines,podvmclusters,podvmmachinetemplates -A -o name 2>&1 | tr '\n' ' ')]"
echo "containers on kata-bb-node: [$(docker network inspect kata-bb-node --format '{{range .Containers}}{{.Name}} {{end}}')]"
echo "containers on kata-bb: [$(docker network inspect kata-bb --format '{{range .Containers}}{{.Name}} {{end}}')]"
echo "Docker containers that are not the kind nodes or the simulator and are younger than this day: [$(docker ps -a --format '{{.Names}} {{.CreatedAt}}' | grep -v -E '^(kata-bb-|p3-nico-sim )' | grep "$(date +%F)" | cut -d' ' -f1 | tr '\n' ' ')]"
echo "Docker volumes with no container: $(docker volume ls -q -f dangling=true | wc -l) (1 before phase 3, an old named volume)"
echo "SPIRE entries of hosts: $($K get clusterstaticentry -o name 2>/dev/null | grep -c 'host-' || true)"
echo "workflows since the POST ($since):"
$K -n temporal exec deploy/temporal-admintools -- temporal workflow list --query "StartTime > \"$since\"" --limit 60 --namespace cloud-workflow-engine --address temporal-frontend.temporal.svc.cluster.local:7233 2>&1 | awk 'NR>1 {print $1, $3}' | sort | uniq -c | tr '\n' ';'
echo
echo "workflows that still run: $($K -n temporal exec deploy/temporal-admintools -- temporal workflow list --query 'ExecutionStatus="Running"' --namespace cloud-workflow-engine --address temporal-frontend.temporal.svc.cluster.local:7233 2>&1 | awk 'NR>1' | wc -l)"
} 2>&1 | tee "$D/after-delete.txt" | cut -c1-420
