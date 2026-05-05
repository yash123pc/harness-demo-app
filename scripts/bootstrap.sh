#!/usr/bin/env bash
# bootstrap.sh — one-shot local setup for the Harness CI/CD + STO assignment.
#
#   * git init + first commit + push to github.com/yash123pc/harness-demo-app
#   * start minikube
#   * build the image, load it into minikube
#   * apply k8s manifests
#   * port-forward and curl /health to validate
#
# Run from the project root:
#   bash scripts/bootstrap.sh
#
# Required env vars (or you'll be prompted):
#   GITHUB_TOKEN   — PAT with `repo` scope, used for `git push` over HTTPS
#
# Optional:
#   GITHUB_USER    — defaults to yash123pc
#   DOCKERHUB_USER — defaults to ykbundela
#   REPO_NAME      — defaults to harness-demo-app
#   IMAGE_TAG      — defaults to short git SHA (or "dev" if none)

set -euo pipefail

GITHUB_USER="${GITHUB_USER:-yash123pc}"
DOCKERHUB_USER="${DOCKERHUB_USER:-ykbundela}"
REPO_NAME="${REPO_NAME:-harness-demo-app}"
NS="harness-demo"

log()  { printf "\n\033[1;36m== %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }

require() { command -v "$1" >/dev/null || { warn "missing tool: $1"; exit 1; }; }

require git
require docker
require kubectl
require minikube
require curl

# -----------------------------------------------------------------------------
# 1) Initialize git repo and push to GitHub
# -----------------------------------------------------------------------------
log "Step 1/5  Initialise git + push to GitHub (yash123pc/${REPO_NAME})"

if [ ! -d .git ]; then
  git init -q
  git branch -M main
fi

git add .
if ! git diff --cached --quiet; then
  git -c user.name="${GITHUB_USER}" -c user.email="${GITHUB_USER}@users.noreply.github.com" \
      commit -q -m "Initial: Harness CI/CD + STO assignment"
else
  echo "  (nothing to commit)"
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  read -rsp "  Enter a GitHub PAT (scope: repo) for ${GITHUB_USER}: " GITHUB_TOKEN
  echo
fi

# Push using token-in-URL (one-shot; not stored)
PUSH_URL="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git"
if ! git push "${PUSH_URL}" main 2>&1 | sed "s|${GITHUB_TOKEN}|***|g"; then
  warn "git push failed. Make sure the repo github.com/${GITHUB_USER}/${REPO_NAME} exists (create it empty on github.com first)."
  exit 1
fi
echo "  pushed ✓"

# -----------------------------------------------------------------------------
# 2) Start minikube
# -----------------------------------------------------------------------------
log "Step 2/5  Start minikube"
if ! minikube status >/dev/null 2>&1; then
  minikube start --driver=docker
else
  echo "  minikube already running ✓"
fi
kubectl config use-context minikube >/dev/null

# -----------------------------------------------------------------------------
# 3) Build the image and load it into minikube
# -----------------------------------------------------------------------------
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
IMAGE_TAG="${IMAGE_TAG:-$SHA}"
LOCAL_IMAGE="${DOCKERHUB_USER}/${REPO_NAME}:${IMAGE_TAG}"

log "Step 3/5  Build image  (${LOCAL_IMAGE})"
docker build \
  --build-arg APP_VERSION="${IMAGE_TAG}" \
  --build-arg BUILD_SHA="${SHA}" \
  -t "${LOCAL_IMAGE}" .

log "Step 3b   Load image into minikube"
minikube image load "${LOCAL_IMAGE}"

# -----------------------------------------------------------------------------
# 4) Apply Kubernetes manifests
# -----------------------------------------------------------------------------
log "Step 4/5  Apply K8s manifests"
kubectl apply -f k8s/namespace.yaml
sed "s|<+pipeline.variables.DOCKER_REPO>:<+pipeline.variables.IMAGE_TAG>|${LOCAL_IMAGE}|g" k8s/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/service.yaml

echo "  waiting for rollout..."
kubectl -n "${NS}" rollout status deploy/harness-demo-app --timeout=120s

kubectl -n "${NS}" get pods,svc

# -----------------------------------------------------------------------------
# 5) Validate /health
# -----------------------------------------------------------------------------
log "Step 5/5  Validate /health"

LOCAL_PORT=18080
kubectl -n "${NS}" port-forward svc/harness-demo-app "${LOCAL_PORT}:80" >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT

for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  if curl -fsS "http://127.0.0.1:${LOCAL_PORT}/health" 2>/dev/null; then
    echo
    echo
    echo "  /health OK ✓"
    break
  fi
  echo "  waiting for app ($i/10)..."
done

cat <<EOF

\033[1;32mAll done.\033[0m

Next:
  * Push image to Docker Hub manually if you want Harness CI to pull it:
      docker login -u ${DOCKERHUB_USER}
      docker tag ${LOCAL_IMAGE} ${DOCKERHUB_USER}/${REPO_NAME}:latest
      docker push ${LOCAL_IMAGE}
      docker push ${DOCKERHUB_USER}/${REPO_NAME}:latest
  * Run scripts/harness-setup.sh to wire up Harness via API (no clicking).
  * Browse to the app:
      kubectl -n ${NS} port-forward svc/harness-demo-app 8080:80
      open http://localhost:8080/health
EOF
