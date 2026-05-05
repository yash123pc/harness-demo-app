"""Tiny smoke tests so CI has something meaningful to run."""
from app import app


def test_root():
    client = app.test_client()
    res = client.get("/")
    assert res.status_code == 200
    assert b"Hello World" in res.data


def test_health():
    client = app.test_client()
    res = client.get("/health")
    assert res.status_code == 200
    assert res.get_json()["status"] == "ok"
