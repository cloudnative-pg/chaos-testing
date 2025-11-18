# CloudNativePG Chaos Testing with Jepsen

![CloudNativePG Logo](logo/cloudnativepg.png)

**Status**: ✅ Production Ready  
**Focus**: Jepsen-based consistency verification with chaos engineering  
**Maintainer**: cloudnative-pg community

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Why Jepsen?](#-why-jepsen)
- [Architecture](#-architecture)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start-5-minutes)
- [Component Deep Dive](#-component-deep-dive)
- [Test Scenarios](#-test-scenarios)
- [Results Interpretation](#-results-interpretation)
- [Configuration & Customization](#-configuration--customization)
- [Troubleshooting](#-troubleshooting)
- [Advanced Usage](#-advanced-usage)
- [Project Archive](#-project-archive)
- [Contributing](#-contributing)

---

## 🎯 Overview

This project provides **production-ready chaos testing** for CloudNativePG clusters using:

- **[Jepsen](https://jepsen.io/)**: Industry-standard distributed systems consistency verification (Elle checker)
- **[Litmus Chaos](https://litmuschaos.io/)**: CNCF incubating chaos engineering framework
- **[CloudNativePG](https://cloudnative-pg.io/)**: Kubernetes operator for PostgreSQL high availability

### What This Does

1. **Deploys Jepsen workload** - Continuous read/write operations against PostgreSQL cluster
2. **Injects chaos** - Deletes primary pod repeatedly to simulate failures
3. **Verifies consistency** - Uses Elle checker to mathematically prove data integrity
4. **Reports results** - Generates detailed analysis with anomaly detection

---

## 🔬 Why Jepsen?

Unlike simple workload generators like pgbench, Jepsen performs **true consistency verification**:

| Feature                  | pgbench          | Jepsen                       |
| ------------------------ | ---------------- | ---------------------------- |
| Workload generation      | ✅ Yes           | ✅ Yes                       |
| Performance benchmarking | ✅ Yes           | ⚠️ Limited                   |
| Consistency verification | ❌ No            | ✅ **Mathematical proof**    |
| Anomaly detection        | ❌ No            | ✅ G0, G1c, G2, etc.         |
| Isolation level testing  | ❌ No            | ✅ All levels                |
| History analysis         | ❌ No            | ✅ Complete dependency graph |
| Lost write detection     | ⚠️ Manual checks | ✅ Automatic                 |

**Bottom Line**: Jepsen provides rigorous consistency guarantees that pgbench cannot offer.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                              │
│  ┌────────────────────┐      ┌─────────────────────────┐   │
│  │  CloudNativePG     │      │   Jepsen Workload       │   │
│  │  PostgreSQL        │◄─────│   (Job)                 │   │
│  │                    │ R/W  │                         │   │
│  │  • Primary (1)     │      │   • 50 ops/sec          │   │
│  │  • Replicas (2)    │      │   • 10 workers          │   │
│  │  • Auto-failover   │      │   • Append workload     │   │
│  └────────▲───────────┘      │   • Elle checker        │   │
│           │                  └─────────────────────────┘   │
│           │                                                 │
│           │ Delete Primary                                  │
│           │ Every 180s                                      │
│           │                                                 │
│  ┌────────┴───────────┐      ┌─────────────────────────┐   │
│  │  Litmus Chaos      │      │   Monitoring Probes     │   │
│  │  ChaosEngine       │──────│   • Health checks       │   │
│  │                    │      │   • Replication lag     │   │
│  │  • Pod deletion    │      │   • Primary availability│   │
│  │  • 5 probes        │      │   • Prometheus queries  │   │
│  └────────────────────┘      └─────────────────────────┘   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
         │
         │ Extracts results
         ▼
   ┌─────────────────┐
   │  STATISTICS.txt │ ──► :ok/:fail/:info counts
   │  results.edn    │ ──► :valid? true/false
   │  timeline.html  │ ──► Interactive visualization
   │  history.edn    │ ──► Complete operation log
   └─────────────────┘
```

---

## ✅ Prerequisites

### Required

1. **Kubernetes cluster with CloudNativePG** (v1.23+)

   **Recommended**: Use [CNPG Playground](https://github.com/cloudnative-pg/cnpg-playground?tab=readme-ov-file#single-kubernetes-cluster-setup) for quick setup

   ```bash
   # Clone CNPG Playground
   git clone https://github.com/cloudnative-pg/cnpg-playground.git
   cd cnpg-playground

   # Create single cluster with CloudNativePG operator pre-installed
   make kind-with-local-registry
   ```

   **Alternative**: Manual setup

   - Local: kind, minikube, k3s
   - Cloud: EKS, GKE, AKS
   - Install CloudNativePG operator:
     ```bash
     kubectl apply -f \
       https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.20/releases/cnpg-1.20.0.yaml
     ```

2. **Litmus Chaos operator** (v1.13.8+)

   ```bash
   kubectl apply -f \
     https://litmuschaos.github.io/litmus/litmus-operator-v1.13.8.yaml
   ```

3. **Prometheus & Grafana (for chaos probes and monitoring dashboards)**

   - Add Helm repo:
     ```bash
     helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
     helm repo update
     ```
   - Install kube-prometheus-stack (includes Prometheus & Grafana):
     ```bash
     helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
     ```
   - Wait for pods to be ready:
     ```bash
     kubectl get pods -n monitoring
     ```
   - Access Prometheus:
     ```bash
     kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
     # Open http://localhost:9090
     ```
   - Access Grafana:
     ```bash
     kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
     # Open http://localhost:3000 (default login: admin/prom-operator)
     ```
   - Import CNPG dashboard:
     [Grafana CNPG Dashboard](https://grafana.com/grafana/dashboards/20417-cloudnativepg/)

### Verify Setup

```bash
# Check Kubernetes
kubectl cluster-info
kubectl get nodes

# Check CloudNativePG
kubectl get deployment -n cnpg-system cnpg-controller-manager

# Check Litmus
kubectl get pods -n litmus

# Check Prometheus
kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus

# Check Grafana
kubectl get svc -n monitoring prometheus-grafana
```

---

## 🚀 Quick Start (5 Minutes)

### Step 1: Deploy PostgreSQL Cluster

```bash
# Deploy sample 3-instance cluster (PostgreSQL 16)
kubectl apply -f pg-eu-cluster.yaml

# Wait for cluster ready (may take 2-3 minutes)
kubectl wait --for=condition=ready cluster/pg-eu --timeout=300s

# Verify cluster status
kubectl cnpg status pg-eu
```

Expected output:

```
Cluster Summary
Name:               pg-eu
Namespace:          default
PostgreSQL Image:   ghcr.io/cloudnative-pg/postgresql:16
Primary instance:   pg-eu-1
Instances:          3
Ready instances:    3
```

### Step 2: Configure Chaos RBAC

```bash
# Create ServiceAccount with permissions for chaos experiments
kubectl apply -f litmus-rbac.yaml
```

### Step 3: Run Combined Test (Jepsen + Chaos)

```bash
# Run 5-minute test with chaos injection
./scripts/run-jepsen-chaos-test.sh

# Script performs:
# 1. Pre-flight checks
# 2. Database cleanup (optional)
# 3. Deploys Jepsen workload
# 4. Waits for Jepsen initialization (30s)
# 5. Applies chaos (deletes primary every 180s)
# 6. Monitors execution in real-time
# 7. Extracts results
# 8. Generates STATISTICS.txt
# 9. Prints summary
```

### Step 4: View Results

```bash
# Results saved to logs/jepsen-chaos-<timestamp>/

# Quick consistency check (should be ":valid? true")
grep ":valid?" logs/jepsen-chaos-*/results/results.edn

# View statistics summary
cat logs/jepsen-chaos-*/STATISTICS.txt

# Check chaos experiment verdict
./scripts/get-chaos-results.sh

# Open interactive timeline in browser
firefox logs/jepsen-chaos-*/results/timeline.html
```

**Expected Result**: `:valid? true` = CloudNativePG maintains consistency during chaos! ✅

---

## 🔍 Component Deep Dive

### A. CloudNativePG Cluster

**File**: `pg-eu-cluster.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-eu
spec:
  instances: 3 # 1 primary + 2 replicas
  primaryUpdateStrategy: unsupervised # Auto-failover enabled

  postgresql:
    parameters:
      max_connections: "100"
      shared_buffers: "256MB"

  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: pg-eu-credentials # Username + password

  storage:
    size: 1Gi
```

**Connection endpoints**:

- **Read-Write**: `pg-eu-rw.default.svc.cluster.local:5432` (primary only)
- **Read-Only**: `pg-eu-ro.default.svc.cluster.local:5432` (all replicas)
- **Read**: `pg-eu-r.default.svc.cluster.local:5432` (all instances)

### B. Jepsen Docker Image

**Image**: `ardentperf/jepsenpg:latest`

**Key parameters** (from `workloads/jepsen-cnpg-job.yaml`):

```yaml
env:
  - name: WORKLOAD
    value: "append" # List-append workload (detects G2, lost writes)

  - name: ISOLATION
    value: "read-committed" # PostgreSQL isolation level to test

  - name: DURATION
    value: "120" # Test duration in seconds

  - name: RATE
    value: "50" # 50 operations per second

## 📚 Additional Resources

### External Documentation

- **Jepsen Framework**: https://jepsen.io/
- **ardentperf/jepsenpg**: https://github.com/ardentperf/jepsenpg
- **CloudNativePG Docs**: https://cloudnative-pg.io/documentation/current/
- **Litmus Chaos Docs**: https://litmuschaos.io/docs/
- **Elle Checker Paper**: https://github.com/jepsen-io/elle

### Included Guides

- **[ISOLATION_LEVELS_GUIDE.md](docs/ISOLATION_LEVELS_GUIDE.md)** - PostgreSQL isolation levels explained
- **[IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md)** - Architecture and design decisions
- **[WORKFLOW_DIAGRAM.md](WORKFLOW_DIAGRAM.md)** - Visual workflow representation

### Community

- **CloudNativePG Slack**: [Join here](https://cloudnative-pg.io/community/)
- **Issue Tracker**: https://github.com/cloudnative-pg/cloudnative-pg/issues
- **Discussions**: https://github.com/cloudnative-pg/cloudnative-pg/discussions


## 🤝 Contributing

We welcome contributions! Please see:

- **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** - Community guidelines
- **[GOVERNANCE.md](GOVERNANCE.md)** - Project governance model
- **[CODEOWNERS](CODEOWNERS)** - Maintainer responsibilities

### How to Contribute

1. **Fork the repository**
2. **Create feature branch**: `git checkout -b feature/my-improvement`
3. **Make changes** and test thoroughly
4. **Commit**: `git commit -m "feat: add new chaos scenario"`
5. **Push**: `git push origin feature/my-improvement`
6. **Open Pull Request** with detailed description


## 📜 License

Apache 2.0 - See [LICENSE](LICENSE)


## 🙏 Acknowledgments

- **CloudNativePG Team** - Kubernetes PostgreSQL operator excellence
- **Litmus Community** - CNCF chaos engineering framework
- **Aphyr (Kyle Kingsbury)** - Creating Jepsen and advancing distributed systems testing
- **ardentperf** - Pre-built jepsenpg Docker image
- **Elle Team** - Mathematical consistency verification


## 📈 Project Status

- **Current Version**: v2.0 (Jepsen-focused)
- **Status**: Production Ready ✅
- **Last Updated**: November 18, 2025
- **Tested With**:
  - CloudNativePG v1.20+
  - PostgreSQL 16
  - Litmus v1.13.8
  - Kubernetes v1.23-1.28


**Happy Chaos Testing! 🎯**

Step 11: Cleanup recommendations
  ├─ Option to delete test resources
  └─ Or keep for manual inspection
```

### E. Utility Scripts

**`scripts/monitor-cnpg-pods.sh`**:

```bash
# Real-time monitoring during tests
./scripts/monitor-cnpg-pods.sh [cluster-name] [namespace]

# Displays:
# - Pod names, roles, status, readiness, restarts
# - Active chaos engines
# - Recent events related to cluster
```

**`scripts/get-chaos-results.sh`**:

```bash
# Quick chaos experiment summary
./scripts/get-chaos-results.sh

# Shows:
# - ChaosEngine status
# - ChaosResult verdicts
# - Probe success rates
# - Pass/fail run counts
```

---

## 🧪 Test Scenarios

### 1. Baseline Test (No Chaos)

**Purpose**: Establish consistency baseline without failures

```bash
# Deploy Jepsen only (no chaos injection)
kubectl apply -f workloads/jepsen-cnpg-job.yaml

# Wait for completion (2-5 minutes)
kubectl wait --for=condition=complete job/jepsen-cnpg-test --timeout=600s

# Check logs
kubectl logs job/jepsen-cnpg-test -f

# Extract results (manual method)
JEPSEN_POD=$(kubectl get pods -l app=jepsen-test -o jsonpath='{.items[0].metadata.name}')
kubectl cp default/${JEPSEN_POD}:/jepsenpg/store/latest/ ./baseline-results/
```

**Expected**: `:valid? true` (no chaos = perfect consistency)

### 2. Primary Failover Test (Default)

**Purpose**: Verify consistency during primary pod deletion

```bash
# Run combined test with default settings
./scripts/run-jepsen-chaos-test.sh

# Or specify custom duration (15 minutes)
./scripts/run-jepsen-chaos-test.sh pg-eu app 900
```

**Expected**: `:valid? true` (CNPG handles graceful failover)

**What happens**:

1. Jepsen starts continuous read/write operations
2. Every 180s, Litmus deletes the primary pod
3. CloudNativePG promotes a replica to primary
4. Jepsen continues operations (some may fail during failover)
5. Elle checker verifies no consistency violations

### 3. Replica Failover Test

**Purpose**: Confirm replica deletion doesn't affect consistency

```bash
# Edit experiments/cnpg-jepsen-chaos.yaml
# Change TARGETS to:
TARGETS: "deployment:default:[cnpg.io/cluster=pg-eu,cnpg.io/instanceRole=replica]:intersection"

# Or use pre-built experiment
kubectl apply -f experiments/cnpg-replica-pod-delete.yaml
```

**Expected**: `:valid? true` (replica deletion should not affect writes to primary)

### 4. Frequent Chaos Test

**Purpose**: Test resilience under aggressive pod deletion

```bash
# Edit experiments/cnpg-jepsen-chaos.yaml
# Change CHAOS_INTERVAL to "30" (delete every 30s instead of 180s)

./scripts/run-jepsen-chaos-test.sh pg-eu app 300
```

**Expected**: `:valid? true` (but higher failure rate in operations)

### 5. Long-Duration Soak Test

**Purpose**: Validate consistency over extended periods

```bash
# 30-minute test
./scripts/run-jepsen-chaos-test.sh pg-eu app 1800

# Results:
# - ~90,000 operations (50 ops/sec × 1800s)
# - Multiple primary failovers
# - Comprehensive consistency proof
```

---

## 📊 Results Interpretation

### A. Result Files

After test completion, results are in `logs/jepsen-chaos-<timestamp>/results/`:

| File                    | Size       | Description                                   |
| ----------------------- | ---------- | --------------------------------------------- |
| `history.edn`           | 3-6 MB     | Complete operation history (all reads/writes) |
| `results.edn`           | 10-50 KB   | Consistency verdict and anomaly analysis      |
| `timeline.html`         | 100-500 KB | Interactive visualization of operations       |
| `latency-raw.png`       | 30-50 KB   | Raw latency measurements                      |
| `latency-quantiles.png` | 25-35 KB   | Latency percentiles (p50, p95, p99)           |
| `rate.png`              | 20-30 KB   | Operations per second over time               |
| `jepsen.log`            | 3-6 MB     | Complete test execution logs                  |
| `STATISTICS.txt`        | 1-2 KB     | High-level operation counts                   |

### B. Jepsen Consistency Verdict

**Check verdict**:

```bash
grep ":valid?" logs/jepsen-chaos-*/results/results.edn
```

**Interpretation**:

✅ **`:valid? true`** - **PASS**

```clojure
{:valid? true
 :anomaly-types []
 :not #{}}
```

- No consistency violations detected
- All acknowledged writes are readable
- No dependency cycles found
- System is linearizable/serializable (depending on isolation level)

⚠️ **`:valid? false`** - **FAIL**

```clojure
{:valid? false
 :anomaly-types [:G-single-item :G2]
 :not #{:read-committed}}
```

- Consistency violations detected
- Check `:anomaly-types` for specific issues
- System does not satisfy expected consistency model

### C. STATISTICS.txt Format

```
==============================================
     JEPSEN TEST EXECUTION STATISTICS
==============================================

Total :ok     : 14,523    (Successful operations)
Total :fail   : 445       (Failed operations - expected during chaos)
Total :info   : 0         (Indeterminate operations)
----------------------------------------------
Total ops     : 14,968

:ok rate      : 97.03%
:fail rate    : 2.97%
:info rate    : 0.00%
==============================================
```

**Typical values**:

- **:ok rate**: 95-98% (some failures expected during pod deletion)
- **:fail rate**: 2-5% (operations during failover window)
- **:info rate**: 0-1% (rare, indeterminate state)

**Concerning values**:

- **:ok rate < 90%**: May indicate performance issues or slow failover
- **:fail rate > 10%**: Excessive failures, investigate cluster health
- **:info rate > 5%**: Network/timeout issues

### D. Chaos Experiment Verdict

```bash
./scripts/get-chaos-results.sh
```

**Output**:

```
🔥 CHAOS ENGINES:
NAME                 AGE                    STATUS
cnpg-jepsen-chaos    2024-11-18T12:30:00Z   completed

📊 CHAOS RESULTS:
NAME                         VERDICT    PHASE       SUCCESS_RATE    FAILED_RUNS    PASSED_RUNS
cnpg-jepsen-chaos-pod-delete Pass       Completed   100%            0              1

🎯 TARGET STATUS (PostgreSQL Cluster):
Cluster Summary
Name:               pg-eu
Namespace:          default
Ready instances:    3/3
```

**Probe verdicts**:

- **Passed (100%)** ✅: All probes succeeded (cluster healthy throughout)
- **Failed** ❌: One or more probe failures (investigate logs)
- **N/A** ⚠️: Probe skipped (e.g., Prometheus not available)

### E. Common Anomaly Types

| Anomaly             | Description                    | Severity | Cause                             |
| ------------------- | ------------------------------ | -------- | --------------------------------- |
| `:G0`               | Write cycle (dirty write)      | Critical | Lost committed data               |
| `:G1c`              | Circular information flow      | Critical | Dirty reads allowed               |
| `:G2`               | Anti-dependency cycle          | High     | Non-serializable execution        |
| `:lost-update`      | Acknowledged write disappeared | Critical | Data loss after failover          |
| `:duplicate-append` | Value appeared twice           | Medium   | Duplicate operation processing    |
| `:internal`         | Jepsen internal error          | Low      | Analysis bug (not database issue) |

**If anomalies are detected**:

1. Check cluster logs: `kubectl logs -l cnpg.io/cluster=pg-eu`
2. Review failover events: `kubectl get events --sort-by='.lastTimestamp'`
3. Inspect replication lag: `kubectl cnpg status pg-eu`
4. Analyze timeline.html for operation patterns during failures

### F. Interactive Timeline

**Open timeline**:

```bash
firefox logs/jepsen-chaos-*/results/timeline.html
```

**Timeline visualization**:

- **Green bars**: Successful operations (`:ok`)
- **Red bars**: Failed operations (`:fail`) - expected during failover
- **Yellow bars**: Indeterminate operations (`:info`)
- **Gray background**: Chaos injection period (pod deletion)
- **X-axis**: Time (seconds from test start)
- **Y-axis**: Worker threads (0-9)

**Look for**:

- Red bars clustered during chaos (normal)
- Long gaps in operations (may indicate issues)
- Red bars outside chaos windows (investigate)

---

## ⚙️ Configuration & Customization

### A. Test Duration

**Default**: 5 minutes (300 seconds)

```bash
# 10-minute test
./scripts/run-jepsen-chaos-test.sh pg-eu app 600

# 30-minute soak test
./scripts/run-jepsen-chaos-test.sh pg-eu app 1800
```

### B. Chaos Interval

**Default**: Delete primary every 180 seconds

Edit `experiments/cnpg-jepsen-chaos.yaml`:

```yaml
- name: CHAOS_INTERVAL
  value: "60" # Aggressive: every 60s
  # value: "300"  # Conservative: every 5 minutes
```

### C. Jepsen Workload Parameters

Edit `workloads/jepsen-cnpg-job.yaml`:

```yaml
env:
  # Operation rate (ops/sec)
  - name: RATE
    value: "100" # Default: 50

  # Concurrent workers
  - name: CONCURRENCY
    value: "20" # Default: 10

  # Test duration
  - name: DURATION
    value: "600" # Default: 120 seconds

  # Workload type
  - name: WORKLOAD
    value: "ledger" # Options: append, ledger

  # PostgreSQL isolation level
  - name: ISOLATION
    value: "serializable" # Options: read-committed, repeatable-read, serializable
```

**Workload types**:

- **`append`**: List-append (detects G2, lost writes) - Recommended
- **`ledger`**: Bank ledger (detects G1c, dirty reads)

**Isolation levels**:

- **`read-committed`**: Default PostgreSQL, allows phantom reads
- **`repeatable-read`**: Prevents non-repeatable reads
- **`serializable`**: Strongest guarantee, fully linearizable

### D. Probe Customization

Add custom probes to `experiments/cnpg-jepsen-chaos.yaml`:

```yaml
probe:
  # Custom cmdProbe: Check connection pool
  - name: "check-connection-pool"
    type: "cmdProbe"
    mode: "Continuous"
    runProperties:
      command: "kubectl exec -it pg-eu-1 -- psql -U postgres -c 'SELECT count(*) FROM pg_stat_activity;' | grep -E '[0-9]+'"
      interval: 30
      retry: 3

  # Custom promProbe: Monitor CPU usage
  - name: "check-cpu-usage"
    type: "promProbe"
    mode: "Continuous"
    promProbe/inputs:
      endpoint: "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
      query: "rate(container_cpu_usage_seconds_total{pod=~'pg-eu-.*'}[1m])"
      comparator:
        criteria: "<"
        value: "0.8" # CPU usage < 80%
```

### E. Target Different Pods

**Delete replicas instead of primary**:

```yaml
- name: TARGETS
  value: "deployment:default:[cnpg.io/cluster=pg-eu,cnpg.io/instanceRole=replica]:intersection"
```

**Delete random pod**:

```yaml
- name: TARGETS
  value: "deployment:default:[cnpg.io/cluster=pg-eu]:random"
```

### F. Cluster Configuration

Edit `pg-eu-cluster.yaml` for different topologies:

```yaml
spec:
  instances: 5 # 1 primary + 4 replicas

  # Enable synchronous replication
  postgresql:
    parameters:
      synchronous_commit: "on"
      synchronous_standby_names: "pg-eu-2"

  # Resource limits
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"

  # Storage
  storage:
    size: 10Gi
    storageClass: "fast-ssd"
```

---

## 🐛 Troubleshooting

### Issue 1: Jepsen Pod Stuck in ContainerCreating

**Symptoms**:

```bash
kubectl get pods -l app=jepsen-test
# NAME                     READY   STATUS              RESTARTS   AGE
# jepsen-cnpg-test-xxxxx   0/1     ContainerCreating   0          5m
```

**Diagnosis**:

```bash
kubectl describe pod -l app=jepsen-test
# Events:
#   Pulling image "ardentperf/jepsenpg:latest"
```

**Solution**:

- **First run**: Image pull takes 2-3 minutes (1.2 GB image)
- **Wait**: Be patient, check events for progress
- **Pre-pull** (optional):
  ```bash
  kubectl run temp --image=ardentperf/jepsenpg:latest --rm -it -- /bin/bash
  # Ctrl+C after image is pulled
  ```

### Issue 2: ChaosEngine TARGET_SELECTION_ERROR

**Symptoms**:

```bash
kubectl get chaosengine cnpg-jepsen-chaos
# STATUS: Stopped (No targets found)
```

**Diagnosis**:

```bash
kubectl describe chaosengine cnpg-jepsen-chaos
# Events:
#   Warning  SelectionFailed  No pods match the target selector
```

**Solution**:

```bash
# Verify pod labels
kubectl get pods -l cnpg.io/cluster=pg-eu --show-labels

# Check primary pod exists
kubectl get pods -l cnpg.io/instanceRole=primary

# Fix TARGETS in cnpg-jepsen-chaos.yaml:
# Should use: deployment:default:[cnpg.io/cluster=pg-eu,cnpg.io/instanceRole=primary]:intersection
```

### Issue 3: Prometheus Probes Failing

**Symptoms**:

```bash
./scripts/get-chaos-results.sh
# Probe: check-replication-lag-sot - FAILED
# Probe: check-replication-lag-eot - FAILED
```

**Diagnosis**:

```bash
# Check Prometheus accessibility
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Open browser: http://localhost:9090
# Query: cnpg_collector_up
# Expected: Value = 1 for all instances
```

**Solutions**:

1. **Prometheus not installed**:

   ```bash
   helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
   ```

2. **CNPG metrics not enabled**:

   ```yaml
   # Add to pg-eu-cluster.yaml
   spec:
     monitoring:
       enabled: true
       podMonitorEnabled: true
   ```

3. **Disable Prometheus probes** (if not needed):
   - Edit `experiments/cnpg-jepsen-chaos.yaml`
   - Remove `promProbe` entries
   - Keep only `cmdProbe` checks

### Issue 4: Database Connection Failures

**Symptoms**:

```bash
kubectl logs -l app=jepsen-test
# ❌ Failed to connect to database
# FATAL: password authentication failed for user "app"
```

**Diagnosis**:

```bash
# Check secret exists
kubectl get secret pg-eu-credentials

# Verify credentials
kubectl get secret pg-eu-credentials -o jsonpath='{.data.username}' | base64 -d
kubectl get secret pg-eu-credentials -o jsonpath='{.data.password}' | base64 -d

# Test connection manually
kubectl run psql-test --image=postgres:16 --rm -it -- \
  psql -h pg-eu-rw -U app -d app
```

**Solutions**:

1. **Secret not created**:

   ```bash
   # CloudNativePG auto-creates, but verify:
   kubectl get cluster pg-eu -o jsonpath='{.spec.bootstrap.initdb.secret.name}'
   ```

2. **Wrong database name**:
   ```yaml
   # In jepsen-cnpg-job.yaml:
   - name: PGDATABASE
     value: "app" # Must match cluster bootstrap database
   ```

### Issue 5: Elle Analysis Takes Forever

**Symptoms**:

- Jepsen pod runs for 30+ minutes
- No `results.edn` file generated

**Diagnosis**:

```bash
kubectl logs -l app=jepsen-test | tail -50
# Look for:
# "Analyzing history..."
# "Computing explanations..."  <-- Stuck here
```

**Solutions**:

1. **Reduce operation count**:

   ```yaml
   # In jepsen-cnpg-job.yaml:
   - name: DURATION
     value: "60" # Shorter test (1 minute)
   - name: RATE
     value: "25" # Fewer ops/sec
   ```

2. **Extract partial results**:

   ```bash
   JEPSEN_POD=$(kubectl get pods -l app=jepsen-test -o jsonpath='{.items[0].metadata.name}')
   kubectl cp default/${JEPSEN_POD}:/jepsenpg/store/latest/history.edn ./history.edn
   # History file contains all operations even if analysis incomplete
   ```

3. **Increase resources**:
   ```yaml
   # In jepsen-cnpg-job.yaml:
   resources:
     limits:
       memory: "4Gi" # Default: 1Gi
       cpu: "2000m" # Default: 1000m
   ```

### Issue 6: High Failure Rate (>10%)

**Symptoms**:

```
:fail rate: 15.3%
```

**Diagnosis**:

```bash
# Check failover duration
kubectl logs -l cnpg.io/cluster=pg-eu | grep -i "failover\|promote"

# Check replication lag
kubectl cnpg status pg-eu
```

**Solutions**:

1. **Increase chaos interval**:

   ```yaml
   # Give more time between failures
   - name: CHAOS_INTERVAL
     value: "300" # 5 minutes instead of 3
   ```

2. **Enable synchronous replication**:

   ```yaml
   # In pg-eu-cluster.yaml:
   spec:
     postgresql:
       parameters:
         synchronous_commit: "on"
   ```

3. **Add more replicas**:
   ```yaml
   spec:
     instances: 5 # More replicas = faster failover
   ```

### Issue 7: `:valid? false` - Consistency Violation

**Symptoms**:

```clojure
{:valid? false
 :anomaly-types [:G2]
 :not #{:repeatable-read}}
```

**This is serious** - indicates actual consistency bug. Steps:

1. **Preserve evidence**:

   ```bash
   # Copy all results immediately
   cp -r logs/jepsen-chaos-* /backup/consistency-violation-$(date +%Y%m%d-%H%M%S)/

   # Export cluster state
   kubectl get all -l cnpg.io/cluster=pg-eu -o yaml > cluster-state.yaml
   kubectl logs -l cnpg.io/cluster=pg-eu --all-containers=true > cluster-logs.txt
   ```

2. **Analyze anomaly**:

   ```bash
   # Check results.edn for details
   grep -A 50 ":anomaly-types" logs/jepsen-chaos-*/results/results.edn

   # Look at timeline.html for operation patterns
   firefox logs/jepsen-chaos-*/results/timeline.html
   ```

3. **Report bug**:
   - File issue with CloudNativePG: https://github.com/cloudnative-pg/cloudnative-pg/issues
   - Include: results.edn, history.edn, cluster logs, timeline.html
   - Describe: test parameters, chaos configuration, cluster topology

---

## 🚀 Advanced Usage

### A. Custom Jepsen Command

For complete control, edit the Jepsen command in the Job manifest or orchestration script.

**Advanced options**:

- `--nemesis partition`: Add Jepsen network partitions (requires network chaos)
- `--max-writes-per-key 500`: More appends per key (longer analysis)
- `--key-count 100`: More keys (more parallelism)
- `--isolation serializable`: Test strictest isolation level

### B. Parallel Testing

Run multiple tests simultaneously against different clusters:

```bash
# Terminal 1: Test EU cluster
./scripts/run-jepsen-chaos-test.sh pg-eu app 600 &

# Terminal 2: Test US cluster
./scripts/run-jepsen-chaos-test.sh pg-us app 600 &

# Terminal 3: Test ASIA cluster
./scripts/run-jepsen-chaos-test.sh pg-asia app 600 &

# Wait for all
wait

# Compare results
for dir in logs/jepsen-chaos-*/; do
  echo "=== ${dir} ==="
  grep ":valid?" ${dir}/results/results.edn
done
```

### C. CI/CD Integration

**GitHub Actions example**:

```yaml
name: Chaos Testing
on: [push, pull_request]

jobs:
  jepsen-chaos:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Create kind cluster
        uses: helm/kind-action@v1.5.0

      - name: Install CloudNativePG
        run: |
          kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.20/releases/cnpg-1.20.0.yaml

      - name: Install Litmus
        run: |
          kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v1.13.8.yaml

      - name: Deploy test cluster
        run: |
          kubectl apply -f pg-eu-cluster.yaml
          kubectl wait --for=condition=ready cluster/pg-eu --timeout=300s

      - name: Run chaos test
        run: |
          kubectl apply -f litmus-rbac.yaml
          ./scripts/run-jepsen-chaos-test.sh pg-eu app 300

      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: jepsen-results
          path: logs/jepsen-chaos-*/

      - name: Check consistency
        run: |
          if grep -q ":valid? false" logs/jepsen-chaos-*/results/results.edn; then
            echo "❌ Consistency violation detected!"
            exit 1
          fi
          echo "✅ Consistency verified"
```

### D. Testing Different Isolation Levels

```bash
# Test read-committed (default)
sed -i 's/value: ".*" # ISOLATION/value: "read-committed" # ISOLATION/' workloads/jepsen-cnpg-job.yaml
./scripts/run-jepsen-chaos-test.sh pg-eu app 300

# Test repeatable-read
sed -i 's/value: ".*" # ISOLATION/value: "repeatable-read" # ISOLATION/' workloads/jepsen-cnpg-job.yaml
./scripts/run-jepsen-chaos-test.sh pg-eu app 300

# Test serializable (strictest)
sed -i 's/value: ".*" # ISOLATION/value: "serializable" # ISOLATION/' workloads/jepsen-cnpg-job.yaml
./scripts/run-jepsen-chaos-test.sh pg-eu app 300

# Compare results
for dir in logs/jepsen-chaos-*/; do
  isolation=$(grep "Isolation:" ${dir}/jepsen-live.log | head -1)
  valid=$(grep ":valid?" ${dir}/results/results.edn)
  echo "${isolation} => ${valid}"
done
```

### E. Monitoring During Tests

**Real-time monitoring** (in separate terminal):

```bash
# Watch cluster pods
./scripts/monitor-cnpg-pods.sh pg-eu default

# Or manual watch
watch -n 2 'kubectl get pods -l cnpg.io/cluster=pg-eu -o wide'

# Monitor Jepsen progress
kubectl logs -l app=jepsen-test -f | grep -E "Run complete|:valid\?|Error"

# Monitor chaos runner
kubectl logs -l app.kubernetes.io/component=experiment-job -f
```

**Grafana dashboards** (if using kube-prometheus-stack):

```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Open browser: http://localhost:3000
# Default credentials: admin/prom-operator

# Import CNPG dashboard:
# https://grafana.com/grafana/dashboards/cloudnativepg
```

---

## 📦 Project Archive

### What Was Moved

The `/archive` directory contains deprecated pgbench and E2E testing content:

```
archive/
├── scripts/           # pgbench initialization, E2E orchestration
├── workloads/         # pgbench continuous jobs
├── experiments/       # Non-Jepsen chaos experiments
├── docs/              # Deep-dive guides for pgbench approach
└── README.md          # Explanation of archived content
```

### Why Jepsen Only?

- **pgbench**: Good for performance testing, but lacks consistency verification
- **Jepsen**: Provides mathematical proof of consistency (Elle checker)
- **Simplicity**: One comprehensive testing approach vs. multiple partial ones
- **Industry standard**: Jepsen is the gold standard for distributed systems testing

See [`archive/README.md`](archive/README.md) for details on what was moved and why.

---

## 📚 Additional Resources

### External Documentation

- **Jepsen Framework**: https://jepsen.io/
- **ardentperf/jepsenpg**: https://github.com/ardentperf/jepsenpg
- **CloudNativePG Docs**: https://cloudnative-pg.io/documentation/current/
- **Litmus Chaos Docs**: https://litmuschaos.io/docs/
- **Elle Checker Paper**: https://github.com/jepsen-io/elle

### Included Guides

- **[ISOLATION_LEVELS_GUIDE.md](docs/ISOLATION_LEVELS_GUIDE.md)** - PostgreSQL isolation levels explained
- **[IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md)** - Architecture and design decisions
- **[WORKFLOW_DIAGRAM.md](WORKFLOW_DIAGRAM.md)** - Visual workflow representation

### Community

- **CloudNativePG Slack**: [Join here](https://cloudnative-pg.io/community/)
- **Issue Tracker**: https://github.com/cloudnative-pg/cloudnative-pg/issues
- **Discussions**: https://github.com/cloudnative-pg/cloudnative-pg/discussions

---

## 🤝 Contributing

We welcome contributions! Please see:

- **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** - Community guidelines
- **[GOVERNANCE.md](GOVERNANCE.md)** - Project governance model
- **[CODEOWNERS](CODEOWNERS)** - Maintainer responsibilities

### How to Contribute

1. **Fork the repository**
2. **Create feature branch**: `git checkout -b feature/my-improvement`
3. **Make changes** and test thoroughly
4. **Commit**: `git commit -m "feat: add new chaos scenario"`
5. **Push**: `git push origin feature/my-improvement`
6. **Open Pull Request** with detailed description

---

## 📜 License

Apache 2.0 - See [LICENSE](LICENSE)

---

## 🙏 Acknowledgments

- **CloudNativePG Team** - Kubernetes PostgreSQL operator excellence
- **Litmus Community** - CNCF chaos engineering framework
- **Aphyr (Kyle Kingsbury)** - Creating Jepsen and advancing distributed systems testing
- **ardentperf** - Pre-built jepsenpg Docker image
- **Elle Team** - Mathematical consistency verification

---

## 📈 Project Status

- **Current Version**: v2.0 (Jepsen-focused)
- **Status**: Production Ready ✅
- **Last Updated**: November 18, 2025
- **Tested With**:
  - CloudNativePG v1.20+
  - PostgreSQL 16
  - Litmus v1.13.8
  - Kubernetes v1.23-1.28

---

## 🆘 Getting Help

1. **Check [Troubleshooting](#-troubleshooting)** section above
2. **Review logs** in `logs/jepsen-chaos-<timestamp>/`
3. **Search existing issues**: https://github.com/cloudnative-pg/chaos-testing/issues
4. **Ask in discussions**: https://github.com/cloudnative-pg/chaos-testing/discussions
5. **Open new issue** with:
   - Kubernetes version
   - CloudNativePG version
   - Full error logs
   - Steps to reproduce

---

**Happy Chaos Testing! 🎯**
