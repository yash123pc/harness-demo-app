#!/usr/bin/env bash
# Deploys the manifests in k8s/ to the active kubectl context.
# Substitutes the Harness artifact-image token with the image you pass in.
#
# Usage:
#   ./scripts/deploy-local.sh docker.io/<your-user>/harness-demo-app:<tag>
set -euo pipefail

IMAGE="${1:?Usage: $0 <full-image-ref>}"

echo ">> Applying namespace"
kubectl apply -f k8s/namespace.yaml

echo ">> Rendering deployment with image=${IMAGE}"
sed "s|ykbundela/harness-demo-app:latest|${IMAGE}|g" k8s/deployment.yaml | kubectl apply -f -

echo ">> Applying service"
kubectl apply -f k8s/service.yaml

echo ">> Waiting for rollout..."
kubectl -n harness-demo rollout status deploy/harness-demo-app --timeout=120s

echo ">> Pods:"
kubectl -n harness-demo get pods -o wide

echo
echo "Reach the app via:"
echo "  kubectl -n harness-demo port-forward svc/harness-demo-app 8080:80"
echo "  curl http://localhost:8080/health"
