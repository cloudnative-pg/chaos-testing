# Chaos Testing - GitHub Actions

This directory contains GitHub Actions workflows and reusable actions for automated chaos testing.

## Directory Structure

```
.github/
├── actions/                    # Reusable composite actions
│   ├── free-disk-space/       # Free up ~31 GB disk space
│   ├── setup-tools/           # Install kubectl, Kind, Helm, cnpg plugin
│   └── setup-kind/            # Create Kind cluster with PostgreSQL nodes
└── workflows/                  # Workflow definitions
    └── test-setup.yml         # Test infrastructure setup
```

## Reusable Actions

### free-disk-space
Removes unnecessary pre-installed software from GitHub runners while preserving tools needed for chaos testing.

**Usage:**
```yaml
- uses: ./.github/actions/free-disk-space
```

**What it removes:**
- .NET SDK (~15-20 GB)
- Android SDK (~12 GB)
- Haskell/GHC (~5-8 GB)
- Cached tool versions (Go, Python, Ruby, Node)
- CodeQL (~5 GB)
- Unused browsers (Firefox, Edge)
- Package manager caches

**What it preserves:**
- Docker (required for Kind)
- kubectl, Kind, Helm (pre-installed on ubuntu-latest)
- jq, curl, git, bash
- System Python and Node

**Expected space freed:** ~35-40 GB

### setup-tools
Installs all required tools for chaos testing.

**Usage:**
```yaml
- uses: ./.github/actions/setup-tools
  with:
    kind-version: 'v0.20.0'  # optional
    helm-version: 'v3.13.0'  # optional
```

**Installs:**
- kubectl (latest stable)
- Kind (v0.20.0)
- Helm (v3.13.0)
- kubectl-cnpg plugin (via krew)
- jq

### setup-kind
Creates a Kind Kubernetes cluster with nodes labeled for PostgreSQL workloads.

**Usage:**
```yaml
- uses: ./.github/actions/setup-kind
  with:
    cluster-name: 'chaos-test'  # optional
    config-file: '.github/actions/setup-kind/kind-config.yaml'  # optional
```

**Cluster configuration:**
- 1 control-plane node
- 2 worker nodes with `node-role.kubernetes.io/postgres` label
- PostgreSQL nodes have NoSchedule taint

## Testing

### Manual Testing
Run the test workflow manually:
1. Go to Actions tab
2. Select "Test Setup Infrastructure"
3. Click "Run workflow"
4. Optionally skip disk cleanup for faster testing

### Expected Results
- ✅ All tools installed successfully
- ✅ Kind cluster created with 3 nodes
- ✅ 2 nodes labeled for PostgreSQL
- ✅ Cluster accessible via kubectl
- ✅ kubectl-cnpg plugin working

## Next Steps

After validating the setup infrastructure:
1. Add CNPG installation action
2. Add Litmus chaos installation action
3. Add Prometheus monitoring setup
4. Create main chaos testing workflow
