# Step 2: Tool Installation Testing

## ✅ Step 1 Results
- **Status**: PASSED ✅
- **Free disk space**: 48 GB
- **Time**: ~3-5 minutes
- **All checks**: Passed

## 🔧 Step 2: Add Tool Installation

### What's New
Added tool installation step to the workflow:
```yaml
- name: Setup chaos testing tools
  uses: ./.github/actions/setup-tools

- name: Verify tools installed
  run: |
    kubectl version --client
    kind version
    helm version
    kubectl cnpg version
    jq --version
```

### What This Tests
- ✅ kubectl installs (latest stable)
- ✅ Kind installs (latest release)
- ✅ Helm installs (latest)
- ✅ krew installs (kubectl plugin manager)
- ✅ kubectl-cnpg plugin installs via krew
- ✅ jq is available

### Expected Results
- All tools install successfully
- Version commands work
- kubectl-cnpg plugin accessible via krew
- Time: ~5-8 minutes total (cleanup + tools)

### How to Test

```bash
cd /home/xploy04/Documents/chaos-testing/forks/chaos-testing

# Commit the updated workflow
git add .github/workflows/test-setup.yml
git commit -s -m "test: Add Step 2 - tool installation"
git push origin dev-2
```

Then on GitHub:
1. Go to Actions → "Test Setup Infrastructure (Step 2)"
2. Click "Run workflow"
3. Select branch: `dev-2`
4. Watch for:
   - ✅ Disk cleanup completes
   - ✅ kubectl installs
   - ✅ Kind installs
   - ✅ Helm installs
   - ✅ kubectl-cnpg plugin installs
   - ✅ All verification checks pass

### Next: Step 3
Once this passes, we'll add Kind cluster creation!
