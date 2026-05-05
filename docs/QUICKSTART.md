# Beginner Quickstart — what to do, in order

Open this in one window, your terminal in another, and follow top to bottom. Total time: ~30 min if everything cooperates.

---

## Phase A — Install tools (one-time)

1. **Docker Desktop** → https://www.docker.com/products/docker-desktop/  · start it
2. **minikube** → https://minikube.sigs.k8s.io/docs/start/
3. **kubectl** → https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
4. **Git** → https://git-scm.com/download/win
5. Verify in a terminal:
   ```bash
   docker --version && minikube version && kubectl version --client && git --version
   ```

## Phase B — Accounts

6. GitHub: https://github.com (you = `yash123pc`)
7. Docker Hub: https://hub.docker.com (you = `ykbundela`)
8. Harness Free Tier: https://app.harness.io/auth/#/signup

## Phase C — Credentials

9. **GitHub PAT**: github.com → avatar → *Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new (classic)* → scope `repo` → copy `ghp_...`.
10. **Docker Hub token**: hub.docker.com → avatar → *Account Settings → Personal Access Tokens → Generate new* → permissions *Read & Write* → copy.
11. **Empty GitHub repo**: github.com → `+` → *New repository* → name `harness-demo-app`, owner `yash123pc`, public, **no README/license/.gitignore** → *Create*.

## Phase D — Run the local bootstrap

12. Open Git Bash in this folder (right-click in Explorer → *Git Bash Here*).
13. ```bash
    bash scripts/bootstrap.sh
    ```
    Paste your GitHub PAT when prompted.
14. Look for `"status":"ok"` near the end. That confirms the app + Kubernetes side works.
15. Push the image to Docker Hub so Harness CD can pull it:
    ```bash
    docker login -u ykbundela     # paste Docker Hub token
    SHA=$(git rev-parse --short HEAD)
    docker tag  ykbundela/harness-demo-app:$SHA ykbundela/harness-demo-app:latest
    docker push ykbundela/harness-demo-app:$SHA
    docker push ykbundela/harness-demo-app:latest
    ```

## Phase E — Wire up Harness

16. Sign in at https://app.harness.io. Your **Account ID** is the chunk between `account/` and the next `/` in the URL.
17. **Harness API token**: avatar → *My Profile → My API Keys → + API Key* (name `setup`) → on that key click *+ Token* (name `setup-token`) → *Generate Token* → copy.
18. **Install the Delegate** (only manual click step):
    - Left sidebar → *Project Settings* (create project `Harness Demo` / id `harness_demo_project` if asked).
    - *Delegates → + New Delegate → Kubernetes → Continue*.
    - Name: `local-delegate`. Continue → Verify.
    - Run the `kubectl apply` it shows you. Wait until status = **Connected**.
19. Run:
    ```bash
    bash scripts/harness-setup.sh
    ```
    Pastes (in order): Account ID, Harness API token, GitHub PAT, Docker Hub token.

## Phase F — Run the pipeline

20. Open the URL the script prints at the end.
21. Click **Run** (top right).
    - Branch = `main`
    - `DOCKER_REPO` = `ykbundela/harness-demo-app` (default)
    - *Run Pipeline*.
22. Watch all four stages turn green:
    ```
    CI - Build & Push  →  STO - Security Scan  →  CD - Deploy to K8s  →  Post-deploy validation
    ```
23. See the deployed app:
    ```bash
    kubectl -n harness-demo port-forward svc/harness-demo-app 8080:80
    # open http://localhost:8080/health
    ```

---

## Troubleshooting

| Symptom | What's happening | Fix |
| --- | --- | --- |
| `docker: command not found` | Docker Desktop not running | Open it from Start Menu, wait for whale icon |
| `git push` rejected with 403 | PAT scope wrong / token expired | Regenerate PAT with `repo` scope |
| Pipeline fails on STO with CRITICAL CVE | The security gate is doing its job | This is *correct*. For the demo, either rebuild after a few weeks (CVEs get patched) or bump `fail_on_severity` to `high` temporarily |
| CD stage fails `ImagePullBackOff` | Image isn't on Docker Hub yet | Run step 15 before triggering the pipeline |
| Delegate stays "Not connected" | Still starting | `kubectl get pods -n harness-delegate-ng` — wait until 1/1 Running |
| Post-deploy validation fails | App not ready in time | Re-run; if persistent, check `kubectl -n harness-demo logs deploy/harness-demo-app` |
| `harness-setup.sh` prints HTTP 401 | API token wrong or expired | Regenerate at *My Profile → My API Keys* |

---

## What success looks like (screenshots to capture for submission)

1. Harness pipeline overview with all four stages green.
2. Docker Hub showing `ykbundela/harness-demo-app:<sha>` and `:latest`.
3. `kubectl -n harness-demo get pods,svc` output with 2 Running pods.
4. `curl http://localhost:8080/health` returning `{"status":"ok",...}`.
