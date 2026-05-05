#!/usr/bin/env bash
# harness-setup.sh — create everything the pipeline needs in your Harness account
# via the Harness Platform REST API. Idempotent: safe to re-run.
#
# Creates:
#   * Project           : harness_demo_project (in your default org)
#   * Connectors        : github_connector, dockerhub_connector, local_k8s_connector
#   * Secrets           : github_token, dockerhub_username, dockerhub_password
#   * Service / Env / Infra to match .harness/pipeline.yaml
#   * Imports the pipeline from .harness/pipeline.yaml
#   * Imports the PR trigger from .harness/trigger-on-pr.yaml
#
# Required env vars (the script will prompt if missing):
#   HARNESS_ACCOUNT_ID   — copy from app.harness.io URL: app.harness.io/ng/account/<this>/...
#   HARNESS_API_TOKEN    — Personal Access Token, scope: account-admin (Profile -> My API Keys)
#   GITHUB_TOKEN         — PAT with repo scope (used by github_connector)
#   DOCKERHUB_TOKEN      — Docker Hub access token for ykbundela
#
# Optional:
#   HARNESS_ORG_ID       — default: default
#   HARNESS_PROJECT_ID   — default: harness_demo_project
#   GITHUB_USER          — default: yash123pc
#   DOCKERHUB_USER       — default: ykbundela
#   REPO_NAME            — default: harness-demo-app
#   K8S_DELEGATE_NAME    — default: local-delegate

set -euo pipefail

GITHUB_USER="${GITHUB_USER:-yash123pc}"
DOCKERHUB_USER="${DOCKERHUB_USER:-ykbundela}"
REPO_NAME="${REPO_NAME:-harness-demo-app}"
HARNESS_ORG_ID="${HARNESS_ORG_ID:-default}"
HARNESS_PROJECT_ID="${HARNESS_PROJECT_ID:-harness_demo_project}"
HARNESS_PROJECT_NAME="${HARNESS_PROJECT_NAME:-Harness Demo}"
K8S_DELEGATE_NAME="${K8S_DELEGATE_NAME:-local-delegate}"
HARNESS_BASE="${HARNESS_BASE:-https://app.harness.io}"

