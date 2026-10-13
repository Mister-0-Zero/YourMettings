from fastapi.testclient import TestClient

from app.main import app
from app.core.config import settings


def test_health(monkeypatch):
    monkeypatch.setattr(settings, "database_url", "")
    with TestClient(app) as client:
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
        assert "/health" in client.get("/openapi.json").json()["paths"]
