"""Demo gate checks plus PostgreSQL isolation against existing account resources."""
from datetime import datetime, timedelta, timezone
from uuid import UUID

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy import select

from app.core.config import Settings, settings
from app.core.http_security import RequestBoundary
from app.db.models import User
from app.db.session import initialize_database, TEST_USER_ID
from app.services import demo_access

KEY = "unit-test-demo-key-43-characters-minimum-abcdefgh"


def enable_demo(monkeypatch):
    monkeypatch.setattr(settings, "demo_secret", KEY)
    monkeypatch.setattr(settings, "demo_expires_at", datetime.now(timezone.utc) + timedelta(hours=48))
    monkeypatch.setattr(settings, "demo_enabled", True)


@pytest.fixture
def gate(monkeypatch):
    enable_demo(monkeypatch)
    application = FastAPI()
    application.add_middleware(RequestBoundary)

    @application.get("/health")
    def health():
        return {"status": "ok"}

    with TestClient(application) as client:
        yield client


@pytest.mark.parametrize("changes", [
    {"demo_secret": "short"}, {"demo_secret": ""},
    {"demo_secret": "x" * 42}, {"demo_secret": "я" * 43},
    {"demo_expires_at": None},
    {"demo_expires_at": datetime.now()},
    {"demo_expires_at": datetime.now(timezone.utc) - timedelta(seconds=1)},
])
def test_configuration_fails_closed_without_leaking_secret(changes):
    values = {"demo_enabled": True, "demo_secret": KEY,
              "demo_expires_at": datetime.now(timezone.utc) + timedelta(hours=48), **changes}
    with pytest.raises(ValidationError) as error:
        Settings(_env_file=None, **values)
    assert KEY not in str(error.value)


def test_configuration_defaults_to_email():
    config = Settings(_env_file=None, demo_enabled=False, demo_secret="")
    assert not config.demo_enabled
    assert "demo_secret=" not in repr(config)
    assert "demo_secret=" not in repr(settings)


@pytest.mark.parametrize("path", ["/health", "/docs", "/redoc", "/openapi.json",
    "/api/v1/folders", "/api/v1/auth/me", "/nonexistent"])
