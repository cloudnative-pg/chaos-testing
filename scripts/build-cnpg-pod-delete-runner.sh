#!/usr/bin/env bash

# Helper script to build a custom LitmusChaos go-runner image using an
# arbitrary ref from the upstream litmuschaos/litmus-go repository.

set -euo pipefail

if ! command -v git >/dev/null || ! command -v docker >/dev/null; then
  echo "This script requires both git and docker to be installed." >&2
  exit 1
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  cat <<'USAGE' >&2
Usage: ./scripts/build-cnpg-pod-delete-runner.sh <registry>/<image>[:tag] [git-ref]

Example:
  ./scripts/build-cnpg-pod-delete-runner.sh ghcr.io/example/litmus-go-runner-cnpg:master
  ./scripts/build-cnpg-pod-delete-runner.sh ghcr.io/example/litmus-go-runner-cnpg:v0.1.0 v3.11.0

The script:
  1. Clones litmuschaos/litmus-go
  2. Checks out the requested git ref (default: master)
  3. Builds the go-runner image
  4. Pushes it to the registry you specify
USAGE
  exit 1
fi

IMAGE_REF=$1
GIT_REF=${2:-master}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

pushd "$WORKDIR" >/dev/null

git clone https://github.com/litmuschaos/litmus-go.git
cd litmus-go

git checkout "$GIT_REF"

go mod download

docker build -f build/Dockerfile -t "$IMAGE_REF" .
docker push "$IMAGE_REF"

popd >/dev/null

echo "Custom go-runner image pushed: $IMAGE_REF (source ref: $GIT_REF)"
