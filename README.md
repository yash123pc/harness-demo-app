# Harness CI/CD + STO — Hands-On Assignment

End-to-end CI/CD pipeline with integrated security testing (STO) using **Harness Free Tier** and a **local Kubernetes cluster** (minikube/kind).

The deliverable is a tiny Python Flask service that exposes `/health`, packaged as a Docker image, scanned for CVEs, and rolled out to Kubernetes — with a security gate that **fails the pipeline on any CRITICAL vulnerability**.

---

## Repository layout

```
.
├── app/                    # Python Flask application
│   ├── app.py              # / , /health , /version
│   ├── requirements.txt
│   └── test_app.py         # pytest smoke tests run in CI
├── Dockerfile              # multi-stage, non-root, slim runtime
├── .dockerignore
├── k8s/                    # Kubernetes manifests
│   ├── namespace.yaml
│   ├── deployment.yaml     # rolling strategy, probes, resource limits
│   └── service.yaml        # NodePort :30080
├── .harness/
│   ├── pipeline.yaml       # CI -> STO -> CD -> Validate
│   └── trigger-on-pr.yaml  # bonus: shift-left trigger on every PR
├── scripts/
│   ├── local-run.sh        # build + run the image locally
│   ├── deploy-local.sh     # apply manifests to your kubectl context
│   └── validate-health.sh  # mirrors the post-deploy validation step
├── docs/
│   ├── STEP_BY_STEP.md     # detailed setup walkthrough
│   └── INTERVIEW.md        # talking points for the live demo
└── README.md               # this file
```

---

## Quickstart (local, no Harness)

```bash
# 1. Build and run the image
./scripts/local-run.sh
curl http://localhost:8080/health
# => {"status":"ok", ...}

# 2. Deploy to a local cluster (minikube / kind)
minikube start                 # or: kind create cluster
docker build -t harness-demo-app:dev .
minikube image load harness-demo-app:dev   # for kind: kind load docker-image ...
./scripts/deploy-local.sh harness-demo-app:dev

# 3. Validate
./scripts/validate-health.sh
```

---

## Pipeline architecture

```
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────────┐
│  CI - Build/Push │ -> │  STO - Trivy +   │ -> │  CD - Rolling    │ -> │ Post-deploy validate │
│                  │    │  Bandit (gate)   │    │  deploy to K8s   │    │ curl /health, assert │
└──────────────────┘    └──────────────────┘    └──────────────────┘    └──────────────────────┘
   pytest                fail on CRITICAL          K8sRollingDeploy        port-forward + curl
   docker build/push     CVEs (mandatory)          rollback on failure     retries with backoff
```

Each stage is defined in `.harness/pipeline.yaml`:

1. **CI - Build & Push** — runs `pytest`, builds the image with `BuildAndPushDockerRegistry`, tags it with the short commit SHA + `latest`, pushes to Docker Hub.
2. **STO - Security Scan** — `AquaTrivy` step does a **container scan** with `fail_on_severity: critical`, plus a bonus **Bandit SAST** scan on the Python source. Either CRITICAL hit fails the pipeline before deployment.
3. **CD - Deploy to K8s** — `K8sRollingDeploy` applies `k8s/` against the configured infrastructure. `maxUnavailable: 0`, `maxSurge: 1` for zero-downtime. Stage failure triggers `K8sRollingRollback`.
4. **Post-deploy validation** — port-forwards `svc/harness-demo-app` and curls `/health` with retry/backoff, asserting `"status":"ok"` in the response. Failure here also rolls back.

### Why a security gate matters
Container scanning catches known CVEs in OS packages and Python dependencies. By gating on **CRITICAL**, we let the team move fast on Lows/Mediums (with tickets) but block anything actively dangerous from reaching production. SAST (Bandit) catches dangerous Python idioms before the image is even built.

---

## Security gating — how it actually works

In `.harness/pipeline.yaml`:

```yaml
- step:
    type: AquaTrivy
    spec:
      target: { type: container, name: <DOCKER_REPO>, variant: <TAG> }
      advanced:
        fail_on_severity: critical    # <-- the mandatory gate
```

`fail_on_severity: critical` tells the Harness STO step to exit non-zero (and fail the stage, and therefore the pipeline) if Trivy reports any CRITICAL findings on the image we just pushed.

The CD stage only starts after STO is green, so a vulnerable image **never reaches** Kubernetes.

If you want to *also* fail on `high`, change the value to `high` (severities are inclusive — `high` blocks both High and Critical).

---

## Setup instructions (Harness side)

