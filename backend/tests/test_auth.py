"""Real PostgreSQL authentication checks; SMTP is replaced only through DI."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app.auth_models import AuthAccessToken, AuthRenewalToken, AuthSession, EmailChallenge
from app.core.config import settings
from app.db.models import Folder, User
from app.integrations.email import SmtpEmailSender, get_email_sender
from app.services import auth


class CapturingSender:
    def __init__(self):
        self.messages = []

    def send_code(self, recipient, code):
        self.messages.append((recipient, code))


@pytest.fixture
def sender(monkeypatch):
    monkeypatch.setattr(settings, "auth_secret", "integration-test-secret-32-bytes-minimum")
    monkeypatch.setattr(settings, "auth_admin_emails", ["owner@example.org"])
    monkeypatch.setattr(settings, "auth_legacy_admin_email", "")
    return CapturingSender()


@pytest.fixture
def auth_client(client, sender):
    from app.api.auth import get_current_user
    from app.main import app
    app.dependency_overrides.pop(get_current_user, None)
    app.dependency_overrides[get_email_sender] = lambda: sender
    yield client


def login(client, sender, email="person@cbr.ru", remember=False):
    requested = client.post("/api/v1/auth/request-code", json={"email": email})
    assert requested.status_code == 202, requested.text
    data = requested.json()
    assert "code" not in data
    verified = client.post("/api/v1/auth/verify-code", json={
        "challenge_id": data["challenge_id"], "email": email,
        "code": sender.messages[-1][1], "remember_me": remember})
    assert verified.status_code == 200, verified.text
    return verified.json()


@pytest.mark.parametrize("address", ["a@cbr.ru.evil.example", "a@evil.example", "a@sub.cbr.ru"])
def test_rejects_noncorporate_domain(auth_client, sender, address):
    result = auth_client.post("/api/v1/auth/request-code", json={"email": address})
    assert result.status_code == 403
    assert sender.messages == []


def test_rejects_bad_address(auth_client, sender):
    assert auth_client.post("/api/v1/auth/request-code", json={"email": "a@@cbr.ru"}).status_code == 422
    assert sender.messages == []


@pytest.mark.parametrize("remember", [True, False])
def test_login_and_token_storage(auth_client, database, sender, remember):
    result = login(auth_client, sender, "Person@CBR.RU", remember)
    assert result["user"]["email"] == "person@cbr.ru"
    assert result["user"]["role"] == "user"
    assert result["expires_in"] == 900
    assert result["persistence"] == ("secure_storage" if remember else "memory_only")
    assert ("refresh_token" in result) is remember
    assert ("session_token" in result) is not remember
    assert auth_client.get("/api/v1/auth/me").status_code == 401
    assert auth_client.get("/api/v1/auth/me", headers={"Authorization": "Bearer " + result["access_token"]}).status_code == 200
    with database() as db:
        access = db.get(AuthAccessToken, auth.digest(result["access_token"]))
        session = db.get(AuthSession, access.session_id)
        assert (session.expires_at - session.created_at).days == (30 if remember else 1)
        challenge = db.scalar(select(EmailChallenge))
        assert challenge.code_hash != sender.messages[-1][1]
        assert len(challenge.code_hash) == 64


def test_admin_allowlist(auth_client, sender):
    result = login(auth_client, sender, "owner@example.org")
    assert result["user"]["role"] == "admin"


def test_resend_throttle(auth_client, sender):
    assert auth_client.post("/api/v1/auth/request-code", json={"email": "a@cbr.ru"}).status_code == 202
    limited = auth_client.post("/api/v1/auth/request-code", json={"email": "A@cbr.ru"})
    assert limited.status_code == 429
    assert limited.headers["retry-after"] == "60"
    assert len(sender.messages) == 1


def test_wrong_code_attempts_persist(auth_client, database, sender):
    requested = auth_client.post("/api/v1/auth/request-code", json={"email": "a@cbr.ru"}).json()
    code = "000001" if sender.messages[-1][1] == "000000" else "000000"
    body = {"challenge_id": requested["challenge_id"], "email": "a@cbr.ru", "code": code}
    for _ in range(4):
        assert auth_client.post("/api/v1/auth/verify-code", json=body).status_code == 401
    assert auth_client.post("/api/v1/auth/verify-code", json=body).status_code == 429
    body["code"] = sender.messages[-1][1]
    assert auth_client.post("/api/v1/auth/verify-code", json=body).status_code == 429
    with database() as db:
        assert db.get(EmailChallenge, UUID(requested["challenge_id"])).attempts == 5


def test_expired_code(auth_client, database, sender):
    requested = auth_client.post("/api/v1/auth/request-code", json={"email": "a@cbr.ru"}).json()
    with database.begin() as db:
        db.get(EmailChallenge, UUID(requested["challenge_id"])).expires_at = auth.utcnow() - timedelta(seconds=1)
    result = auth_client.post("/api/v1/auth/verify-code", json={
        "challenge_id": requested["challenge_id"], "email": "a@cbr.ru", "code": sender.messages[-1][1]})
    assert result.status_code == 401
    assert result.json()["error"]["code"] == "code_expired"


def test_used_code_cannot_login_again(auth_client, database, sender):
    login(auth_client, sender)
    with database() as db:
        challenge = db.scalar(select(EmailChallenge))
        challenge_id = str(challenge.id)
    result = auth_client.post("/api/v1/auth/verify-code", json={
        "challenge_id": challenge_id, "email": "person@cbr.ru", "code": sender.messages[-1][1]})
    assert result.status_code == 401


@pytest.mark.parametrize("remember", [True, False])
def test_refresh_replay_and_logout(auth_client, database, sender, remember):
    original = login(auth_client, sender, remember=remember)
    field = "refresh_token" if remember else "session_token"
    body = {field: original[field]}
    headers = {"Idempotency-Key": str(uuid4())}
    rotated = auth_client.post("/api/v1/auth/refresh", json=body, headers=headers)
    assert rotated.status_code == 200, rotated.text
    renewed = rotated.json()
    assert renewed[field] != original[field]
    assert renewed["session_expires_at"] == original["session_expires_at"]
    assert auth_client.post("/api/v1/auth/refresh", json=body, headers=headers).json() == renewed
    bearer = {"Authorization": "Bearer " + renewed["access_token"]}
    assert auth_client.post("/api/v1/auth/logout", headers=bearer).status_code == 204
    assert auth_client.post("/api/v1/auth/logout", headers=bearer).status_code == 204
    assert auth_client.get("/api/v1/auth/me", headers=bearer).status_code == 401
    assert auth_client.post("/api/v1/auth/refresh", json=body, headers=headers).status_code == 401
    assert auth_client.post("/api/v1/auth/refresh", json={field: renewed[field]}, headers=headers).status_code == 401


def test_refresh_reuse_revokes_family(auth_client, sender):
    original = login(auth_client, sender, remember=True)
    body = {"refresh_token": original["refresh_token"]}
    first = auth_client.post("/api/v1/auth/refresh", json=body, headers={"Idempotency-Key": "first"}).json()
    assert auth_client.post("/api/v1/auth/refresh", json=body, headers={"Idempotency-Key": "other"}).status_code == 401
    assert auth_client.get("/api/v1/auth/me", headers={"Authorization": "Bearer " + first["access_token"]}).status_code == 401


def test_refresh_requires_one_token_and_key(auth_client, sender):
    original = login(auth_client, sender)
    body = {"session_token": original["session_token"]}
    assert auth_client.post("/api/v1/auth/refresh", json=body).status_code == 422
    assert auth_client.post("/api/v1/auth/refresh", json={**body, "refresh_token": "x" * 43},
                            headers={"Idempotency-Key": "key"}).status_code == 422
    assert auth_client.post("/api/v1/auth/refresh", json={"refresh_token": original["session_token"]},
                            headers={"Idempotency-Key": "key"}).status_code == 401


def test_expired_access_can_refresh(auth_client, database, sender):
    original = login(auth_client, sender)
    with database.begin() as db:
        db.get(AuthAccessToken, auth.digest(original["access_token"])).expires_at = auth.utcnow() - timedelta(seconds=1)
    assert auth_client.get("/api/v1/auth/me", headers={"Authorization": "Bearer " + original["access_token"]}).status_code == 401
    assert auth_client.post("/api/v1/auth/refresh", json={"session_token": original["session_token"]},
                            headers={"Idempotency-Key": "key"}).status_code == 200


def test_absolute_session_expiry(auth_client, database, sender):
    original = login(auth_client, sender)
    with database.begin() as db:
        token = db.get(AuthRenewalToken, auth.digest(original["session_token"]))
        db.get(AuthSession, token.session_id).expires_at = auth.utcnow() - timedelta(seconds=1)
    result = auth_client.post("/api/v1/auth/refresh", json={"session_token": original["session_token"]},
                              headers={"Idempotency-Key": "key"})
    assert result.status_code == 401
    assert result.json()["error"]["code"] == "session_expired"


@pytest.mark.parametrize("remember", [True, False])
def test_logout_with_expired_access_revokes_active_session(auth_client, database, sender, remember):
    original = login(auth_client, sender, remember=remember)
    with database.begin() as db:
        db.get(AuthAccessToken, auth.digest(original["access_token"])).expires_at = auth.utcnow() - timedelta(seconds=1)
    bearer = {"Authorization": "Bearer " + original["access_token"]}
    assert auth_client.get("/api/v1/auth/me", headers=bearer).status_code == 401
    assert auth_client.post("/api/v1/auth/logout", headers=bearer).status_code == 204
    assert auth_client.post("/api/v1/auth/logout", headers=bearer).status_code == 204
    field = "refresh_token" if remember else "session_token"
    assert auth_client.post("/api/v1/auth/refresh", json={field: original[field]},
                            headers={"Idempotency-Key": "logout-expired"}).status_code == 401


def test_smtp_unconfigured_reports_failure(auth_client, database, sender, monkeypatch):
    from app.main import app
    monkeypatch.setattr(settings, "smtp_host", "")
    app.dependency_overrides[get_email_sender] = lambda: SmtpEmailSender()
    assert auth_client.post("/api/v1/auth/request-code", json={"email": "a@cbr.ru"}).status_code == 503
    assert sender.messages == []
    with database() as db:
        challenge = db.scalar(select(EmailChallenge))
        assert not challenge.delivered
        assert challenge.consumed_at is not None


def test_legacy_claim_requires_configured_verified_admin(auth_client, database, sender, monkeypatch):
    with database.begin() as db:
        legacy = db.get(User, auth.LEGACY_USER_ID)
        assert legacy is not None
        legacy.legacy_claim_pending = True
        folder = Folder(user_id=legacy.id, name="Preserved")
        db.add(folder)
        db.flush()
        folder_id = folder.id
    corporate = login(auth_client, sender)
    assert corporate["user"]["id"] != str(auth.LEGACY_USER_ID)
    with database() as db:
        assert db.get(User, auth.LEGACY_USER_ID).legacy_claim_pending
    monkeypatch.setattr(settings, "auth_legacy_admin_email", "owner@example.org")
    owner = login(auth_client, sender, "owner@example.org")
    assert owner["user"]["id"] == str(auth.LEGACY_USER_ID)
    with database() as db:
        assert db.get(Folder, folder_id).user_id == auth.LEGACY_USER_ID
        assert not db.get(User, auth.LEGACY_USER_ID).legacy_claim_pending


def test_concurrent_refresh_same_key_is_one_rotation(database, sender):
    with database() as db:
        request = auth.request_code(db, "concurrent@cbr.ru", "127.0.0.1", sender)
        original = auth.verify_code(db, request.challenge_id, "concurrent@cbr.ru", sender.messages[-1][1], True)
    def rotate():
        with database() as db:
            return auth.refresh(db, original.refresh_token, remembered=True, idempotency_key="same-key")
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda _: rotate(), range(2)))
    assert results[0].model_dump() == results[1].model_dump()
    with database() as db:
        session = db.scalar(select(AuthSession).where(AuthSession.user_id == original.user.id))
        assert session.revoked_at is None
        assert len(db.scalars(select(AuthRenewalToken).where(AuthRenewalToken.session_id == session.id)).all()) == 2


def test_email_and_ip_hourly_limits(database, sender):
    now = auth.utcnow()
    with database.begin() as db:
        for index in range(30):
            db.add(EmailChallenge(email=f"past{index}@cbr.ru", ip_hash=auth.keyed_digest("ip:127.0.0.9"),
                code_hash="0" * 64, created_at=now - timedelta(minutes=2),
                expires_at=now + timedelta(minutes=8), delivered=False))
    with database() as db, pytest.raises(HTTPException) as error:
        auth.request_code(db, "new@cbr.ru", "127.0.0.9", sender)
    assert error.value.status_code == 429
    assert sender.messages == []


def test_email_hourly_limit_cannot_be_bypassed_by_ip(database, sender):
    now = auth.utcnow()
    with database.begin() as db:
        for index in range(5):
            db.add(EmailChallenge(email="limited@cbr.ru", ip_hash=auth.keyed_digest(f"ip:{index}"),
                code_hash="0" * 64, created_at=now - timedelta(minutes=2 + index),
                expires_at=now + timedelta(minutes=8), delivered=False))
    with database() as db, pytest.raises(HTTPException) as error:
        auth.request_code(db, "limited@cbr.ru", "127.0.0.123", sender)
    assert error.value.status_code == 429
    assert sender.messages == []


def test_concurrent_code_consumption_creates_one_session(database, sender):
    with database() as db:
        challenge = auth.request_code(db, "once@cbr.ru", "127.0.0.1", sender)
    code = sender.messages[-1][1]
    def verify():
        with database() as db:
            try:
                auth.verify_code(db, challenge.challenge_id, "once@cbr.ru", code, True)
                return 200
            except HTTPException as exc:
                return exc.status_code
    with ThreadPoolExecutor(max_workers=2) as executor:
        statuses = list(executor.map(lambda _: verify(), range(2)))
    assert sorted(statuses) == [200, 401]
    with database() as db:
        user = db.scalar(select(User).where(User.email == "once@cbr.ru"))
        assert len(db.scalars(select(AuthSession).where(AuthSession.user_id == user.id)).all()) == 1


def test_replay_receipt_expiration_revokes_session(auth_client, database, sender):
    original = login(auth_client, sender, remember=True)
    body = {"refresh_token": original["refresh_token"]}
    headers = {"Idempotency-Key": "lost-response"}
    rotated = auth_client.post("/api/v1/auth/refresh", json=body, headers=headers).json()
    with database.begin() as db:
        db.get(AuthRenewalToken, auth.digest(original["refresh_token"])).replay_until = auth.utcnow() - timedelta(seconds=1)
    assert auth_client.post("/api/v1/auth/refresh", json=body, headers=headers).status_code == 401
    assert auth_client.get("/api/v1/auth/me", headers={"Authorization": "Bearer " + rotated["access_token"]}).status_code == 401


def test_secret_missing_fails_closed(auth_client, sender, monkeypatch):
    monkeypatch.setattr(settings, "auth_secret", "")
    response = auth_client.post("/api/v1/auth/request-code", json={"email": "a@cbr.ru"})
    assert response.status_code == 503
    assert sender.messages == []
