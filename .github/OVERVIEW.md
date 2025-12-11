# GitHub Actions for CloudNativePG Chaos Testing

This directory contains GitHub Actions workflows and reusable composite actions for automated chaos testing of CloudNativePG clusters.

## Workflows

### `chaos-test-full.yml`

Comprehensive chaos testing workflow that validates PostgreSQL cluster resilience under failure conditions.

**What it does**:
- Provisions a Kind cluster using cnpg-playground
- Installs CloudNativePG operator and PostgreSQL cluster
- Deploys Litmus Chaos and Prometheus monitoring
- Runs Jepsen consistency tests with pod-delete chaos injection
- **Validates resilience** - fails the build if chaos tests don't pass
- Collects comprehensive artifacts including cluster state dumps on failure

**Triggers**:
- **Manual**: `workflow_dispatch` with configurable chaos duration (default: 300s)
- **Automatic**: Pull requests to `main` branch (skips documentation-only changes)
- **Scheduled**: Weekly on Sundays at 13:00 UTC

**Quality Gates**:
- Litmus chaos experiment must pass
- Jepsen consistency validation must pass (`:valid? true`)
- Workflow fails if either check fails

---

## Reusable Composite Actions

### `free-disk-space`

Removes unnecessary pre-installed software from GitHub runners to free up ~40GB of disk space.

**What it removes**:
- .NET SDK (~15-20 GB)
- Android SDK (~12 GB)
- Haskell tools (~5-8 GB)
- Large tool caches (CodeQL, Go, Python, Ruby, Node)
- Unused browsers

**What it preserves**:
- Docker
- kubectl
- Kind
- Helm
- jq

**Usage**:
```yaml
- name: Free disk space
  uses: ./.github/actions/free-disk-space
```

---

### `setup-tools`

Installs and upgrades chaos testing tools to latest stable versions.

**Tools installed/upgraded**:
- kubectl (latest stable)
- Kind (latest release)
- Helm (latest via official installer)
- krew (kubectl plugin manager)
- kubectl-cnpg plugin (via krew)

**Usage**:
```yaml
- name: Setup chaos testing tools
  uses: ./.github/actions/setup-tools
```

---

### `setup-kind`

Creates a Kind cluster using the proven cnpg-playground configuration.

**Features**:
- Multi-node cluster with PostgreSQL-labeled nodes
- Configured for HA testing
- Proven configuration from cnpg-playground

**Inputs**:
- `region` (optional): Region name for the cluster (default: `eu`)

**Outputs**:
- `kubeconfig`: Path to kubeconfig file
- `cluster-name`: Name of the created cluster

**Usage**:
```yaml
- name: Create Kind cluster
  uses: ./.github/actions/setup-kind
  with:
    region: eu
```

---

### `setup-cnpg`

Installs CloudNativePG operator and deploys a PostgreSQL cluster.

**What it does**:
1. Installs CNPG operator using `kubectl cnpg install generate` (recommended method)
2. Waits for operator deployment to be ready
3. Applies CNPG operator configuration
4. Waits for webhook to be fully initialized
5. Deploys PostgreSQL cluster
6. Waits for cluster to be ready with health checks

**Requirements**:
- `clusters/cnpg-config.yaml` - CNPG operator configuration
- `clusters/pg-eu-cluster.yaml` - PostgreSQL cluster definition

**Usage**:
```yaml
- name: Setup CloudNativePG
  uses: ./.github/actions/setup-cnpg
```

---

### `setup-litmus`

Installs Litmus Chaos operator, experiments, and RBAC configuration.

**What it installs**:
- litmus-core operator (via Helm)
- pod-delete chaos experiment
- Litmus RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)

**Verification**:
- Checks all CRDs are installed
- Verifies operator is ready
- Validates RBAC permissions

**Requirements**:
- `litmus-rbac.yaml` - RBAC configuration file

**Usage**:
```yaml
- name: Setup Litmus Chaos
  uses: ./.github/actions/setup-litmus
```

---

### `setup-prometheus`

Installs Prometheus and Grafana monitoring using cnpg-playground's built-in monitoring solution.

**What it installs**:
- Prometheus Operator (via cnpg-playground monitoring/setup.sh)
- Grafana Operator with official CNPG dashboard
- CNPG PodMonitor for PostgreSQL metrics

**Requirements**:
- `monitoring/podmonitor-pg-eu.yaml` - CNPG PodMonitor configuration
- cnpg-playground must be cloned to `/tmp/cnpg-playground` (done by setup-kind action)

**Usage**:
```yaml
- name: Setup Prometheus
  uses: ./.github/actions/setup-prometheus
```

---

## Artifacts

Each workflow run produces the following artifacts (retained for 30 days):

**Jepsen Results**:
- `history.edn` - Operation history
- `STATISTICS.txt` - Test statistics
- `*.png` - Visualization graphs

**Litmus Results**:
- `chaosresult.yaml` - Chaos experiment results

**Logs**:
- `test.log` - Complete test execution log

**Cluster State** (on failure only):
- `cluster-state-dump.yaml` - Complete cluster state including pods, events, and operator logs

---

## Usage in Other Workflows

You can reuse these actions in your own workflows:

```yaml
name: My Chaos Test

on:
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: write
    
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
      
      - name: Free disk space
        uses: ./.github/actions/free-disk-space
      
      - name: Setup tools
        uses: ./.github/actions/setup-tools
      
      - name: Create cluster
        uses: ./.github/actions/setup-kind
        with:
          region: us
      
      - name: Setup CNPG
        uses: ./.github/actions/setup-cnpg
      
      # Your custom chaos testing steps here
```

---