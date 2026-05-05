#!/usr/bin/env bash
# Build the image locally and run it on http://localhost:8080
# Useful for sanity-checking before pushing to the registry / CI.
set -euo pipefail

IMAGE="${IMAGE:-harness-demo-app:dev}"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo local)"

docker build \
  --build-arg APP_VERSION="${SHA}" \
  --build-arg BUILD_SHA="${SHA}" \
  -t "${IMAGE}" .

docker run --rm -it \
  -p 8080:8080 \
  -e APP_NAME=harness-demo-app \
  "${IMAGE}"
