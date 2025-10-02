# CloudNativePG Chaos Experiments - Hands-on Guide

This guide provides step-by-step instructions for running chaos experiments on CloudNativePG PostgreSQL clusters.

## Prerequisites

Before starting, ensure you have completed the environment setup:

### 1. CloudNativePG Environment Setup

Follow the official setup guide:

📚 **[CloudNativePG Playground Setup](https://github.com/cloudnative-pg/cnpg-playground/blob/main/README.md)**

This will provide you with:

- Kind Kubernetes clusters (k8s-eu, k8s-us)
- CloudNativePG operator installed
- PostgreSQL clusters ready for testing

### 2. Verify Environment Readiness

After completing the playground setup, verify your environment:

```bash
# Clone this repository if you haven't already
git clone https://github.com/cloudnative-pg/chaos-testing.git
cd chaos-testing

# Verify environment is ready for chaos experiments
./scripts/check-environment.sh
```

The verification script checks:

- ✅ Kubernetes cluster connectivity
- ✅ CloudNativePG operator status
- ✅ PostgreSQL cluster health
- ✅ Required tools (kubectl, cnpg plugin)

## LitmusChaos Installation

### Option 1: Operator Installation (Recommended)

```bash
# Install LitmusChaos operator
kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v3.10.0.yaml

# Wait for operator to be ready
kubectl rollout status deployment -n litmus chaos-operator-ce

# Install pod-delete experiment
kubectl apply -f https://hub.litmuschaos.io/api/chaos/master?file=faults/kubernetes/pod-delete/fault.yaml

# Create RBAC for chaos experiments
kubectl apply -f litmus-rbac.yaml
```

### Option 2: Chaos Center (UI-based)

For a graphical interface, follow the [Chaos Center installation guide](https://docs.litmuschaos.io/docs/getting-started/installation#install-chaos-center).

### Option 3: LitmusCTL (CLI)

Install the LitmusCTL CLI following the [official documentation](https://docs.litmuschaos.io/docs/litmusctl-installation).

## Available Chaos Experiments

### 1. Replica Pod Delete (Low Risk)

**Purpose**: Test replica pod recovery and replication resilience.

**What it does**:

- Randomly selects replica pods (excludes primary)
- Deletes pods with configurable intervals
- Validates automatic recovery

**Execute**:

```bash
# Run replica pod deletion experiment
kubectl apply -f experiments/cnpg-replica-pod-delete.yaml

# Monitor experiment
kubectl get chaosengines -w
```

### 2. Primary Pod Delete (High Risk)

**Purpose**: Test failover mechanisms and primary election.

⚠️ **Warning**: This triggers failover and may cause temporary unavailability.

**What it does**:

- Targets the primary PostgreSQL pod
- Forces failover to a replica
- Tests automatic primary election

**Execute**:

```bash
# Run primary pod deletion experiment
kubectl apply -f experiments/cnpg-primary-pod-delete.yaml

# Monitor failover process
kubectl cnpg status pg-eu -w
```

### 3. Random Pod Delete (Medium Risk)

**Purpose**: Test overall cluster resilience with unpredictable failures.

**What it does**:

- Randomly selects any pod in the cluster
- May target primary or replica
- Tests general fault tolerance

**Execute**:

```bash
# Run random pod deletion experiment
kubectl apply -f experiments/cnpg-random-pod-delete.yaml

# Monitor cluster health
kubectl get pods -l cnpg.io/cluster=pg-eu -w
```

## Monitoring Experiments

### Real-time Monitoring

```bash
# Watch chaos engines
kubectl get chaosengines -w

# Watch PostgreSQL pods
kubectl get pods -l cnpg.io/cluster=pg-eu -w

# Monitor cluster status
kubectl cnpg status pg-eu

# View experiment logs
kubectl get jobs | grep pod-delete
kubectl logs job/<job-name>
```

### Experiment Parameters

Key configuration parameters in the experiments:

| Parameter              | Description                   | Default Value    |
| ---------------------- | ----------------------------- | ---------------- |
| `TOTAL_CHAOS_DURATION` | Duration of chaos injection   | 30s              |
| `RAMP_TIME`            | Preparation time before/after | 10s              |
| `CHAOS_INTERVAL`       | Wait time between deletions   | 15s              |
| `TARGET_PODS`          | Specific pods to target       | Random selection |
| `PODS_AFFECTED_PERC`   | Percentage of pods to affect  | 50%              |
| `SEQUENCE`             | Execution mode                | serial           |
| `FORCE`                | Force delete pods             | true             |

## Results Analysis

### Getting Results

```bash
# Get comprehensive results summary
./scripts/get-chaos-results.sh

# Check specific chaos results
kubectl get chaosresults

# Detailed result analysis
kubectl describe chaosresult <result-name>
```

### Expected Successful Results

✅ **Healthy Experiment Results**:

- **Verdict**: Pass
- **Phase**: Completed
- **Success Rate**: 100%
- **Cluster Status**: Healthy
- **Recovery Time**: < 2 minutes
- **Replication Lag**: Minimal (< 1s)

### Interpreting Results

**Experiment Verdict**:

- `Pass`: Experiment completed successfully, cluster recovered
- `Fail`: Issues detected during experiment
- `Error`: Experiment configuration or execution problems

**Cluster Health Indicators**:

- All pods in `Running` state
- Primary and replicas healthy
- Replication slots active
- Zero replication lag

## Troubleshooting

### Common Issues

#### 1. Experiment Fails with "No Target Pods Found"

```bash
# Check if PostgreSQL cluster exists
kubectl get cluster pg-eu

# Verify pod labels
kubectl get pods -l cnpg.io/cluster=pg-eu --show-labels

# Check experiment configuration
kubectl describe chaosengine <engine-name>
```

#### 2. Pods Stuck in Pending State

```bash
# Check node resources
kubectl describe nodes

# Check pod events
kubectl describe pod <pod-name>

# Verify storage classes
kubectl get storageclass
```

#### 3. Chaos Operator Not Ready

```bash
# Check operator status
kubectl get pods -n litmus

# Check operator logs
kubectl logs -n litmus deployment/chaos-operator-ce

# Reinstall if needed
kubectl delete -f https://litmuschaos.github.io/litmus/litmus-operator-v3.10.0.yaml
kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v3.10.0.yaml
```

#### 4. RBAC Permission Issues

```bash
# Verify service account
kubectl get serviceaccount litmus-admin

# Check cluster role bindings
kubectl get clusterrolebinding litmus-admin

# Reapply RBAC if needed
kubectl apply -f litmus-rbac.yaml
```

### Environment Verification

If experiments fail, rerun the environment check:

```bash
./scripts/check-environment.sh
```

## Advanced Usage

### Custom Experiment Configuration

You can modify experiment parameters by editing the YAML files:

```yaml
# Example: Increase chaos duration
- name: TOTAL_CHAOS_DURATION
  value: "60" # 60 seconds instead of 30

# Example: Target specific pods
- name: TARGET_PODS
  value: "pg-eu-2,pg-eu-3" # Specific replicas

# Example: Parallel execution
- name: SEQUENCE
  value: "parallel" # Instead of serial
```

### Creating Custom Experiments

1. Copy an existing experiment file
2. Modify the metadata and parameters
3. Test with short duration first
4. Gradually increase complexity

### Cleanup

```bash
# Delete active chaos experiments
kubectl delete chaosengine --all

# Clean up chaos results
kubectl delete chaosresults --all

# Remove experiment resources (optional)
kubectl delete chaosexperiments --all
```

## Best Practices

1. **Start Small**: Begin with replica experiments before primary
2. **Monitor Continuously**: Watch cluster health during experiments
3. **Test in Development**: Never run untested experiments in production
4. **Document Results**: Keep records of experiment outcomes
5. **Gradual Complexity**: Increase experiment complexity over time
6. **Backup Strategy**: Ensure backups are available before testing
7. **Team Communication**: Notify team members before disruptive tests

## Next Steps

- Experiment with different parameter values
- Create custom chaos scenarios
- Integrate with CI/CD pipelines
- Set up monitoring and alerting
- Explore other LitmusChaos experiments (network, CPU, memory)

## Support and Community

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [LitmusChaos Documentation](https://docs.litmuschaos.io/)
- [CloudNativePG Community](https://github.com/cloudnative-pg/cloudnative-pg)
- [LitmusChaos Community](https://github.com/litmuschaos/litmus)