> Detailed walkthrough with screenshots in [`docs/STEP_BY_STEP.md`](docs/STEP_BY_STEP.md).

Prereqs:

- [Harness Free Tier](https://app.harness.io/) account
- Docker Hub account + access token
- `kubectl` pointing at a local cluster (minikube / kind / k3d)
- A Harness Delegate running locally so it can reach your cluster

In Harness:

1. **Create connectors**
   - `github_connector` — your GitHub PAT, points at the repo
   - `dockerhub_connector` — Docker Hub username + access token
2. **Create secrets** (Project-level, never hardcoded)
   - `dockerhub_username`, `dockerhub_password`
   - `kubeconfig` (or use a Delegate-based K8s connector instead)
3. **Install a Delegate** (one-line Helm/kubectl install) into the same cluster you'll deploy to.
4. **Create a K8s Connector + Infrastructure Definition** that uses the Delegate.
5. **Service**: create `harness_demo_app_service` (Kubernetes), point it at `k8s/` manifests in this repo.
6. **Environment**: `dev` (Pre-Production), with infrastructure `local_k8s` using the K8s connector above.
7. **Import the pipeline**: in your Project, *Pipelines → Import From Git → `.harness/pipeline.yaml`*.
8. **Run it.** First execution will need the `DOCKER_REPO` runtime input; subsequent runs reuse it.

To enable shift-left scanning on PRs, also import `.harness/trigger-on-pr.yaml` as a webhook trigger.

---

## Requirements covered

| Requirement | Where |
| --- | --- |
| HTTP endpoint `/health` | `app/app.py` |
| Dockerfile | `Dockerfile` (multi-stage, non-root, slim) |
| Build + tag with commit SHA + push | CI stage `BuildAndPushDockerRegistry` |
| Container scan | STO stage `AquaTrivy` |
| **Fail on CRITICAL** | `fail_on_severity: critical` |
| K8s manifests | `k8s/deployment.yaml`, `k8s/service.yaml` |
| **Rolling deployment** | `strategy.type: RollingUpdate` + `K8sRollingDeploy` |
| Accessible via NodePort | `service.yaml` `type: NodePort, nodePort: 30080` |
| Post-deploy validation | Stage 4 — `curl /health`, assert `status=ok` |
| Bonus: SAST | STO stage `Bandit` step |
| Bonus: shift-left on PR | `.harness/trigger-on-pr.yaml` |
| Bonus: parameterised pipeline | `pipeline.variables` (`DOCKER_REPO`, `IMAGE_TAG`, `K8S_NAMESPACE`) |
| Bonus: secrets management | `<+secrets.getValue(...)>` — nothing hardcoded |
| Bonus: rollback on failure | `K8sRollingRollback` rollback step + `StageRollback` failure strategy |
| Bonus: retry/backoff | Validation step retries `/health` 10× with backoff |

---

## Assumptions & trade-offs

- **Local k8s** (minikube/kind) is reached through a **Harness Delegate** running inside that same cluster. This avoids exposing your kubeconfig over the public internet. If you don't want a Delegate, you can use a Harness K8s connector with an inline kubeconfig stored as a secret — works the same, just less elegant.
- **Docker Hub public repo** is used so no auth is needed for pulling. For private registries, configure `imagePullSecrets` on the Service Account or in the Service definition.
- **Trivy DB**: the Harness AquaTrivy step downloads the Trivy DB at scan time. First run is slower; subsequent runs are cached on the runner.
- **NodePort** is the simplest way to surface a service on minikube/kind. In a real cluster I'd put an Ingress in front (nginx/traefik) and run cert-manager for TLS.
- Image is tagged with both the **short commit SHA** (immutable, traceable) and `latest` (handy for humans). Production deploys should always reference the SHA tag, never `latest`.
- The Bandit SAST step technically belongs to a CI stage (it scans source code, not the image). I've kept it in the STO stage for narrative clarity — STO is "everything security" — but you could move it into CI as a parallel step to the unit tests for slightly faster feedback.

---

## Submission checklist

- [x] Application code (`app/`)
- [x] Kubernetes manifests (`k8s/`)
- [x] Dockerfile + helper scripts
- [x] Harness pipeline YAML (`.harness/pipeline.yaml`)
- [x] PR trigger YAML (bonus, `.harness/trigger-on-pr.yaml`)
- [x] README (this file)
- [x] Step-by-step setup guide (`docs/STEP_BY_STEP.md`)
- [x] Interview talking points (`docs/INTERVIEW.md`)
