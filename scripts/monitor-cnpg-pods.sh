#!/usr/bin/env bash

# Monitor CloudNativePG pods during chaos experiments
# Usage: ./scripts/monitor-cnpg-pods.sh [cluster-name] [namespace] [chaos-namespace] [kube-context]

set -euo pipefail

CLUSTER_NAME=${1:-pg-eu}
NAMESPACE=${2:-default}
CHAOS_NAMESPACE=${3:-litmus}
KUBE_CONTEXT=${4:-}
CTX_ARG="${KUBE_CONTEXT:+--context $KUBE_CONTEXT}"

echo "Monitoring CloudNativePG cluster: $CLUSTER_NAME in namespace: $NAMESPACE"
echo "Press Ctrl+C to stop"
echo ""

# Watch command with color and formatting
watch -n 2 -c "
echo '=== CloudNativePG Cluster: $CLUSTER_NAME ==='
echo ''
kubectl $CTX_ARG get pods -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME \
  -o custom-columns=\
NAME:.metadata.name,\
ROLE:.metadata.labels.'cnpg\.io/instanceRole',\
STATUS:.status.phase,\
READY:.status.conditions[?\(@.type==\'Ready\'\)].status,\
RESTARTS:.status.containerStatuses[0].restartCount,\
AGE:.metadata.creationTimestamp \
  --sort-by=.metadata.name

echo ''
echo '=== Active Chaos Experiments (namespace: $CHAOS_NAMESPACE) ==='
kubectl $CTX_ARG get chaosengine -n $CHAOS_NAMESPACE -l context=cloudnativepg-failover-testing -o wide 2>/dev/null || echo 'No active chaos engines'

echo ''
echo '=== Recent Events ==='
kubectl $CTX_ARG get events -n $NAMESPACE --field-selector involvedObject.kind=Pod \
  --sort-by=.lastTimestamp | grep $CLUSTER_NAME | tail -5 || echo 'No recent events'
"