def test_every_path_requires_header_before_body(gate, path):
    response = gate.post(path, content=b"not-json", headers={"Content-Length": "999999999"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "demo_key_required"
    assert response.headers["cache-control"] == "no-store"


def test_query_cookie_bearer_and_duplicate_keys_do_not_authorize(gate):
    for headers in ({"Authorization": "Bearer " + KEY}, {"Cookie": "X-Demo-Key=" + KEY},
                    {"X-Demo-Key": "wrong"}, {"X-Demo-Key": b"\xff"}):
        response = gate.get("/health", params={"X-Demo-Key": KEY}, headers=headers)
        assert response.status_code == 401
        assert KEY not in response.text
    assert gate.get("/health", headers=[("X-Demo-Key", KEY), ("X-Demo-Key", KEY)]).status_code == 401
    assert gate.get("/health", headers={"X-Demo-Key": KEY}).status_code == 200


def test_rotation_expiry_and_disable(gate, monkeypatch):
    assert gate.get("/health", headers={"X-Demo-Key": KEY}).status_code == 200
    replacement = "rotated-key-43-characters-minimum-for-test-abcdef"
    monkeypatch.setattr(settings, "demo_secret", replacement)
    assert gate.get("/health", headers={"X-Demo-Key": KEY}).status_code == 401
    assert gate.get("/health", headers={"X-Demo-Key": replacement}).status_code == 200
    monkeypatch.setattr(settings, "demo_expires_at", datetime.now(timezone.utc) - timedelta(seconds=1))
    assert gate.get("/health", headers={"X-Demo-Key": replacement}).status_code == 403
    monkeypatch.setattr(settings, "demo_enabled", False)
    assert gate.get("/health").status_code == 200


def test_runtime_configuration_loss_fails_closed(gate, monkeypatch):
    monkeypatch.setattr(settings, "demo_secret", "")
    response = gate.get("/health", headers={"X-Demo-Key": KEY})
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "demo_not_configured"


@pytest.mark.parametrize("endpoint", ["request-code", "verify-code", "refresh", "logout", "logout/"])
def test_email_endpoints_unavailable_before_validation(gate, endpoint):
    response = gate.post("/api/v1/auth/" + endpoint, content=b"not-json",
                         headers={"X-Demo-Key": KEY})
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "auth_unavailable_demo"


def test_rate_limit_ignores_spoofed_forwarded_headers(gate):
    for index in range(10):
        assert gate.get("/health", headers={"X-Demo-Key": "bad", "X-Forwarded-For": str(index)}).status_code == 401
    response = gate.get("/health", headers={"X-Demo-Key": "bad", "X-Forwarded-For": "fresh"})
    assert response.status_code == 429
    assert 1 <= int(response.headers["retry-after"]) <= 60
    assert gate.get("/health", headers={"X-Demo-Key": KEY}).status_code == 200


def test_valid_requests_rate_limited(gate):
    for _ in range(360):
        assert gate.get("/health", headers={"X-Demo-Key": KEY}).status_code == 200
    assert gate.get("/health", headers={"X-Demo-Key": KEY}).status_code == 429


def test_rolling_window_and_memory_caps(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(demo_access.time, "monotonic", lambda: clock[0])
    limiter = demo_access.DemoRateLimiter(max_buckets=2, global_invalid=3, global_valid=3)
    limiter.check("one", False)
    limiter.check("two", False)
    with pytest.raises(HTTPException) as error:
        limiter.check("three", False)
    assert error.value.status_code == 429 and len(limiter.buckets) == 2
    limiter.check("one", False)
    with pytest.raises(HTTPException):
        limiter.check("one", False)
    assert sum(map(len, limiter.global_events.values())) == 3
    clock[0] += 60
    limiter.check("three", False)
    assert len(limiter.buckets) == 1
    assert len(limiter.global_events[False]) == 1


def test_gate_never_reads_body_when_key_missing(monkeypatch):
    import asyncio
    enable_demo(monkeypatch)
    called = []
    async def downstream(scope, receive, send):
        raise AssertionError("downstream must not run")
    async def receive():
        raise AssertionError("request body must not be read")
    async def send(message):
        called.append(message)
    asyncio.run(RequestBoundary(downstream)({"type": "http", "method": "POST",
        "path": "/api/v1/audio-sessions/id/chunks", "headers": [], "client": ("127.0.0.1", 1)}, receive, send))
    assert called[0]["status"] == 401


@pytest.mark.integration
def test_demo_identity_creation_and_email_mode_restoration(client, database, monkeypatch):
    from app.api.auth import get_current_user
    from app.main import app
    from app.services import auth
    from test_auth import CapturingSender
    app.dependency_overrides.pop(get_current_user, None)
    monkeypatch.setattr(settings, "auth_secret", "integration-test-secret-32-bytes-minimum")
    sender = CapturingSender()
    with database() as db:
        request = auth.request_code(db, "normal@cbr.ru", "127.0.0.1", sender)
        tokens = auth.verify_code(db, request.challenge_id, "normal@cbr.ru", sender.messages[-1][1], False)
    assert tokens.user.access_mode == "email"
    enable_demo(monkeypatch)
    initialize_database(database)
    initialize_database(database)
    headers = {"X-Demo-Key": KEY}
    response = client.get("/api/v1/auth/me", headers=headers)
    assert response.status_code == 200, response.text
    assert response.json() == {"id": str(demo_access.DEMO_USER_ID), "email": demo_access.DEMO_EMAIL,
                               "role": "user", "email_verified_at": None, "access_mode": "demo"}
    assert client.get("/api/v1/auth/me", headers={"Authorization": "Bearer " + tokens.access_token}).status_code == 401
    combined = client.get("/api/v1/auth/me", headers={**headers, "Authorization": "Bearer " + tokens.access_token})
    assert combined.status_code == 200 and combined.json()["id"] == str(demo_access.DEMO_USER_ID)
    schema = client.get("/openapi.json", headers=headers)
    assert schema.status_code == 200
    security = schema.json()["paths"]["/api/v1/auth/me"]["get"]["security"]
    assert {"APIKeyHeader": []} in security and {"HTTPBearer": []} in security
    with database() as db:
        assert db.get(User, TEST_USER_ID).email == "test@yourmettings.local"
        assert len(db.scalars(select(User).where(User.id == demo_access.DEMO_USER_ID)).all()) == 1
    monkeypatch.setattr(settings, "demo_enabled", False)
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 401
    restored = client.get("/api/v1/auth/me", headers={"Authorization": "Bearer " + tokens.access_token})
    assert restored.status_code == 200 and restored.json()["access_mode"] == "email"


@pytest.mark.integration
def test_demo_cannot_read_or_modify_existing_account_data(client, database, monkeypatch):
    from app.api.auth import get_current_user
    from app.main import app
    from test_tenant_isolation import Actor, checked, meeting, selection
    from test_templates import definition
    from test_processing import FakeGenerator
    from app.integrations.ollama import get_generator
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    # Existing test account stands for preserved legacy/user content.
    owner = Actor(client, {"access_token": "test-fixture-only", "user": {"id": str(TEST_USER_ID)}})
    folder, transcript, summary = meeting(owner)
    template = checked(owner.call("POST", "/summary-templates", json=definition()), 201)["id"]
    draft = checked(owner.call("POST", "/audio-sessions", json={"title": "Private audio", "folder_ids": [folder]}), 201)["id"]
    candidates = selection(owner, folder)
    candidate = checked(owner.call("POST", f"/summary-selections/{candidates['id']}/candidates", json={},
                                  headers={"Idempotency-Key": "private-candidate"}), 202)
    app.dependency_overrides.pop(get_current_user, None)
    enable_demo(monkeypatch)
    initialize_database(database)
    headers = {"X-Demo-Key": KEY}
    for path in ("/folders", "/summaries"):
        response = client.get("/api/v1" + path, headers=headers)
        assert response.status_code == 200 and response.json()["items"] == []
    paths = [f"/transcripts/{transcript}", f"/summaries/{summary}",
             f"/summary-templates/{template}", f"/audio-sessions/{draft}",
             f"/summary-selections/{candidates['id']}", f"/summary-candidates/{candidate['id']}"]
    for path in paths:
        response = client.get("/api/v1" + path, headers=headers)
        assert response.status_code == 404, (path, response.text)
    assert client.patch(f"/api/v1/folders/{folder}", headers=headers, json={"name": "stolen"}).status_code == 404
    assert client.delete(f"/api/v1/summaries/{summary}", headers=headers).status_code == 404
    assert client.post(f"/api/v1/audio-sessions/{draft}/chunks", headers={**headers,
        "Content-Type": "application/octet-stream"}, params={"sequence_number": 0, "start_ms": 0},
        content=b"foreign-audio").status_code == 404
    assert client.post(f"/api/v1/summary-selections/{candidates['id']}/accept", headers=headers,
                       json={"candidate_id": candidate["id"]}).status_code == 404
    own = client.post("/api/v1/folders", headers=headers, json={"name": "Demo only"})
    assert own.status_code == 201
    from app.db.models import Folder
    with database() as db:
        assert db.get(Folder, UUID(own.json()["id"])).user_id == demo_access.DEMO_USER_ID
        assert db.get(Folder, UUID(folder)).user_id == TEST_USER_ID


@pytest.mark.integration
def test_disabled_demo_creates_no_account(database):
    with database() as db:
        assert db.get(User, demo_access.DEMO_USER_ID) is None


@pytest.mark.integration
def test_reserved_identity_conflict_never_rewrites_account(database, monkeypatch):
    with database.begin() as db:
        db.add(User(id=demo_access.DEMO_USER_ID, email="preserved@cbr.ru"))
    enable_demo(monkeypatch)
    with pytest.raises(RuntimeError, match="unexpected account"):
        initialize_database(database)
    with database() as db:
        assert db.get(User, demo_access.DEMO_USER_ID).email == "preserved@cbr.ru"
