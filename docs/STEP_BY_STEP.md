# Step-by-step setup guide

This is the long-form companion to the README. Follow it once, top to bottom, and you'll have a working Harness pipeline running CI/CD + STO against a local Kubernetes cluster.

---

## 0. What you need installed

- Docker Desktop (or Docker Engine on Linux)
- One local Kubernetes option:
  - `minikube` (`brew install minikube`) — easiest
  - or `kind` (`brew install kind`)
- `kubectl` matching your cluster
- `git` + a GitHub account
- A Docker Hub account (free)
- A Harness Free Tier account → https://app.harness.io/

---

## 1. Push this code to GitHub

```bash
cd Harness_HandsOn
git init
git add .
git commit -m "Initial: Harness CI/CD + STO assignment"
git branch -M main
git remote add origin git@github.com:<your-user>/harness-demo-app.git
git push -u origin main
```

---

## 2. Smoke test locally (catch problems before involving Harness)

```bash
# Build + run
./scripts/local-run.sh
# In another terminal:
curl -s http://localhost:8080/health | jq .
# Expect: {"status":"ok","app":"harness-demo-app", ...}
```

Stop the container with Ctrl-C.

---

## 3. Spin up a local Kubernetes cluster

### Option A — minikube
```bash
minikube start --driver=docker
kubectl get nodes   # should show 1 Ready node
```

### Option B — kind
```bash
kind create cluster --name harness-demo
kubectl get nodes
```

---

## 4. Deploy manually (sanity check before adding Harness)

```bash
docker build -t harness-demo-app:dev .

# minikube:
minikube image load harness-demo-app:dev
# kind:
# kind load docker-image harness-demo-app:dev --name harness-demo

./scripts/deploy-local.sh harness-demo-app:dev
./scripts/validate-health.sh
```

If `/health` returns `{"status":"ok",...}`, the application + manifests + cluster are all good. Time to bring Harness into the picture.

---

## 5. Install a Harness Delegate inside your cluster

The Delegate is a small pod that lets Harness reach private things (your local cluster, your registries, etc.) without exposing them to the public internet.

In the Harness UI:

1. *Project Settings → Delegates → New Delegate*
2. Pick **Kubernetes**, name it `local-delegate`.
3. Copy the `kubectl apply` (or Helm) install command and run it against your local cluster.
4. Wait for the Delegate to show up as **Connected**.

```bash
kubectl get pods -n harness-delegate-ng
# harness-delegate-ng-xxx    1/1     Running
```

---

## 6. Create connectors

In *Project Settings → Connectors*:

| Connector | Type | Notes |
| --- | --- | --- |
| `github_connector` | GitHub | PAT with `repo` scope |
| `dockerhub_connector` | Docker Registry | Docker Hub URL, username + access token (NOT password) |
| `local_k8s_connector` | Kubernetes Cluster | Use the Delegate from step 5 |

Test each connection — it should go green.

---

## 7. Create secrets

In *Project Settings → Secrets*:

- `dockerhub_username` → text secret, your Docker Hub username
- `dockerhub_password` → text secret, your Docker Hub access token

These are referenced by the STO step as `<+secrets.getValue("...")>`.

---

## 8. Create the Service, Environment, Infrastructure

These are CD building blocks Harness expects in the new pipeline model.

1. **Service**
   - *Services → New Service* → name `harness-demo-app`, identifier `harness_demo_app_service`
   - Type: **Kubernetes**
   - Manifest: point to your repo, path `k8s/` (use `github_connector`)
   - Artifact: Docker Registry → `dockerhub_connector`, image path `<your-user>/harness-demo-app`, tag = runtime input
2. **Environment**
   - *Environments → New Environment* → name `dev`, type **Pre-Production**
3. **Infrastructure** (under the `dev` environment)
   - Type: **Kubernetes Direct**
   - Connector: `local_k8s_connector`
   - Namespace: `harness-demo`
   - Identifier: `local_k8s`

---

## 9. Import the pipeline

1. *Pipelines → New Pipeline → Import From Git*
2. Connector: `github_connector`, branch `main`, file `.harness/pipeline.yaml`.
3. Save.

If Harness reports identifier mismatches, open the YAML editor and either:
- adjust `serviceRef`, `environmentRef`, `infrastructureDefinitions[].identifier` to match what you created in step 8, OR
- rename the entities you created in step 8 to match the YAML.

---

## 10. Run the pipeline

*Pipelines → harness-demo-cicd-sto → Run*.

Provide the runtime inputs:
- `DOCKER_REPO` → `<your-dockerhub-user>/harness-demo-app`
- Codebase build → `Branch: main`

You should see four stages execute in order:

```
CI - Build & Push      ✅
STO - Security Scan    ✅   (or ❌ on CRITICAL CVE — that's the gate doing its job)
CD - Deploy to K8s     ✅
Post-deploy validation ✅
```

After success:
```bash
kubectl -n harness-demo get pods,svc
# minikube:
minikube service -n harness-demo harness-demo-app --url
# or just port-forward:
kubectl -n harness-demo port-forward svc/harness-demo-app 8080:80
curl http://localhost:8080/health
```

---

## 11. (Bonus) Enable PR-triggered scanning

1. *Triggers → New Trigger → Import From Git → `.harness/trigger-on-pr.yaml`*.
2. Set the GitHub webhook URL Harness gives you on the repo (Settings → Webhooks → Add).
3. Open a PR — the pipeline runs against the PR head, STO scans the resulting image, and the merge button is gated on the scan result via GitHub's required-status-checks.

---

## 12. (Bonus) Force the security gate to trip

Add a known-vulnerable base for one run to prove the gate works:

```Dockerfile
# (don't merge this — just for the demo)
FROM python:3.9-slim AS runtime
```

Older base images carry more known CVEs. Push, watch the STO stage fail, then revert.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Delegate stays "Not connected" | Cluster can't reach Harness SaaS | Check egress; some corp networks block it |
| `ImagePullBackOff` in CD | Image private, no pull secret | Make repo public, or add `imagePullSecrets` on the SA |
| Post-deploy validation fails with `connection refused` | App not ready in time | Increase `startupProbe.failureThreshold` or `validate-health.sh` retries |
| Trivy step times out | Trivy DB download slow | Re-run; the runner caches it after first download |
| Pipeline can't find manifests | Service manifest path mismatch | In the Service YAML, set `manifests[].spec.paths` to `k8s/` |
