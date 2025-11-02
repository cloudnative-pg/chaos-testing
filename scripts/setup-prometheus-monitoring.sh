#!/usr/bin/env bash

set -euo pipefail

NAMESPACE=${NAMESPACE:-default}
CLUSTER_NAME=${CLUSTER_NAME:-pg-eu}
PODMONITOR_FILE=${PODMONITOR_FILE:-monitoring/podmonitor-pg-eu.yaml}

echo "Applying PodMonitor for cluster '${CLUSTER_NAME}' in namespace '${NAMESPACE}'"
kubectl apply -f "$PODMONITOR_FILE"

cat <<EOF

Assumptions for promProbe endpoint:
- Using kube-prometheus-stack: endpoint is usually http://prometheus-k8s.monitoring.svc:9090
- If your Prometheus service name/namespace differs, edit the experiments under experiments/*.yaml and replace the promProbe endpoint values.

To verify metrics are being scraped:
- Check Prometheus targets UI or run:
  kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus
- Ensure a PodMonitor exists: kubectl get podmonitor -A | grep ${CLUSTER_NAME}
- Port-forward a CNPG pod and curl metrics: kubectl port-forward ${CLUSTER_NAME}-1 9187:9187 & curl -s localhost:9187/metrics | head

EOF
