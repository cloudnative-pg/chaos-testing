#!/usr/bin/env bash

# Monitor CloudNativePG pods during chaos experiments
# Usage: ./scripts/monitor-cnpg-pods.sh [cluster-name] [namespace]

set -euo pipefail

CLUSTER_NAME=${1:-pg-eu}
NAMESPACE=${2:-default}

echo "Monitoring CloudNativePG cluster: $CLUSTER_NAME in namespace: $NAMESPACE"
echo "Press Ctrl+C to stop"
echo ""

# Watch command with color and formatting
watch -n 2 -c "
echo '=== CloudNativePG Cluster: $CLUSTER_NAME ==='
echo ''
kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME \
  -o custom-columns=\
NAME:.metadata.name,\
ROLE:.metadata.labels.'cnpg\.io/instanceRole',\
STATUS:.status.phase,\
READY:.status.conditions[?\(@.type==\'Ready\'\)].status,\
RESTARTS:.status.containerStatuses[0].restartCount,\
AGE:.metadata.creationTimestamp \
  --sort-by=.metadata.name

echo ''
echo '=== Active Chaos Experiments ==='
kubectl get chaosengine -n $NAMESPACE -l context=cloudnativepg-failover-testing -o wide 2>/dev/null || echo 'No active chaos engines'

echo ''
echo '=== Recent Events ==='
kubectl get events -n $NAMESPACE --field-selector involvedObject.kind=Pod \
  --sort-by=.lastTimestamp | grep $CLUSTER_NAME | tail -5 || echo 'No recent events'
"
