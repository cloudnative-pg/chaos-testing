# Testing GitHub Actions in Your Fork

## ✅ Setup Complete!

All GitHub Actions files have been copied to your fork at:
`/home/xploy04/Documents/chaos-testing/forks/chaos-testing`

## 📁 Files Copied

```
.github/
├── README.md                           # Documentation
├── actions/
│   ├── free-disk-space/
│   │   └── action.yml                  # Disk cleanup action
│   ├── setup-tools/
│   │   └── action.yml                  # Tool installation
│   └── setup-kind/
│       ├── action.yml                  # Kind cluster setup
│       └── kind-config.yaml            # Cluster configuration
└── workflows/
    └── test-setup.yml                  # Test workflow (Step 1: disk cleanup only)
```

## 🚀 Step-by-Step Testing Plan

### Step 1: Test Disk Cleanup (Current)

**What to do:**
```bash
cd /home/xploy04/Documents/chaos-testing/forks/chaos-testing

# Add all files
git add .github/

# Commit
git commit -s -m "test: Add Step 1 - disk cleanup action"

# Push to your fork
git push origin dev-2
```

**Then on GitHub:**
1. Go to: https://github.com/XploY04/chaos-testing/actions
2. Click "Test Disk Cleanup (Step 1)"
3. Click "Run workflow"
4. Select branch: `dev-2`
5. Click "Run workflow"

**Expected results (~3-5 minutes):**
- ✅ Disk space increases from ~21-28 GB to ~50-60 GB free
- ✅ Docker still works
- ✅ Essential tools (jq, curl, git) still work

### Step 2: Add Tool Installation (After Step 1 passes)

I'll update the workflow to add:
```yaml
- name: Setup chaos testing tools
  uses: ./.github/actions/setup-tools
```

Test that kubectl, Kind, Helm, kubectl-cnpg install correctly.

### Step 3: Add Kind Cluster Setup (After Step 2 passes)

Add:
```yaml
- name: Setup Kind cluster
  uses: ./.github/actions/setup-kind

- name: Verify cluster
  run: kubectl get nodes
```

Test that 3-node cluster creates with PostgreSQL labels.

### Step 4: Add CNPG Installation (After Step 3 passes)

And so on...

## 📊 Current Status

- [x] Disk cleanup action created
- [x] Tool installation action created
- [x] Kind cluster action created
- [x] Test workflow created (Step 1 only)
- [x] Files copied to fork
- [ ] **Next: Commit and test Step 1**

## 🔍 What Each Step Tests

| Step | Action | What It Tests | Time |
|------|--------|---------------|------|
| 1 | Disk cleanup | Removes .NET, Android, Haskell, etc. | ~3-5 min |
| 2 | Tool installation | Installs kubectl, Kind, Helm, cnpg plugin | ~2-3 min |
| 3 | Kind cluster | Creates 3-node cluster with labels | ~3-5 min |
| 4 | CNPG operator | Installs operator via plugin | ~2-3 min |
| 5 | PostgreSQL cluster | Deploys pg-eu cluster | ~3-5 min |
| 6 | Litmus chaos | Installs Litmus operator + experiments | ~3-5 min |
| 7 | Prometheus | Installs monitoring (no Grafana) | ~3-5 min |
| 8 | Full chaos test | Runs Jepsen + chaos experiment | ~10-15 min |

## 🎯 Ready to Start!

Run these commands to begin testing:

```bash
cd /home/xploy04/Documents/chaos-testing/forks/chaos-testing
git add .github/
git commit -s -m "test: Add Step 1 - disk cleanup action"
git push origin dev-2
```

Then go to GitHub Actions and run the workflow!
