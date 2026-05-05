# syntax=docker/dockerfile:1.6
# ---------- Stage 1: builder ----------
# Install dependencies into a virtualenv so the final image stays small and clean.
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

COPY app/requirements.txt ./requirements.txt

RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install -r requirements.txt

# ---------- Stage 2: runtime ----------
# Smaller, rootless runtime image. Trivy / container scanners will scan THIS layer.
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8080

# Create an unprivileged user (security best practice)
RUN groupadd --system app && useradd --system --gid app --home /app app

WORKDIR /app

# Copy virtualenv from builder
COPY --from=builder /opt/venv /opt/venv

# Copy application source
COPY app/ /app/

# Build-time arguments (set by Harness CI from <+codebase.commitSha>)
ARG APP_VERSION=dev
ARG BUILD_SHA=local
ENV APP_VERSION=${APP_VERSION} \
    BUILD_SHA=${BUILD_SHA} \
    APP_NAME=harness-demo-app

USER app

EXPOSE 8080

# Container-level healthcheck (independent of k8s probes)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; \
        sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health',timeout=2).status==200 else 1)"

# gunicorn for production (2 workers, 4 threads is plenty for a demo)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "--access-logfile", "-", "app:app"]
