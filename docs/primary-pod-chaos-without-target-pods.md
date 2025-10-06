# Primary Pod Deletion Without `TARGET_PODS`

This document captures the current repository context and describes a repeatable
pattern for deleting the CloudNativePG primary pod via LitmusChaos **without
hard-coding pod names** in the `TARGET_PODS` environment variable.

## Current Context Summary

- **PostgreSQL topology**: The `pg-eu` [`Cluster`](../pg-eu-cluster.yaml)
  resource provisions three instances (one primary and two replicas). Pods are
  ```diff
  --- a/pkg/utils/common/pods.go
  +++ b/pkg/utils/common/pods.go
  @@
  -	case "pod":
  -		if len(target.Names) > 0 {
  -			for _, name := range target.Names {
  -				pod, err := clients.GetPod(target.Namespace, name, chaosDetails.Timeout, chaosDetails.Delay)
  -				if err != nil {
  -					return finalPods, cerrors.Error{ErrorCode: cerrors.ErrorTypeTargetSelection, Target: fmt.Sprintf("{podName: %s, namespace: %s}", name, target.Namespace), Reason: err.Error()}
  -				}
  -				finalPods.Items = append(finalPods.Items, *pod)
  -			}
  -		} else {
  -			return finalPods, cerrors.Error{ErrorCode: cerrors.ErrorTypeTargetSelection, Target: fmt.Sprintf("{podKind: %s, namespace: %s}", target.Kind, target.Namespace), Reason: "no pod names or labels supplied"}
  -		}
  -		podKind = true
  +	case "pod":
  +		if len(target.Names) > 0 {
  +			for _, name := range target.Names {
  +				pod, err := clients.GetPod(target.Namespace, name, chaosDetails.Timeout, chaosDetails.Delay)
  +				if err != nil {
  +					return finalPods, cerrors.Error{ErrorCode: cerrors.ErrorTypeTargetSelection, Target: fmt.Sprintf("{podName: %s, namespace: %s}", name, target.Namespace), Reason: err.Error()}
  +				}
  +				finalPods.Items = append(finalPods.Items, *pod)
  +			}
  +		} else if len(target.Labels) > 0 {
  +			for _, label := range target.Labels {
  +				pods, err := FilterNonChaosPods(target.Namespace, label, clients, chaosDetails)
  +				if err != nil {
  +					return finalPods, stacktrace.Propagate(err, "could not fetch pods for label selector")
  +				}
  +				finalPods.Items = append(finalPods.Items, pods.Items...)
  +			}
  +		} else {
  +			return finalPods, cerrors.Error{ErrorCode: cerrors.ErrorTypeTargetSelection, Target: fmt.Sprintf("{podKind: %s, namespace: %s}", target.Kind, target.Namespace), Reason: "no pod names or labels supplied"}
  +		}
  +		podKind = true

- Fetches the active list of pods that match `cnpg.io/instanceRole=primary` at

  The important addition is the new label-aware branch inside `case "pod"`,
  which reuses `FilterNonChaosPods` to expand any selectors provided via `APP_LABEL`.
  runtime.
- Injects chaos against whichever pod currently owns the primary role.
- Continues to honour Litmus tunables (duration, interval, sequence, probes).

No static pod names are stored in Git, and the experiment keeps working across
failovers because the label always migrates to the new primary.

## Implementation Details

### 1. Patch `litmus-go`

Create a patch file (for example, `patches/litmus-go-pod-kind.patch`) with the
following diff:

```diff
--- a/pkg/utils/common/pods.go
+++ b/pkg/utils/common/pods.go
@@
-func GetPodList(appNs, appLabel, appKind, targetPods string, clients clients.ClientSets) (*corev1.PodList, error) {
+func GetPodList(appNs, appLabel, appKind, targetPods string, clients clients.ClientSets) (*corev1.PodList, error) {
+    // Allow CloudNativePG and other custom operators to be targeted purely via labels.
+    if appKind == "" || strings.EqualFold(appKind, "pod") {
+        if appLabel == "" {
+            return nil, errors.Errorf("no applabel provided for APP_KIND=pod")
+        }
+
+        pods, err := clients.KubeClient.CoreV1().Pods(appNs).List(context.Background(), metav1.ListOptions{
+            LabelSelector: appLabel,
+        })
+        if err != nil {
+            return nil, err
+        }
+        if len(pods.Items) == 0 {
+            return nil, errors.Errorf("no pods found for label %s in namespace %s", appLabel, appNs)
+        }
+        return pods, nil
+    }
@@
-    if targetPods == "" {
-        return nil, errors.Errorf("no target pods found")
-    }
+    if targetPods == "" {
+        return nil, errors.Errorf("no target pods found")
+    }
```

The important piece is the early return: when `APP_KIND` is `pod` (or an empty
string), the helper lists pods directly based on the supplied label selector.

### 2. Build & Push a Custom Runner Image

A simple helper script (see [`scripts/build-cnpg-pod-delete-runner.sh`](../scripts/build-cnpg-pod-delete-runner.sh))
automates the following steps:

```bash
#!/usr/bin/env bash
set -euo pipefail

REGISTRY=${REGISTRY:-ghcr.io/<your-account>}
TAG=${TAG:-cnpg-pod-delete}
VERSION=${VERSION:-v0.1.0}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

git clone https://github.com/litmuschaos/litmus-go.git "$workdir/litmus-go"
cd "$workdir/litmus-go"

git checkout 3.10.0
patch -p1 < /path/to/patches/litmus-go-pod-kind.patch
gofmt -w pkg/utils/common/pods.go

go mod tidy

go test ./...

docker build -t "$REGISTRY/$TAG:$VERSION" .
docker push "$REGISTRY/$TAG:$VERSION"
```

> ⚠️ Adjust the registry/credentials as required. Any container registry that
> your Kubernetes cluster can pull from will work.

### 3. Override the `ChaosExperiment`

Add a Kubernetes manifest (`chaosexperiments/pod-delete-cnpg.yaml`) with the
custom image reference. Apply it after installing Litmus:

```bash
kubectl apply -f chaosexperiments/pod-delete-cnpg.yaml
```

This replaces the default `pod-delete` experiment in the `default` namespace.
All existing chaos engines that reference `pod-delete` now use the patched
binary transparently.

### 4. Update the Chaos Engine

The repository already sets `appkind: "pod"` in
[`experiments/cnpg-primary-pod-delete.yaml`](../experiments/cnpg-primary-pod-delete.yaml).
Once the custom experiment image is in place, the primary chaos workflow works
without any explicit pod name lists.

## Validation Checklist

1. Apply the patched `ChaosExperiment` manifest.
2. Deploy or restart the `cnpg-primary-pod-delete` chaos engine.
3. Observe the experiment job logs:
   - The runner should log the matched target via the label selector.
   - The primary pod should be terminated and failover should occur.
4. Verify `kubectl cnpg status pg-eu` reports a healthy cluster afterwards.
5. Inspect `kubectl get chaosresults` to confirm the verdict is `Pass`.

## Next Steps

- Port the same logic to the replica/random chaos definitions so that they no
  longer need `TARGET_PODS`.
- Upstream the helper change to LitmusChaos so that future releases include the
  label-based fallback out-of-the-box.
- Extend the script to support multiple label selectors (e.g. cluster + role).

```
This approach keeps the chaos configuration declarative, dynamic, and resilient
across automatic failovers—exactly what we want for exercising CloudNativePG in
production-like scenarios.
