"""
Simple Flask application for the Harness CI/CD + STO hands-on assignment.

Exposes:
  GET /         -> friendly hello message
  GET /health   -> liveness/readiness probe (used by Kubernetes + post-deploy validation)
  GET /version  -> reports the build/commit information injected at container build time
"""

import os
import socket
from datetime import datetime, timezone

from flask import Flask, jsonify

app = Flask(__name__)

APP_NAME = os.environ.get("APP_NAME", "harness-demo-app")
APP_VERSION = os.environ.get("APP_VERSION", "dev")
BUILD_SHA = os.environ.get("BUILD_SHA", "local")


@app.route("/")
def index():
    return jsonify(
        message="Hello World from Harness CI/CD + STO demo!",
        app=APP_NAME,
        version=APP_VERSION,
        host=socket.gethostname(),
    )


@app.route("/health")
def health():
    """Lightweight health check used by k8s probes and pipeline validation."""
    return jsonify(
        status="ok",
        app=APP_NAME,
        version=APP_VERSION,
        commit=BUILD_SHA,
        timestamp=datetime.now(timezone.utc).isoformat(),
    ), 200


@app.route("/version")
def version():
    return jsonify(app=APP_NAME, version=APP_VERSION, commit=BUILD_SHA)


if __name__ == "__main__":
    # 0.0.0.0 so the container is reachable from outside
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
