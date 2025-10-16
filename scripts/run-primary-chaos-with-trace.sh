#!/usr/bin/env bash

# Run the primary pod-delete chaos experiment and capture
# both the experiment logs and the CloudNativePG pod roles.

set -euo pipefail

NAMESPACE=${NAMESPACE:-default}
CLUSTER_LABEL=${CLUSTER_LABEL:-pg-eu}
ENGINE_MANIFEST=${ENGINE_MANIFEST:-experiments/cnpg-primary-pod-delete.yaml}
ENGINE_NAME=${ENGINE_NAME:-cnpg-primary-pod-delete}
LOG_DIR=${LOG_DIR:-logs}
ROLE_INTERVAL=${ROLE_INTERVAL:-10}

mkdir -p "$LOG_DIR"
RUN_ID=$(date +%Y%m%d-%H%M%S)
START_TS=$(date +%s)
LOG_FILE="$LOG_DIR/primary-chaos-$RUN_ID.log"

log() {
  printf '%s %b\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$LOG_FILE"
}

log_block() {
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    fi
    log "  $line"
  done <<< "$1"
}

log "Starting primary chaos run (log: $LOG_FILE)"

log "Deleting existing chaos engine: $ENGINE_NAME"
kubectl delete chaosengine "$ENGINE_NAME" -n "$NAMESPACE" --ignore-not-found

log "Applying chaos engine manifest: $ENGINE_MANIFEST"
kubectl apply -f "$ENGINE_MANIFEST"

log "Waiting for experiment job to appear"
JOB_NAME=""
for _ in {1..90}; do
  mapfile -t JOB_LINES < <(kubectl get jobs -n "$NAMESPACE" -l name=pod-delete \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp},{.metadata.name}{"\n"}{end}')
  for line in "${JOB_LINES[@]}"; do
    ts="${line%,*}"
    name="${line#*,}"
    if [[ -z "$ts" || -z "$name" ]]; then
      continue
    fi
    job_epoch=$(date -d "$ts" +%s)
    if (( job_epoch >= START_TS )); then
      JOB_NAME="$name"
      break 2
    fi
  done
  sleep 2
done

if [[ -z "$JOB_NAME" ]]; then
  log "ERROR: Timed out waiting for pod-delete job"
  exit 1
fi

log "Detected job: $JOB_NAME"
log "Ensuring pod logs are ready before streaming"
for _ in {1..30}; do
  if kubectl logs -n "$NAMESPACE" job/"$JOB_NAME" --tail=1 >/dev/null 2>&1; then
    break
  fi
  log "Job pod not ready for logs yet, retrying in 5s"
  sleep 5
done

log "Streaming experiment logs"
kubectl logs -n "$NAMESPACE" job/"$JOB_NAME" -f | tee -a "$LOG_FILE" &
LOG_PID=$!

log "Recording pod role snapshots every ${ROLE_INTERVAL}s"
while true; do
  COMPLETION=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.completionTime}' 2>/dev/null || true)
  SNAPSHOT=$(kubectl get pods -n "$NAMESPACE" -l cnpg.io/cluster="$CLUSTER_LABEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.cnpg\.io/instanceRole}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].restartCount}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}')
  log "Current CNPG pod roles:"
  log $'  NAME\tROLE\tSTATUS\tRESTARTS\tCREATED'
  log_block "$SNAPSHOT"
  if [[ -n "$COMPLETION" ]]; then
    log "Job reports completion at $COMPLETION"
    break
  fi
  sleep "$ROLE_INTERVAL"
done

log "Waiting for log streamer (pid $LOG_PID) to finish"
wait "$LOG_PID" || true

log "Primary chaos run finished. Log captured at $LOG_FILE"
