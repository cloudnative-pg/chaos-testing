#!/bin/bash

echo "==========================================="
echo "      CHAOS EXPERIMENT RESULTS SUMMARY"
echo "==========================================="
echo

echo "🔥 CHAOS ENGINES:"
kubectl get chaosengines -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp,STATUS:.status.engineStatus
echo

echo "📊 CHAOS RESULTS:"
kubectl get chaosresults -o custom-columns=NAME:.metadata.name,VERDICT:.status.experimentStatus.verdict,PHASE:.status.experimentStatus.phase,SUCCESS_RATE:.status.experimentStatus.probeSuccessPercentage,FAILED_RUNS:.status.history.failedRuns,PASSED_RUNS:.status.history.passedRuns
echo

echo "🎯 TARGET STATUS (PostgreSQL Cluster):"
kubectl cnpg status pg-eu
echo

echo "📈 DETAILED CHAOS RESULTS:"
for result in $(kubectl get chaosresults -o name); do
    echo "--- $result ---"
    kubectl get $result -o jsonpath='{.status.experimentStatus.verdict}' && echo
    kubectl get $result -o jsonpath='{.status.experimentStatus.phase}' && echo
    echo "Success Rate: $(kubectl get $result -o jsonpath='{.status.experimentStatus.probeSuccessPercentage}')%"
    echo "Failed Runs: $(kubectl get $result -o jsonpath='{.status.history.failedRuns}')"
    echo "Passed Runs: $(kubectl get $result -o jsonpath='{.status.history.passedRuns}')"
    echo
done

echo "🔍 RECENT EXPERIMENT EVENTS:"
kubectl get events --field-selector reason=Pass,reason=Fail --sort-by='.lastTimestamp' | tail -10