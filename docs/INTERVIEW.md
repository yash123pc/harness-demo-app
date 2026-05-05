# Interview talking points

Use this as your script for the live walkthrough (Round 3). It's organised the way the interviewer is likely to probe: high level → each stage → security gate → trade-offs → "what would you do next."

---

## 30-second pitch

> "I built a four-stage Harness pipeline for a small Python service. **CI** runs unit tests, builds a multi-stage Docker image, tags it with the commit SHA, and pushes to Docker Hub. **STO** runs a Trivy container scan and Bandit SAST, with a hard gate that fails the pipeline on any CRITICAL vulnerability — so vulnerable images never reach the cluster. **CD** does a rolling deploy to local Kubernetes through a Harness Delegate, with automatic rollback on failure. **Post-deploy validation** port-forwards into the cluster and curls `/health` with retries to confirm the new version is actually serving traffic. Secrets are pulled from the Harness Secret Manager — nothing is hardcoded."

---

## Why this design

1. **Fail fast, fail cheap.** Unit tests run before the image is even built. SAST and image scan run before the image is deployed. The cheapest checks gate the most expensive operations.
2. **One artifact, one identity.** The image is built **once** in CI, then promoted by tag through STO and CD. Every downstream stage refers to that exact tag (`<+pipeline.variables.IMAGE_TAG>`), so what you scan is what you ship.
3. **Defense in depth.** Container scan (Trivy) catches CVEs in OS packages and Python deps. SAST (Bandit) catches dangerous code patterns the scanner can't see. Non-root user + read-only rootfs + dropped capabilities in the Pod spec limit blast radius if something does slip through.
4. **Rollback is automatic.** Both CD and post-deploy validation use `StageRollback` on failure. If `/health` doesn't come back green, the previous ReplicaSet is restored — no human in the loop required.

---

## Walking each stage

### CI — Build & Push

- `Run` step → `pytest`. Cheap; fails in seconds if I broke something obvious.
- `BuildAndPushDockerRegistry` → builds with `--build-arg APP_VERSION=<sha> BUILD_SHA=<sha>` so the running container can report its version through `/version` and `/health`. Tags both `<sha>` (immutable, the one CD will deploy) and `latest` (convenience).

**Possible interviewer probes**
- *Why two tags?* SHA tag is immutable, traceable, and what production should ever reference. `latest` is for humans poking at the registry.
- *Why a multi-stage Dockerfile?* Builder has pip/build tools, runtime doesn't. Smaller image → smaller attack surface for Trivy → faster scans → faster deploys.

### STO — Security Scan

- `AquaTrivy` step in `orchestration` mode against the image we just pushed.
- `fail_on_severity: critical` is the **mandatory gate** from the spec.
- `Bandit` step on the source — bonus SAST for Python.

**Probes**
- *What does "fail on critical" actually do?* Trivy outputs findings with severity levels (LOW/MEDIUM/HIGH/CRITICAL). The Harness step exits non-zero when any finding ≥ the threshold exists, which fails the stage, which fails the pipeline.
- *Could you make it stricter?* Yes — set `fail_on_severity: high` to also block Highs. Trade-off: more noise, more CVE-chasing churn. I'd start at CRITICAL and ratchet down once the team is comfortable.
- *What about exceptions/allowlists?* Trivy supports `.trivyignore` for accepting known-but-unfixable CVEs. In Harness STO, you can also add findings to an exemption list with an expiry date — better than a static ignore file because it forces re-review.

### CD — Deploy to K8s

- `K8sRollingDeploy` applies `k8s/` to namespace `harness-demo`.
- Deployment uses `maxSurge: 1, maxUnavailable: 0` → zero downtime: bring the new pod up, wait for readiness, then tear an old one down.
- Probes: `startupProbe` for slow boots, `readinessProbe` to gate Service traffic, `livenessProbe` to restart wedged pods. All hit `/health`.
- Pod hardening: `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: [ALL]` capabilities, `RuntimeDefault` seccomp.

