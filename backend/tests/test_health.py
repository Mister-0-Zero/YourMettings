from fastapi.testclient import TestClient

from app.main import app
from app.core.config import settings


def test_health(monkeypatch):
    monkeypatch.setattr(settings, "database_url", "")
    with TestClient(app) as client:
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
        assert client.get("/openapi.json").status_code == 401
        assert "/health" in app.openapi()["paths"]