log()  { printf "\n\033[1;36m== %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }

prompt() {
  local var="$1" desc="$2" silent="${3:-no}"
  if [ -z "${!var:-}" ]; then
    if [ "$silent" = "yes" ]; then
      read -rsp "  ${desc}: " val; echo
    else
      read -rp  "  ${desc}: " val
    fi
    export "$var=$val"
  fi
}

prompt HARNESS_ACCOUNT_ID  "Harness Account ID"
prompt HARNESS_API_TOKEN   "Harness API token (Profile -> My API Keys)" yes
prompt GITHUB_TOKEN        "GitHub PAT (repo scope)"                    yes
prompt DOCKERHUB_TOKEN     "Docker Hub access token (user: $DOCKERHUB_USER)" yes

H="x-api-key: ${HARNESS_API_TOKEN}"
QS="accountIdentifier=${HARNESS_ACCOUNT_ID}&orgIdentifier=${HARNESS_ORG_ID}&projectIdentifier=${HARNESS_PROJECT_ID}"

# helper that PUTs a YAML body to the right endpoint, falling back to POST if it
# doesn't already exist. Endpoints accept YAML when Content-Type is application/yaml.
upsert() {
  local url="$1" body="$2" label="$3"
  local code
  code=$(curl -sS -o /tmp/h-resp.json -w "%{http_code}" \
        -H "$H" -H "Content-Type: application/yaml" \
        -X PUT --data-binary "$body" "$url" || true)
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then ok "$label (updated)"; return; fi

  code=$(curl -sS -o /tmp/h-resp.json -w "%{http_code}" \
        -H "$H" -H "Content-Type: application/yaml" \
        -X POST --data-binary "$body" "${url%/*}" || true)
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then ok "$label (created)"; return; fi

  warn "$label  (HTTP $code)"
  cat /tmp/h-resp.json; echo
}

# -----------------------------------------------------------------------------
log "1/7  Project"
PROJ_BODY=$(cat <<EOF
project:
  orgIdentifier: ${HARNESS_ORG_ID}
  identifier: ${HARNESS_PROJECT_ID}
  name: ${HARNESS_PROJECT_NAME}
  color: "#0063F7"
  modules: [CI, CD, STO]
EOF
)
curl -sS -o /dev/null -H "$H" -H "Content-Type: application/yaml" \
  -X POST --data-binary "$PROJ_BODY" \
  "${HARNESS_BASE}/ng/api/projects?accountIdentifier=${HARNESS_ACCOUNT_ID}&orgIdentifier=${HARNESS_ORG_ID}" \
  && ok "project ensured"

# -----------------------------------------------------------------------------
log "2/7  Secrets"
create_secret() {
  local id="$1" name="$2" value="$3"
  local body
  body=$(cat <<EOF
secret:
  type: SecretText
  name: ${name}
  identifier: ${id}
  orgIdentifier: ${HARNESS_ORG_ID}
  projectIdentifier: ${HARNESS_PROJECT_ID}
  spec:
    secretManagerIdentifier: harnessSecretManager
    valueType: Inline
    value: "${value}"
EOF
)
  upsert "${HARNESS_BASE}/ng/api/v2/secrets/${id}?${QS}" "$body" "secret ${id}"
}
create_secret github_token        "GitHub Token"        "${GITHUB_TOKEN}"
create_secret dockerhub_username  "Docker Hub Username" "${DOCKERHUB_USER}"
create_secret dockerhub_password  "Docker Hub Token"    "${DOCKERHUB_TOKEN}"

# -----------------------------------------------------------------------------
log "3/7  Connectors"
GH_CONN=$(cat <<EOF
connector:
  name: GitHub Connector
  identifier: github_connector
  orgIdentifier: ${HARNESS_ORG_ID}
  projectIdentifier: ${HARNESS_PROJECT_ID}
  type: Github
  spec:
    url: https://github.com/${GITHUB_USER}/${REPO_NAME}
    type: Repo
    authentication:
      type: Http
      spec:
        type: UsernameToken
        spec:
          username: ${GITHUB_USER}
          tokenRef: github_token
    apiAccess:
      type: Token
      spec:
        tokenRef: github_token
    executeOnDelegate: false
EOF
)
upsert "${HARNESS_BASE}/ng/api/connectors/github_connector?${QS}" "$GH_CONN" "github_connector"

DH_CONN=$(cat <<EOF
connector:
  name: Docker Hub
  identifier: dockerhub_connector
  orgIdentifier: ${HARNESS_ORG_ID}
  projectIdentifier: ${HARNESS_PROJECT_ID}
  type: DockerRegistry
  spec:
    dockerRegistryUrl: https://index.docker.io/v2/
    providerType: DockerHub
    auth:
      type: UsernamePassword
      spec:
        username: ${DOCKERHUB_USER}
        passwordRef: dockerhub_password
    executeOnDelegate: false
EOF
)
upsert "${HARNESS_BASE}/ng/api/connectors/dockerhub_connector?${QS}" "$DH_CONN" "dockerhub_connector"

K8S_CONN=$(cat <<EOF
connector:
  name: Local K8s
  identifier: local_k8s_connector
  orgIdentifier: ${HARNESS_ORG_ID}
  projectIdentifier: ${HARNESS_PROJECT_ID}
  type: K8sCluster
  spec:
    credential:
      type: InheritFromDelegate
    delegateSelectors:
      - ${K8S_DELEGATE_NAME}
EOF
)
upsert "${HARNESS_BASE}/ng/api/connectors/local_k8s_connector?${QS}" "$K8S_CONN" "local_k8s_connector"

# -----------------------------------------------------------------------------
log "4/7  Service"
SVC_BODY=$(cat <<EOF
service:
  name: harness-demo-app
  identifier: harness_demo_app_service
  orgIdentifier: ${HARNESS_ORG_ID}
  projectIdentifier: ${HARNESS_PROJECT_ID}
  serviceDefinition:
    type: Kubernetes
    spec:
      manifests:
        - manifest:
            identifier: k8s_manifests
            type: K8sManifest
            spec:
              store:
                type: Github
                spec:
                  connectorRef: github_connector
                  gitFetchType: Branch
                  paths:
                    - k8s
                  branch: main
              valuesPaths: []
              skipResourceVersioning: false
      artifacts:
        primary:
          primaryArtifactRef: dockerhub_image
          sources:
            - identifier: dockerhub_image
              type: DockerRegistry
              spec:
                connectorRef: dockerhub_connector
                imagePath: ${DOCKERHUB_USER}/${REPO_NAME}
                tag: <+input>
EOF
)
upsert "${HARNESS_BASE}/ng/api/servicesV2/harness_demo_app_service?${QS}" "$SVC_BODY" "service"

# -----------------------------------------------------------------------------
log "5/7  Environment + Infrastructure"
ENV_BODY=$(cat <<EOF
environment:
  name: dev
  identifier: dev
  orgIdentifier: ${HARNESS_ORG_ID}
  projectIdentifier: ${HARNESS_PROJECT_ID}
  type: PreProduction
EOF
)
upsert "${HARNESS_BASE}/ng/api/environmentsV2/dev?${QS}" "$ENV_BODY" "environment"

INFRA_BODY=$(cat <<EOF
infrastructureDefinition:
  name: local-k8s
  identifier: local_k8s
  orgIdentifier: ${HARNESS_ORG_ID}
  projectIdentifier: ${HARNESS_PROJECT_ID}
  environmentRef: dev
  deploymentType: Kubernetes
  type: KubernetesDirect
  spec:
    connectorRef: local_k8s_connector
    namespace: harness-demo
    releaseName: release-<+INFRA_KEY_SHORT_ID>
EOF
)
upsert "${HARNESS_BASE}/ng/api/infrastructures/local_k8s?${QS}&environmentIdentifier=dev" \
       "$INFRA_BODY" "infrastructure"

# -----------------------------------------------------------------------------
log "6/7  Import pipeline"
PIPELINE_YAML="$(cat .harness/pipeline.yaml)"
curl -sS -o /tmp/h-resp.json -w "  HTTP %{http_code}\n" \
  -H "$H" -H "Content-Type: application/yaml" \
  -X POST --data-binary "$PIPELINE_YAML" \
  "${HARNESS_BASE}/pipeline/api/pipelines/v2?${QS}" \
  || true
ok "pipeline import attempted (re-import via PUT if it already exists)"

# -----------------------------------------------------------------------------
log "7/7  Import PR trigger"
TRIGGER_YAML="$(cat .harness/trigger-on-pr.yaml)"
curl -sS -o /tmp/h-resp.json -w "  HTTP %{http_code}\n" \
  -H "$H" -H "Content-Type: application/yaml" \
  -X POST --data-binary "$TRIGGER_YAML" \
  "${HARNESS_BASE}/pipeline/api/triggers?${QS}&targetIdentifier=harness_demo_cicd_sto" \
  || true
ok "trigger import attempted"

cat <<EOF

\033[1;32mHarness setup complete.\033[0m

Open the pipeline:
  ${HARNESS_BASE}/ng/account/${HARNESS_ACCOUNT_ID}/cd/orgs/${HARNESS_ORG_ID}/projects/${HARNESS_PROJECT_ID}/pipelines/harness_demo_cicd_sto/pipeline-studio/

Before the first run you still need to install a Delegate named "${K8S_DELEGATE_NAME}"
inside your minikube cluster (one-line install command in the Harness UI under
Project Settings -> Delegates -> New Delegate -> Kubernetes).

Then click "Run".
EOF
