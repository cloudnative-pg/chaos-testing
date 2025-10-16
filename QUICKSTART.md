# Quick Start: Running CloudNativePG Chaos Experiments

## Prerequisites

- Kubernetes cluster with CloudNativePG operator installed
- LitmusChaos operator installed
- CloudNativePG cluster running (e.g., `pg-eu`)

## Setup (One Time)

### 1. Apply RBAC

```bash
kubectl apply -f litmus-rbac.yaml
```

### 2. Apply ChaosExperiment Override

```bash
kubectl apply -f chaosexperiments/pod-delete-cnpg.yaml
```

## Running Experiments

### Random Pod Delete

Randomly deletes any pod in the cluster:

```bash
kubectl apply -f experiments/cnpg-random-pod-delete.yaml
```

Watch the chaos:

```bash
kubectl logs -n default -l app=cnpg-random-pod-delete -f
```

### Primary Pod Delete

Deletes the current primary pod (tracks role across failovers):

```bash
kubectl apply -f experiments/cnpg-primary-pod-delete.yaml
```

Watch the chaos:

```bash
kubectl logs -n default -l app=cnpg-primary-pod-delete -f
```

### Replica Pod Delete

Deletes a random replica pod:

```bash
kubectl apply -f experiments/cnpg-replica-pod-delete.yaml
```

Watch the chaos:

```bash
kubectl logs -n default -l app=cnpg-replica-pod-delete-v2 -f
```

## Checking Results

### View experiment results

```bash
kubectl get chaosresult -n default
```

### Check specific result verdict

```bash
kubectl get chaosresult <engine-name>-pod-delete -n default -o jsonpath='{.status.experimentStatus.verdict}'
```

### View detailed experiment logs

```bash
# Get the latest experiment job name
JOB_NAME=$(kubectl get jobs -n default -l name=pod-delete --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')

# View logs
kubectl logs -n default job/$JOB_NAME
```

### Check cluster health

```bash
kubectl get pods -n default -l cnpg.io/cluster=pg-eu
kubectl cnpg status pg-eu
```

## Stopping Experiments

### Stop a running experiment

```bash
kubectl patch chaosengine <engine-name> -n default --type merge -p '{"spec":{"engineState":"stop"}}'
```

### Delete an experiment

```bash
kubectl delete chaosengine <engine-name> -n default
```

## Customization

### Adjust chaos duration

Edit the experiment YAML and modify:

```yaml
env:
  - name: TOTAL_CHAOS_DURATION
    value: "120" # seconds
```

### Change affected pod percentage

```yaml
env:
  - name: PODS_AFFECTED_PERC
    value: "50" # 50% of matching pods
```

### Target different cluster

Update the `applabel` field:

```yaml
appinfo:
  applabel: "cnpg.io/cluster=your-cluster-name"
```

## Troubleshooting

### Experiment not starting

Check the chaos-operator logs:

```bash
kubectl logs -n litmus deployment/chaos-operator-ce --tail=50
```

### Check chaos engine status

```bash
kubectl describe chaosengine <engine-name> -n default
```

### Runner pod not creating

Verify the ChaosExperiment image:

```bash
kubectl get chaosexperiment pod-delete -n default -o jsonpath='{.spec.definition.image}'
```

For kind clusters, ensure the image is loaded:

```bash
kind load docker-image <image-name> --name <cluster-name>
```

## Key Configuration

All experiments use:

- `appkind: "cluster"` - Enables label-based pod discovery
- `applabel: "cnpg.io/cluster=pg-eu,..."` - Kubernetes label selectors
- Empty `TARGET_PODS` - Relies on dynamic label-based targeting

This configuration eliminates the need for hard-coded pod names and works seamlessly across pod restarts and failovers.
