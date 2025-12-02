# CloudNativePG Chaos Testing with Jepsen

![CloudNativePG Logo](logo/cloudnativepg.png)

Production-ready Jepsen and Litmus chaos automation for CloudNativePG (CNPG) clusters.

---

## 🚀 Quick Start

**Want to run chaos testing immediately?** Follow these streamlined steps:

0. **Clone this repo** → Get the chaos experiments and scripts (section 0)
1. **Setup cluster** → Bootstrap CNPG Playground (section 1)
2. **Install CNPG** → Deploy operator + sample cluster (section 2)
3. **Install Litmus** → Install operator, experiments, and RBAC (sections 3, 3.5, 3.6)
4. **Smoke-test chaos** → Run the quick pod-delete check without monitoring (section 4)
5. **Add monitoring** → Install Prometheus for probe validation (section 5; required before section 6 with probes enabled)
6. **Run Jepsen** → Full consistency testing layered on chaos (section 6)

**First time users:** Use section 4 as a smoke test without Prometheus, then return to section 5 to install monitoring before running the Jepsen workflow in section 6.

---

## ✅ Prerequisites

- Linux/macOS shell with `bash`, `git`, `curl`, `jq`, and internet access.
- Container + Kubernetes tooling: Docker **or** Podman, the [Kind CLI](https://kind.sigs.k8s.io/) tool, `kubectl`, `helm`, the [`kubectl cnpg` plugin](https://cloudnative-pg.io/documentation/current/kubectl-plugin/) binary, and the [`cmctl` utility](https://cert-manager.io/docs/reference/cmctl/) for cert-manager.
- Install the CNPG plugin using kubectl krew (recommended):
  ```bash
  # Install or update to the latest version
  kubectl krew update
  kubectl krew install cnpg || kubectl krew upgrade cnpg
  kubectl cnpg version
  ```
  > **Alternative installation methods:**
  > - For Debian/Ubuntu: Download `.deb` from [releases page](https://github.com/cloudnative-pg/cloudnative-pg/releases)
  > - For RHEL/Fedora: Download `.rpm` from [releases page](https://github.com/cloudnative-pg/cloudnative-pg/releases)
  > - See [official installation docs](https://cloudnative-pg.io/documentation/current/kubectl-plugin) for all methods
- Optional but recommended: `kubectx`, `stern`, `kubectl-view-secret` (see the [CNPG Playground README](https://github.com/cloudnative-pg/cnpg-playground#prerequisites) for a complete list).
- **Disk Space:** Minimum **30GB** free disk space recommended:
  - Kind cluster nodes: ~5GB
  - Container images: ~5GB (first run with image pull)
  - Prometheus/MongoDB storage: ~10GB
  - Jepsen results + logs: ~5GB
  - Buffer for growth: ~5GB
- Sufficient local resources for a multi-node Kind cluster (≈8 CPUs / 12 GB RAM) and permission to run port-forwards.

Once the tooling is present, everything else is managed via repository scripts and Helm charts.

---

## ⚡ Setup and Configuration

> Follow these sections in order; each references the authoritative upstream documentation to keep this README concise.

### 0. Clone the Chaos Testing Repository

**First, clone this repository to access the chaos experiments and scripts:**

```bash
git clone https://github.com/cloudnative-pg/chaos-testing.git
cd chaos-testing
```

All subsequent commands reference files in this repository (experiments, scripts, monitoring configs). Keep this terminal window open.

### 1. Bootstrap the CNPG Playground

The upstream documentation provides detailed instructions for prerequisites and networking. Follow the setup instructions here: <https://github.com/cloudnative-pg/cnpg-playground#usage>.

**Open a new terminal** and run:

```bash
git clone https://github.com/cloudnative-pg/cnpg-playground.git
cd cnpg-playground
./scripts/setup.sh eu         # creates kind-k8s-eu cluster
./scripts/info.sh             # displays contexts and access information
export KUBECONFIG=$PWD/k8s/kube-config.yaml
kubectl config use-context kind-k8s-eu
```

### 2. Install CloudNativePG and Create the PostgreSQL Cluster

With the Kind cluster running, install the operator using the **kubectl cnpg plugin** as recommended in the [CloudNativePG Installation & Upgrades guide](https://cloudnative-pg.io/documentation/current/installation_upgrade/). This approach ensures you get the latest stable operator version:

**In the cnpg-playground terminal:**

```bash
# Re-export the playground kubeconfig if you opened a new shell
export KUBECONFIG=$PWD/k8s/kube-config.yaml
kubectl config use-context kind-k8s-eu

# Install the latest operator version using the kubectl cnpg plugin
kubectl cnpg install generate --control-plane | \
  kubectl --context kind-k8s-eu apply -f - --server-side

# Verify the controller rollout
kubectl --context kind-k8s-eu rollout status deployment \
  -n cnpg-system cnpg-controller-manager
```

Apply the operator config map:

```bash
kubectl apply -f clusters/cnpg-config.yaml
kubectl rollout restart -n cnpg-system deployment cnpg-controller-manager
```

**Switch back to the chaos-testing terminal:**

```bash
# Create the pg-eu PostgreSQL cluster for chaos testing
kubectl apply -f clusters/pg-eu-cluster.yaml

# Verify cluster is ready (this will watch until healthy)
kubectl get cluster pg-eu -w  # Wait until status shows "Cluster in healthy state"
# Press Ctrl+C when you see: pg-eu   3       3   ready   XX m
```

### 3. Install Litmus Chaos

Litmus 3.x separates the operator (via `litmus-core`) from the ChaosCenter UI (via `litmus` chart). Install both, then add the experiment definitions and RBAC:

```bash
# Add Litmus Helm repository
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update

# Install litmus-core (operator + CRDs)
helm upgrade --install litmus-core litmuschaos/litmus-core \
  --namespace litmus --create-namespace \
  --wait --timeout 10m

# Verify CRDs are installed
kubectl get crd chaosengines.litmuschaos.io chaosexperiments.litmuschaos.io chaosresults.litmuschaos.io

# Verify operator is running
kubectl -n litmus get deploy litmus
kubectl -n litmus wait --for=condition=Available deployment/litmus --timeout=5m
```

### 3.5. Install ChaosExperiment Definitions

The ChaosEngine requires ChaosExperiment resources to exist before it can run. Install the `pod-delete` experiment:

```bash
# Install from Chaos Hub (has namespace: default hardcoded, so override it)
kubectl apply --namespace=litmus -f https://hub.litmuschaos.io/api/chaos/master?file=faults/kubernetes/pod-delete/fault.yaml

# Verify experiment is installed
kubectl -n litmus get chaosexperiments
# Should show: pod-delete
```

### 3.6. Configure RBAC for Chaos Experiments

Apply the RBAC configuration and verify the service account has correct permissions:

```bash
# Apply RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
kubectl apply -f litmus-rbac.yaml

# Verify the ServiceAccount exists in litmus namespace
kubectl -n litmus get serviceaccount litmus-admin

# Verify the ClusterRoleBinding points to correct namespace
kubectl get clusterrolebinding litmus-admin -o jsonpath='{.subjects[0].namespace}'
# Should output: litmus (not default)

# Test permissions (optional)
kubectl auth can-i delete pods --as=system:serviceaccount:litmus:litmus-admin -n default
# Should output: yes
```

> **Important:** The `litmus-rbac.yaml` ClusterRoleBinding must reference `namespace: litmus` in the subjects section. If you see errors like `"litmus-admin" cannot get resource "chaosengines"`, verify the namespace matches where the ServiceAccount exists.

### 4. (Optional) Test Chaos Without Monitoring

Before setting up the full monitoring stack, you can verify chaos mechanics work independently:

```bash
# Apply the probe-free chaos engine (no Prometheus dependency)
kubectl apply -f experiments/cnpg-jepsen-chaos-noprobes.yaml

# Watch the chaos runner pod start (refreshes every 2s)
# Press Ctrl+C once you see the runner pod appear
watch -n2 'kubectl -n litmus get pods | grep cnpg-jepsen-chaos-noprobes-runner'

# Monitor CNPG pod deletions in real-time
bash scripts/monitor-cnpg-pods.sh pg-eu default litmus kind-k8s-eu

# Wait for chaos runner pod to be created, then check logs
kubectl -n litmus wait --for=condition=ready pod -l chaos-runner-name=cnpg-jepsen-chaos-noprobes --timeout=60s && \
runner_pod=$(kubectl -n litmus get pods -l chaos-runner-name=cnpg-jepsen-chaos-noprobes -o jsonpath='{.items[0].metadata.name}') && \
kubectl -n litmus logs -f "$runner_pod"

# After completion, check the result (engine name differs)
kubectl -n litmus get chaosresult cnpg-jepsen-chaos-noprobes-pod-delete -o jsonpath='{.status.experimentStatus.verdict}'
# Should output: Pass (if probes are disabled) or Error (if Prometheus probes enabled but Prometheus not installed)

# Clean up for next test
kubectl -n litmus delete chaosengine cnpg-jepsen-chaos-noprobes
```

**What to observe:**

- The runner pod starts and creates an experiment pod (`pod-delete-xxxxx`)
- CNPG primary pods are deleted every 60 seconds
- CNPG automatically promotes a replica to primary after each deletion
- Deleted pods are recreated by the StatefulSet controller
- The experiment runs for 10 minutes (TOTAL_CHAOS_DURATION=600)

> **Note:** Keep using `experiments/cnpg-jepsen-chaos-noprobes.yaml` until Section 5 installs Prometheus/Grafana. Once monitoring is online, switch to `experiments/cnpg-jepsen-chaos.yaml` (probes enabled) for full observability.

### 5. Configure monitoring (Prometheus + Grafana)

If you already have Prometheus/Grafana installed, skip to the PodMonitor step. Otherwise, install **kube-prometheus-stack**:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
   --namespace monitoring --create-namespace
```

Expose the CNPG metrics port (9187) through a dedicated Service + ServiceMonitor bundle, then verify Prometheus scrapes it. Manual management keeps you aligned with the operator deprecation of `spec.monitoring.enablePodMonitor` and dodges the PodMonitor regression in kube-prometheus-stack v79 where CNPG pods only advertise the `postgresql` and `status` ports:

```bash
# Create monitoring namespace if it doesn't exist
kubectl create namespace monitoring 2>/dev/null || true
# Clean out the legacy PodMonitor if you created one earlier
kubectl -n monitoring delete podmonitor pg-eu --ignore-not-found
# Apply the Service + ServiceMonitor bundle (same file path as before)
kubectl apply -f monitoring/podmonitor-pg-eu.yaml
kubectl -n default get svc pg-eu-metrics
kubectl -n monitoring get servicemonitors pg-eu

# The ServiceMonitor ships with label release=prometheus so the kube-prometheus-stack
# Prometheus instance (which matches on that label) will actually scrape it.

# Verify Prometheus health and targets (look for job "serviceMonitor/monitoring/pg-eu/0")
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090 &
curl -s "http://localhost:9090/api/v1/targets?state=active" | jq '.data.activeTargets[] | {labels, health}'
curl -s "http://localhost:9090/api/v1/query?query=sum(cnpg_collector_up{cluster=\"pg-eu\"})"

# Access Grafana dashboard (optional)
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80

# Once that’s running, open http://localhost:3000 with:
#   Username: admin
#   Password: (decode the generated secret)
#     kubectl -n monitoring get secret prometheus-grafana \
#       -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

Import the official dashboard JSON from <https://github.com/cloudnative-pg/grafana-dashboards/blob/main/charts/cluster/grafana-dashboard.json> (Dashboards → New → Import). Reapply the Service/ServiceMonitor manifest whenever you recreate the `pg-eu` cluster so Prometheus resumes scraping immediately, and extend `monitoring/podmonitor-pg-eu.yaml` (e.g., TLS, interval, labels) to match your environment instead of relying on deprecated automatic generation.

> **Tip:** Once the ServiceMonitor is in place the CNPG metrics ship with `namespace="default"`, so the Grafana dashboard's `operator_namespace` dropdown will populate with `default`. Pick it (or set the variable's default to `default`) to avoid the "No data" empty-state.

> ✅ **Required before section 6 (when probes are enabled):** Complete this monitoring setup so the Prometheus probes defined in `experiments/cnpg-jepsen-chaos.yaml` can succeed.

### 6. Run the Jepsen chaos test

```bash
./scripts/run-jepsen-chaos-test.sh pg-eu app 600
```

This script deploys Jepsen (`jepsenpg` image), applies the Litmus ChaosEngine (primary pod delete), monitors logs, collects Elle results, and cleans up transient resources **automatically** (no manual exit needed - the script handles everything).

**Prerequisites before running the script:**

- Section 5 completed (Prometheus/Grafana running) so probes succeed.
- Chaos workflow validated (run `experiments/cnpg-jepsen-chaos.yaml` once manually if you need to confirm Litmus + CNPG wiring).
- Docker registry access to pull `ardentperf/jepsenpg` image (or pre-pulled into cluster).
- `kubectl` context pointing to the playground cluster with sufficient resources.
- **Increase max open files limit** if needed (required for Jepsen on some systems):
  ```bash
  ulimit -n 65536
  ```
  > This may need to be configured in your container runtime or Kind cluster configuration if running in a containerized environment.

**Script knobs:**

- `LITMUS_NAMESPACE` (default `litmus`) – set if you installed Litmus in a different namespace.
- `PROMETHEUS_NAMESPACE` (default `monitoring`) – used to auto-detect the Prometheus service backing Litmus probes.
- `JEPSEN_IMAGE` is pinned to `ardentperf/jepsenpg@sha256:4a3644d9484de3144ad2ea300e1b66568b53d85a87bf12aa64b00661a82311ac` for reproducibility. Update this digest only after verifying upstream releases.

### 7. Inspect test results

- All test results are stored under `logs/jepsen-chaos-<timestamp>/`.
- Quick validation commands:

  ```bash
  # Check Jepsen consistency verdict
  grep ":valid?" logs/jepsen-chaos-*/results/results.edn

  # Check operation statistics
  tail -20 logs/jepsen-chaos-*/results/STATISTICS.txt

  # Check Litmus chaos verdict (note: use -n litmus, not -n default)
  kubectl -n litmus get chaosresult cnpg-jepsen-chaos-pod-delete \
     -o jsonpath='{.status.experimentStatus.verdict}'

  # View full chaos result details
  kubectl -n litmus get chaosresult cnpg-jepsen-chaos-pod-delete -o yaml

  # Check probe results (if Prometheus was installed)
  kubectl -n litmus get chaosresult cnpg-jepsen-chaos-pod-delete \
     -o jsonpath='{.status.probeStatuses}' | jq
  ```

- Archive `results/results.edn`, `history.edn`, and `chaos-results/chaosresult.yaml` for analysis or reporting.

---

## 📦 Results & logs

- Each run creates a folder under `logs/jepsen-chaos-<timestamp>/`.
- Key files:
  - `results/results.edn` → Elle verdict (`:valid? true|false`).
  - `results/STATISTICS.txt` → `:ok/:fail` counts.
  - `results/chaos-results/chaosresult.yaml` → Litmus verdict + probe output.
- Quick checks:

  ```bash
  # Jepsen results
  grep ":valid?" logs/jepsen-chaos-*/results/results.edn
  tail -20 logs/jepsen-chaos-*/results/STATISTICS.txt

  # Chaos results (note: namespace is 'litmus' by default)
  kubectl -n litmus get chaosresult cnpg-jepsen-chaos-pod-delete \
     -o jsonpath='{.status.experimentStatus.verdict}'
  ```

---

## 🔗 References & more docs

- CNPG Playground: https://github.com/cloudnative-pg/cnpg-playground
- CloudNativePG Installation & Upgrades (v1.27): https://cloudnative-pg.io/documentation/1.27/installation_upgrade/
- Litmus Helm chart: https://github.com/litmuschaos/litmus-helm/
- kube-prometheus-stack: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- CNPG Grafana dashboards: https://github.com/cloudnative-pg/grafana-dashboards
- License: Apache 2.0 (see `LICENSE`).

---

## 🔧 Monitoring and Observability Tools

### Real-time Monitoring Script

Watch CNPG pods, chaos engines, and cluster events during experiments:

```bash
# Monitor pod deletions and failovers in real-time
bash scripts/monitor-cnpg-pods.sh <cluster-name> <cnpg-namespace> <chaos-namespace> <kube-context>

# Example
bash scripts/monitor-cnpg-pods.sh pg-eu default litmus kind-k8s-eu
```

**What it shows:**

- CNPG pod status with role labels (primary/replica)
- Active ChaosEngines in the chaos namespace
- Recent Kubernetes events (pod deletions, promotions, etc.)
- Updates every 2 seconds

## 📚 Additional Resources

- **CNPG Documentation:** <https://cloudnative-pg.io/documentation/>
- **Litmus Documentation:** <https://docs.litmuschaos.io/>
- **Jepsen Documentation:** <https://jepsen.io/>
- **Elle Consistency Checker:** <https://github.com/jepsen-io/elle>
- **PostgreSQL High Availability:** <https://www.postgresql.org/docs/current/high-availability.html>

---

Follow the sections above to execute chaos tests. Review the logs for analysis, and consult the `/archive` directory for additional documentation if needed.
