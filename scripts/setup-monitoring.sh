#!/bin/bash
# One-time setup script for CNPG monitoring with Prometheus
# This script only needs to be run once per cluster

set -e

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CLUSTER_NAME=${1:-pg-eu}
NAMESPACE=${2:-default}

# Functions
log() {
  echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ $1${NC}"
}

log_section() {
  echo ""
  echo "=========================================="
  echo -e "${BLUE}$1${NC}"
  echo "=========================================="
  echo ""
}

# Main execution
clear
log_section "CNPG Monitoring Setup (One-Time Configuration)"

echo "Configuration:"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  Namespace:    $NAMESPACE"
echo ""

# Step 1: Check Prometheus installation
log_section "Step 1: Verify Prometheus Installation"

log "Checking for Prometheus service..."
if kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus &>/dev/null; then
  log_success "Prometheus service found"
  
  # Check Prometheus pods
  PROM_PODS=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$PROM_PODS" -gt 0 ]; then
    log_success "Prometheus is running ($PROM_PODS pod(s))"
  else
    log_error "Prometheus pods are not running"
    exit 1
  fi
else
  log_error "Prometheus not found in 'monitoring' namespace"
  echo ""
  echo "Please install Prometheus first using:"
  echo "  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
  echo "  helm repo update"
  echo "  helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace"
  exit 1
fi

# Step 2: Check for PodMonitor CRD
log_section "Step 2: Verify PodMonitor CRD"

log "Checking for PodMonitor CRD..."
if kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
  log_success "PodMonitor CRD exists"
else
  log_error "PodMonitor CRD not found - Prometheus Operator may not be installed correctly"
  exit 1
fi

# Step 3: Check CNPG cluster exists
log_section "Step 3: Verify CNPG Cluster"

log "Checking for cluster: $CLUSTER_NAME"
if kubectl get cluster $CLUSTER_NAME -n $NAMESPACE &>/dev/null; then
  log_success "CNPG cluster '$CLUSTER_NAME' found"
  
  # Check pod count
  POD_COUNT=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$POD_COUNT" -gt 0 ]; then
    log_success "$POD_COUNT pod(s) running in cluster"
  else
    log_warn "No running pods found in cluster"
  fi
else
  log_error "CNPG cluster '$CLUSTER_NAME' not found in namespace '$NAMESPACE'"
  exit 1
fi

# Step 4: Create or update PodMonitor
log_section "Step 4: Configure PodMonitor"

log "Checking if PodMonitor already exists..."
if kubectl get podmonitor cnpg-${CLUSTER_NAME}-monitor -n monitoring &>/dev/null; then
  log_warn "PodMonitor already exists"
  read -p "Do you want to recreate it? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Deleting existing PodMonitor..."
    kubectl delete podmonitor cnpg-${CLUSTER_NAME}-monitor -n monitoring
  else
    log "Skipping PodMonitor creation"
    SKIP_PODMONITOR=true
  fi
fi

if [ "$SKIP_PODMONITOR" != "true" ]; then
  log "Creating PodMonitor for cluster: $CLUSTER_NAME"
  
  cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-${CLUSTER_NAME}-monitor
  namespace: monitoring
  labels:
    app: cloudnative-pg
    cluster: ${CLUSTER_NAME}
spec:
  selector:
    matchLabels:
      cnpg.io/cluster: $CLUSTER_NAME
  podMetricsEndpoints:
  - port: metrics
  namespaceSelector:
    matchNames:
    - $NAMESPACE
EOF
  
  if [ $? -eq 0 ]; then
    log_success "PodMonitor created successfully"
  else
    log_error "Failed to create PodMonitor"
    exit 1
  fi
fi

# Step 5: Wait for Prometheus to discover targets
log_section "Step 5: Wait for Prometheus Discovery"

log "Waiting 30 seconds for Prometheus to discover new targets..."
for i in {30..1}; do
  echo -ne "\r  Remaining: ${i}s "
  sleep 1
done
echo ""

# Step 6: Verify metrics are being scraped
log_section "Step 6: Verify Metrics Collection"

log "Port-forwarding to Prometheus..."
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &>/dev/null &
PF_PID=$!
sleep 3

log "Querying Prometheus for CNPG metrics..."