**Probes**
- *Rolling vs blue/green vs canary?* For a single-service demo, rolling is the right default. Blue/green doubles cost during the deploy and needs traffic switching. Canary is great when you have metrics-based gates — Harness supports it natively (`K8sCanaryDeploy`) but it'd be overkill here. Easy to swap in later.
- *What if the new pods crash-loop?* Readiness probe fails → Service never sends traffic to them → old pods keep serving. After a timeout the rollout fails, our `K8sRollingRollback` step runs, and the Deployment goes back to the last good ReplicaSet.

### Post-deploy validation

- `ShellScript` step on the Delegate.
- `kubectl port-forward` instead of relying on NodePort being externally reachable from the runner — works the same on minikube and kind.
- 10× retries with 3s backoff so we don't false-fail on a slow first request.
- Asserts `"status":"ok"` is present in the JSON, not just HTTP 200 — catches "the wrong app is responding" bugs.

**Probes**
- *Why not just rely on readiness probes?* Readiness probes prove a pod thinks it's healthy. Post-deploy validation proves the Service is actually reachable end-to-end with our new image. They check different things.
- *What would a richer validation look like?* In a real service: synthetic transactions (login → core flow → logout), SLO checks against the previous N minutes of metrics, a `kubectl rollout status` followed by a real HTTP probe through the Ingress.

---

## Security gate — deep dive

> "The pipeline can never deploy an image with a known CRITICAL vulnerability."

How that's enforced, concretely:

1. CI pushes `<repo>:<sha>` to Docker Hub. *Nothing is deployed yet.*
2. STO pulls that exact tag and runs Trivy.
3. If Trivy reports any CRITICAL CVE, the AquaTrivy step exits non-zero.
4. The STO stage's `failureStrategies: [{ onFailure: { action: { type: MarkAsFailure }}}]` propagates that to a pipeline-level failure.
5. The CD stage has an implicit dependency on STO succeeding — it's never started.
6. The image still exists in Docker Hub, but no Kubernetes manifest will ever pull it because nothing references it. Optionally, you can add a cleanup step that deletes orphan tags.

That's the chain. Three things make it robust: (1) the scan target is the **same SHA** the CI stage just pushed, (2) the gate is **declarative in the pipeline YAML** (so it's reviewed in PR like any other code), and (3) **secrets used by the scan are managed by Harness** — no leaking creds into job logs.

---

## What I'd do next (good answers to "what would you improve?")

- **Cosign image signing in CI + verification in CD admission controller.** Closes the "someone retagged a different image with our SHA" loophole.
- **SBOM generation** (Syft) attached to the build. Lets us answer "are we affected by CVE-X?" without rebuilding.
- **Canary deploys with metric-based gates** (error rate, p95 latency from Prometheus) instead of just probe-based readiness.
- **OPA/Kyverno admission policies** on the cluster — defense in depth. Even if the pipeline is bypassed, the cluster refuses non-compliant pods.
- **GitOps**: keep manifests in a separate repo, have CD push a manifest update PR rather than `kubectl apply` directly. Argo CD pulls and reconciles. Pipeline becomes purely "build + scan + propose."
- **Pipeline templates** for the CI and STO stages so dozens of services share the same hardened logic.

---

## Things I deliberately kept simple (and why)

- **One environment (`dev`)** — the spec asked for "deploy to local Kubernetes". Adding staging/prod was tempting but would have stretched the demo and obscured the core flow. Adding them is a copy-paste of the CD stage with a different `environmentRef` plus a manual approval step.
- **NodePort, not Ingress.** Ingress on minikube/kind requires installing an ingress controller and futzing with `/etc/hosts`. NodePort works out of the box and the assignment explicitly allows it.
- **Trivy only, not Trivy + Snyk + Grype.** One scanner is enough to demonstrate the gate. Multiple scanners is a real-world tactic for reducing false negatives but adds cost and noise to a demo.
