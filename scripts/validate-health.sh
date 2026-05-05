#!/usr/bin/env bash
# Standalone post-deployment validation script.
# Mirrors what the Harness "Post-deploy validation" stage does, so you can
# run it locally to debug.
set -euo pipefail

NS="${NAMESPACE:-harness-demo}"
SVC="${SERVICE:-harness-demo-app}"
LOCAL_PORT="${LOCAL_PORT:-18080}"

echo ">> Port-forwarding svc/${SVC} in ns/${NS} -> :${LOCAL_PORT}"
kubectl -n "$NS" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT

# wait for port-forward
for i in 1 2 3 4 5; do
  sleep 2
  if nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null; then break; fi
  echo "  waiting for port-forward ($i/5)..."
done

attempts=0
max=10
until curl -fsS "http://127.0.0.1:${LOCAL_PORT}/health" | tee /tmp/health.json; do
  attempts=$((attempts+1))
  if [ "$attempts" -ge "$max" ]; then
    echo "!! /health failed after ${max} attempts"; cat /tmp/pf.log || true; exit 1
  fi
  echo "  retry ${attempts}/${max}..."
  sleep 3
done

if ! grep -q '"status":[[:space:]]*"ok"' /tmp/health.json; then
  echo "!! /health did not return status=ok"; exit 1
fi

echo ">> Validation passed."