# Check if metrics endpoint is reachable
if ! curl -s http://localhost:9090/api/v1/status/config &>/dev/null; then
  log_error "Cannot connect to Prometheus"
  kill $PF_PID 2>/dev/null
  exit 1
fi

# Check for cnpg_collector_up metric
METRICS_RESPONSE=$(curl -s "http://localhost:9090/api/v1/query?query=cnpg_collector_up{cluster=\"$CLUSTER_NAME\"}")

if echo "$METRICS_RESPONSE" | grep -q '"status":"success"'; then
  log_success "Successfully queried Prometheus"
  
  # Count pods being monitored
  METRIC_COUNT=$(echo "$METRICS_RESPONSE" | grep -o '"pod":"[^"]*"' | wc -l)
  
  if [ "$METRIC_COUNT" -gt 0 ]; then
    log_success "✅ Monitoring $METRIC_COUNT pod(s) in cluster '$CLUSTER_NAME'"
    
    echo ""
    echo "Pod Status:"
    echo "$METRICS_RESPONSE" | grep -o '"pod":"[^"]*"' | sed 's/"pod":"//g' | sed 's/"//g' | while read pod; do
      echo "  • $pod"
    done
  else
    log_warn "Metrics query succeeded but no pods found"
    log "This may be normal if pods just started. Wait 1-2 minutes and check again."
  fi
else
  log_error "Failed to query CNPG metrics"
  log "Prometheus may not have discovered the targets yet"
fi

# Check Prometheus targets
log ""
log "Checking Prometheus targets..."
TARGETS_RESPONSE=$(curl -s "http://localhost:9090/api/v1/targets")

if echo "$TARGETS_RESPONSE" | grep -q "cnpg.io/cluster.*$CLUSTER_NAME"; then
  log_success "CNPG targets found in Prometheus"
else
  log_warn "CNPG targets not yet visible in Prometheus"
fi

kill $PF_PID 2>/dev/null

# Step 7: Check Grafana
log_section "Step 7: Check Grafana Availability"

log "Looking for Grafana service..."
GRAFANA_SVC=$(kubectl get svc -n monitoring -o name 2>/dev/null | grep grafana | head -1 | sed 's|service/||')

if [ -n "$GRAFANA_SVC" ]; then
  log_success "Grafana service found: $GRAFANA_SVC"
  
  # Get Grafana password
  GRAFANA_PASSWORD=$(kubectl get secret -n monitoring $GRAFANA_SVC -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode)
  
  if [ -n "$GRAFANA_PASSWORD" ]; then
    log_success "Grafana credentials retrieved"
  fi
else
  log_warn "Grafana service not found"
  GRAFANA_SVC="prometheus-grafana"
fi

# Final summary
log_section "Setup Complete! 🎉"

echo "Monitoring is now configured for cluster: $CLUSTER_NAME"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Access Prometheus:"
echo "  kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "  Then open: http://localhost:9090"
echo ""
echo "  Try these queries:"
echo "    cnpg_collector_up{cluster=\"$CLUSTER_NAME\"}"
echo "    cnpg_pg_replication_lag{cluster=\"$CLUSTER_NAME\"}"
echo "    rate(cnpg_collector_pg_stat_database_xact_commit{cluster=\"$CLUSTER_NAME\"}[1m])"
echo ""

if [ -n "$GRAFANA_SVC" ]; then
  echo "🎨 Access Grafana:"
  echo "  kubectl port-forward -n monitoring svc/$GRAFANA_SVC 3000:80"
  echo "  Then open: http://localhost:3000"
  
  if [ -n "$GRAFANA_PASSWORD" ]; then
    echo ""
    echo "  Login credentials:"
    echo "    Username: admin"
    echo "    Password: $GRAFANA_PASSWORD"
  else
    echo ""
    echo "  Get password with:"
    echo "    kubectl get secret -n monitoring $GRAFANA_SVC -o jsonpath='{.data.admin-password}' | base64 --decode"
  fi
  
  echo ""
  echo "  Import CNPG dashboard from:"
  echo "    https://github.com/cloudnative-pg/grafana-dashboards"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ You only need to run this setup once per cluster!"
echo "✅ Metrics will be collected automatically from now on"
echo ""
echo "Next steps:"
echo "  1. Run chaos tests: ./scripts/run-e2e-chaos-test.sh"
echo "  2. View metrics in Grafana or Prometheus"
echo ""
