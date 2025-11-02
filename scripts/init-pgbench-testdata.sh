#!/bin/bash
# Initialize pgbench test data in CNPG cluster
# Implements CNPG e2e pattern: AssertCreateTestData

set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values
CLUSTER_NAME=${1:-pg-eu}
DATABASE=${2:-app}
SCALE_FACTOR=${3:-50}  # 50 = ~7.5MB of test data (5M rows in pgbench_accounts)
NAMESPACE=${4:-default}

echo "========================================"
echo "  CNPG pgbench Test Data Initialization"
echo "========================================"
echo ""
echo "Configuration:"
echo "  Cluster:       $CLUSTER_NAME"
echo "  Namespace:     $NAMESPACE"
echo "  Database:      $DATABASE"
echo "  Scale Factor:  $SCALE_FACTOR"
echo ""

# Calculate expected data size
ACCOUNTS_COUNT=$((SCALE_FACTOR * 100000))
BRANCHES_COUNT=$SCALE_FACTOR
TELLERS_COUNT=$((SCALE_FACTOR * 10))

echo "Expected test data:"
echo "  - pgbench_accounts: $ACCOUNTS_COUNT rows (~$((SCALE_FACTOR * 150)) MB)"
echo "  - pgbench_branches: $BRANCHES_COUNT rows"
echo "  - pgbench_tellers:  $TELLERS_COUNT rows"
echo "  - pgbench_history:  0 rows (populated during benchmark)"
echo ""

# Verify cluster exists
echo "Checking cluster status..."
if ! kubectl get cluster $CLUSTER_NAME -n $NAMESPACE &>/dev/null; then
  echo -e "${RED}❌ Error: Cluster '$CLUSTER_NAME' not found in namespace '$NAMESPACE'${NC}"
  exit 1
fi

# Get cluster status
CLUSTER_STATUS=$(kubectl get cluster $CLUSTER_NAME -n $NAMESPACE -o jsonpath='{.status.phase}')
if [ "$CLUSTER_STATUS" != "Cluster in healthy state" ]; then
  echo -e "${YELLOW}⚠️  Warning: Cluster status is '$CLUSTER_STATUS'${NC}"
  echo "Continuing anyway..."
fi

# Get the read-write service (connects to primary)
SERVICE="${CLUSTER_NAME}-rw"
echo "Using service: $SERVICE (primary endpoint)"

# Get the password from the cluster secret
echo "Retrieving database credentials..."
if ! kubectl get secret ${CLUSTER_NAME}-credentials -n $NAMESPACE &>/dev/null; then
  echo -e "${RED}❌ Error: Secret '${CLUSTER_NAME}-credentials' not found${NC}"
  echo "Available secrets:"
  kubectl get secrets -n $NAMESPACE | grep $CLUSTER_NAME
  exit 1
fi

PASSWORD=$(kubectl get secret ${CLUSTER_NAME}-credentials -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

# Check if test data already exists
echo ""
echo "Checking for existing test data..."
EXISTING_DATA=$(kubectl run pgbench-check-$$  --rm -i --restart=Never \
  --image=postgres:16 \
  --namespace=$NAMESPACE \
  --env="PGPASSWORD=$PASSWORD" \
  --command -- \
  psql -h $SERVICE -U app -d $DATABASE -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE 'pgbench_%';" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

if [ -n "$EXISTING_DATA" ] && [ "$EXISTING_DATA" -gt 0 ] 2>/dev/null; then
  echo -e "${YELLOW}⚠️  Warning: Found $EXISTING_DATA pgbench tables already exist${NC}"
  echo ""
  read -p "Do you want to DROP existing tables and reinitialize? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Dropping existing pgbench tables..."
    kubectl run pgbench-cleanup-$$ --rm -i --restart=Never \
      --image=postgres:16 \
      --namespace=$NAMESPACE \
      --env="PGPASSWORD=$PASSWORD" \
      --command -- \
      psql -h $SERVICE -U app -d $DATABASE -c \
      "DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_tellers, pgbench_history CASCADE;"
    echo "Tables dropped."
  else
    echo "Keeping existing tables. Exiting."
    exit 0
  fi
fi

# Initialize pgbench test data
echo ""
echo "Initializing pgbench test data (this may take a few minutes)..."
echo "Started at: $(date)"

# Create a temporary pod with PostgreSQL client
kubectl run pgbench-init-$$ --rm -i --restart=Never \
  --image=postgres:16 \
  --namespace=$NAMESPACE \
  --env="PGPASSWORD=$PASSWORD" \
  --command -- \
  pgbench -i -s $SCALE_FACTOR -U app -h $SERVICE -d $DATABASE --no-vacuum

if [ $? -eq 0 ]; then
  echo "Completed at: $(date)"
  echo ""
  echo -e "${GREEN}✅ Test data initialized successfully!${NC}"
else
  echo -e "${RED}❌ Failed to initialize test data${NC}"
  exit 1
fi

# Verify tables were created
echo ""
echo "Verifying tables..."
VERIFICATION=$(kubectl run pgbench-verify-$$ --rm -i --restart=Never \
  --image=postgres:16 \
  --namespace=$NAMESPACE \
  --env="PGPASSWORD=$PASSWORD" \
  --command -- \
  psql -h $SERVICE -U app -d $DATABASE -c "\dt pgbench_*")

echo "$VERIFICATION"

# Get actual row counts
echo ""
echo "Verifying row counts..."
ACTUAL_ACCOUNTS=$(kubectl run pgbench-count-$$ --rm -i --restart=Never \
  --image=postgres:16 \
  --namespace=$NAMESPACE \
  --env="PGPASSWORD=$PASSWORD" \
  --command -- \
  psql -h $SERVICE -U app -d $DATABASE -tAc "SELECT count(*) FROM pgbench_accounts;" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

echo "  pgbench_accounts: $ACTUAL_ACCOUNTS rows (expected: $ACCOUNTS_COUNT)"

if [ -n "$ACTUAL_ACCOUNTS" ] && [ "$ACTUAL_ACCOUNTS" -eq "$ACCOUNTS_COUNT" ] 2>/dev/null; then
  echo -e "${GREEN}✅ Row count matches expected value${NC}"
else
  echo -e "${YELLOW}⚠️  Row count differs from expected (this is OK if initialization succeeded)${NC}"
fi

# Run ANALYZE for better query performance
echo ""
echo "Running ANALYZE to update statistics..."
kubectl run pgbench-analyze-$$ --rm -i --restart=Never \
  --image=postgres:16 \
  --namespace=$NAMESPACE \
  --env="PGPASSWORD=$PASSWORD" \
  --command -- \
  psql -h $SERVICE -U app -d $DATABASE -c "ANALYZE;" &>/dev/null

# Display summary
echo ""
echo "========================================"
echo "  ✅ Initialization Complete"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Run workload: kubectl apply -f workloads/pgbench-continuous-job.yaml"
echo "  2. Execute chaos: kubectl apply -f experiments/cnpg-primary-with-workload.yaml"
echo "  3. Verify data: ./scripts/verify-data-consistency.sh"
echo ""
echo "To test pgbench manually:"
echo "  kubectl exec -it ${CLUSTER_NAME}-1 -n $NAMESPACE -- \\"
echo "    pgbench -c 10 -j 2 -T 60 -P 10 -U app -h $SERVICE -d $DATABASE"
echo ""
