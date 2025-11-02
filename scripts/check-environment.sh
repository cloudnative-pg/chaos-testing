#!/bin/bash

# Quick verification script to check if environment is ready for chaos experiments

echo "============================================"
echo "   Chaos Experiment Environment Check"
echo "============================================"
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_passed=0
check_total=0

check_status() {
    local test_name="$1"
    local command="$2"
    local expected="$3"
    
    ((check_total++))
    echo -n "[$check_total] $test_name: "
    
    if eval "$command" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        ((check_passed++))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        if [ -n "$expected" ]; then
            echo "    Expected: $expected"
        fi
        return 1
    fi
}

check_optional() {
    local test_name="$1"
    local command="$2"
    local info="$3"
    
    ((check_total++))
    echo -n "[$check_total] $test_name: "
    
    if eval "$command" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        ((check_passed++))
        return 0
    else
        echo -e "${YELLOW}SKIP${NC}"
        if [ -n "$info" ]; then
            echo "    Info: $info"
        fi
        ((check_passed++))  # Count as passed since it's optional
        return 0
    fi
}

# Basic tools
echo "=== Prerequisites ==="
check_status "kubectl installed" "command -v kubectl"
check_status "kind installed" "command -v kind"
check_optional "kubectl cnpg plugin" "kubectl cnpg version" "Optional plugin - not required for chaos testing"

# Cluster connectivity
echo
echo "=== Cluster Connectivity ==="
check_status "k8s-eu cluster accessible" "kubectl --context kind-k8s-eu get nodes"
check_status "Current context is k8s-eu" "[[ \$(kubectl config current-context) == 'kind-k8s-eu' ]]"

# CNPG components
echo
echo "=== CloudNativePG Components ==="
check_status "CNPG operator deployed" "kubectl get deployment -n cnpg-system cnpg-controller-manager"
check_status "CNPG operator ready" "kubectl get deployment -n cnpg-system cnpg-controller-manager -o jsonpath='{.status.readyReplicas}' | grep -q '1'"
check_status "PostgreSQL cluster exists" "kubectl get cluster pg-eu"
check_status "PostgreSQL cluster ready" "kubectl get cluster pg-eu -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q 'True'"

# PostgreSQL pods
echo
echo "=== PostgreSQL Pods ==="
check_status "Primary pod running" "kubectl get pod pg-eu-1 -o jsonpath='{.status.phase}' | grep -q 'Running'"
check_status "At least one replica running" "kubectl get pods -l cnpg.io/cluster=pg-eu --no-headers | grep -v initdb | wc -l | awk '{print (\$1 >= 2)}' | grep -q 1"

# Litmus components
echo
echo "=== LitmusChaos Components ==="
check_status "Litmus operator deployed" "kubectl get deployment -n litmus chaos-operator-ce"
check_status "Litmus operator ready" "kubectl get deployment -n litmus chaos-operator-ce -o jsonpath='{.status.readyReplicas}' | grep -q '1'"
check_status "Pod-delete experiment available" "kubectl get chaosexperiments pod-delete"
check_status "Litmus service account exists" "kubectl get serviceaccount litmus-admin"
check_status "Litmus RBAC configured" "kubectl get clusterrolebinding litmus-admin"

# Required files
echo
echo "=== Required Files ==="
check_status "PostgreSQL cluster config exists" "test -f pg-eu-cluster.yaml"
check_status "Litmus RBAC config exists" "test -f litmus-rbac.yaml"
check_status "Replica experiment exists" "test -f experiments/cnpg-replica-pod-delete.yaml"
check_status "Primary experiment exists" "test -f experiments/cnpg-primary-pod-delete.yaml"
check_status "Results script exists" "test -f scripts/get-chaos-results.sh"
check_status "Automation script exists" "test -f scripts/run-chaos-experiment.sh"

# Summary
echo
echo "============================================"
echo "             SUMMARY"
echo "============================================"
echo "Checks passed: $check_passed/$check_total"

if [ $check_passed -eq $check_total ]; then
    echo -e "${GREEN}✅ Environment is ready for chaos experiments!${NC}"
    echo
    echo "🚀 Ready to run chaos experiments:"
    echo "   ./scripts/run-chaos-experiment.sh"
    echo
    echo "📖 Or follow the manual steps in:"
    echo "   README-CHAOS-EXPERIMENTS.md"
    exit 0
else
    echo -e "${RED}❌ Environment setup incomplete${NC}"
    echo
    echo "Please fix the failed checks before running chaos experiments."
    echo "Refer to README-CHAOS-EXPERIMENTS.md for setup instructions."
    exit 1
fi