import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

from email_validator import EmailNotValidError, validate_email
from fastapi import HTTPException
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from app.auth_models import AuthAccessToken, AuthRenewalToken, AuthSession, EmailChallenge
from app.auth_schemas import AuthUser, CodeRequested, TokenPair
from app.core.config import settings
from app.db.models import User
from app.integrations.email import EmailDeliveryError, EmailSender

LEGACY_USER_ID = UUID("00000000-0000-0000-0000-000000000001")
ACCESS_SECONDS = 900


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def fail(status: int, code: str, *, retry_after: int | None = None):
    headers = {"WWW-Authenticate": "Bearer"} if status == 401 else None
    if retry_after is not None:
        headers = {"Retry-After": str(retry_after)}
    messages = {
        "auth_not_configured": "Авторизация на сервере не настроена.",
        "invalid_email": "Некорректный адрес электронной почты.",
        "email_not_allowed": "Адрес электронной почты не разрешён.",
        "code_rate_limited": "Слишком много запросов кода. Повторите позже.",
        "email_delivery_unavailable": "Отправка электронной почты недоступна. Проверьте настройки SMTP на сервере.",
        "invalid_code": "Код неверен или уже использован.",
        "code_expired": "Срок действия кода истёк.",
        "code_attempts_exceeded": "Превышено число попыток проверки кода.",
        "legacy_claim_conflict": "Для переноса существующего аккаунта требуется проверка конфигурации сервера.",
        "legacy_account_reserved": "Существующий аккаунт ожидает подтверждения владельца.",
        "authentication_required": "Требуется авторизация.",
        "invalid_access_token": "Недействительный токен доступа.",
        "access_token_expired": "Срок действия токена доступа истёк. Обновите сессию.",
        "session_expired": "Срок действия сессии истёк. Войдите повторно.",
        "session_revoked": "Сессия отозвана. Войдите повторно.",
        "invalid_session_token": "Недействительный токен обновления сессии.",
        "session_token_reused": "Обнаружено повторное использование токена. Войдите повторно.",
        "invalid_session": "Недействительная сессия.",
    }
    raise HTTPException(status, detail={"code": code, "message": messages[code], "details": {}}, headers=headers)


def secret() -> bytes:
    value = settings.auth_secret
    if len(value.encode()) < 32:
        fail(503, "auth_not_configured")
    return value.encode()


def normalize_email(value: str) -> str:
    try:
        parsed = validate_email(value, check_deliverability=False, allow_smtputf8=False)
    except EmailNotValidError:
        fail(422, "invalid_email")
    # Corporate accounts are treated case-insensitively throughout this service.
    return parsed.normalized.lower()


def allowed_email(value: str) -> str:
    email = normalize_email(value)
    admins = {normalize_email(item) for item in settings.auth_admin_emails}
    if email.rsplit("@", 1)[1] != "cbr.ru" and email not in admins:
        fail(403, "email_not_allowed")
    return email


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def keyed_digest(value: str) -> str:
    return hmac.new(secret(), value.encode(), hashlib.sha256).hexdigest()


def lock(db: Session, key: str):
    # Fixed deterministic signed key; transaction-scoped PostgreSQL lock, across processes.
    number = int.from_bytes(hashlib.sha256(key.encode()).digest()[:8], "big", signed=True)
    db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": number})


def request_code(db: Session, email: str, ip: str, sender: EmailSender) -> CodeRequested:
    email = allowed_email(email)
    ip_hash = keyed_digest("ip:" + ip)
    # Always acquire email then IP locks, consistent across requests.
    lock(db, "auth:email:" + email)
    lock(db, "auth:ip:" + ip_hash)
    now = utcnow()
    recent = db.scalar(select(EmailChallenge).where(EmailChallenge.email == email)
                       .order_by(EmailChallenge.created_at.desc()).limit(1))
    if recent and recent.created_at > now - timedelta(seconds=60):
        fail(429, "code_rate_limited", retry_after=60)
    # Counts include delivery failures; there is no public failure bypass.
    for clause, limit, hours in ((EmailChallenge.email == email, 5, 1),
                                 (EmailChallenge.email == email, 20, 24),
                                 (EmailChallenge.ip_hash == ip_hash, 30, 1)):
        count = db.scalar(select(func.count()).select_from(EmailChallenge).where(
            clause, EmailChallenge.created_at > now - timedelta(hours=hours)))
        if count >= limit:
            fail(429, "code_rate_limited", retry_after=3600)
    code = f"{secrets.randbelow(1_000_000):06d}"
    challenge = EmailChallenge(id=uuid4(), email=email, ip_hash=ip_hash, created_at=now,
                               expires_at=now + timedelta(minutes=10), attempts=0)
    challenge.code_hash = keyed_digest(f"otp:{challenge.id}:{email}:{code}")
    db.add(challenge)
    db.flush()
    # Invalidate previous codes: only the most recently requested challenge may succeed.
    for previous in db.scalars(select(EmailChallenge).where(
            EmailChallenge.email == email, EmailChallenge.id != challenge.id,
            EmailChallenge.consumed_at.is_(None))):
        previous.consumed_at = now
    try:
        sender.send_code(email, code)
    except EmailDeliveryError:
        challenge.consumed_at = now
        db.commit()
        fail(503, "email_delivery_unavailable")
    challenge.delivered = True
    db.commit()
    return CodeRequested(challenge_id=challenge.id)


def user_for_verified_email(db: Session, email: str, now: datetime) -> User:
    admins = {normalize_email(item) for item in settings.auth_admin_emails}
    legacy_email = normalize_email(settings.auth_legacy_admin_email) if settings.auth_legacy_admin_email else None
    user = db.scalar(select(User).where(User.email == email).with_for_update())
    # Only this explicitly configured, allowlisted and verified address can claim legacy data.
    if legacy_email == email and email in admins:
        legacy = db.get(User, LEGACY_USER_ID, with_for_update=True)
        if legacy is not None and legacy.legacy_claim_pending:
            if user is not None and user.id != legacy.id:
                fail(409, "legacy_claim_conflict")
            legacy.email = email
            legacy.legacy_claim_pending = False
            user = legacy
    if user is not None and user.legacy_claim_pending:
        fail(403, "legacy_account_reserved")
    if user is None:
        user = User(email=email, password_hash="!disabled", legacy_claim_pending=False)
        db.add(user)
        db.flush()
    user.email_verified_at = now
    user.role = "admin" if email in admins else "user"
    return user


def issue_tokens(db: Session, session: AuthSession, user: User, now: datetime,
                 *, tokens: tuple[str, str] | None = None, persist: bool = True) -> TokenPair:
    access, renewal = tokens or (secrets.token_urlsafe(32), secrets.token_urlsafe(32))
    access_expiry = min(now + timedelta(seconds=ACCESS_SECONDS), session.expires_at)
    if persist:
        db.add(AuthAccessToken(token_hash=digest(access), session_id=session.id, expires_at=access_expiry))
        db.add(AuthRenewalToken(token_hash=digest(renewal), session_id=session.id))
    remembered = session.kind == "remembered"
    return TokenPair(access_token=access, expires_in=max(0, int((access_expiry - now).total_seconds())),
                     access_expires_at=access_expiry,
                     session_expires_at=session.expires_at,
                     persistence="secure_storage" if remembered else "memory_only",
                     refresh_token=renewal if remembered else None,
                     session_token=None if remembered else renewal,
                     user=AuthUser.model_validate(user))


def verify_code(db: Session, challenge_id: UUID, email: str, code: str, remember_me: bool) -> TokenPair:
    email = allowed_email(email)
    lock(db, "auth:email:" + email)
    challenge = db.scalar(select(EmailChallenge).where(EmailChallenge.id == challenge_id).with_for_update())
    now = utcnow()
    if challenge is None or challenge.email != email or not challenge.delivered:
        fail(401, "invalid_code")
    if challenge.attempts >= 5:
        fail(429, "code_attempts_exceeded")
    if challenge.consumed_at is not None:
        fail(401, "invalid_code")
    if challenge.expires_at <= now:
        fail(401, "code_expired")
    expected = keyed_digest(f"otp:{challenge.id}:{email}:{code}")
    if not hmac.compare_digest(challenge.code_hash, expected):
        challenge.attempts += 1
        db.commit()
        fail(429 if challenge.attempts >= 5 else 401,
             "code_attempts_exceeded" if challenge.attempts >= 5 else "invalid_code")
    user = user_for_verified_email(db, email, now)
    challenge.consumed_at = now
    session = AuthSession(user_id=user.id, kind="remembered" if remember_me else "ephemeral",
                          created_at=now, expires_at=now + timedelta(days=30 if remember_me else 1))
    db.add(session)
    db.flush()
    result = issue_tokens(db, session, user, now)
    db.commit()
    return result


def authenticate_session(db: Session, access_token: str, *, allow_revoked: bool = False,
                         allow_expired_access: bool = False) -> AuthSession:
    if len(access_token) > 256:
        fail(401, "invalid_access_token")
    access = db.get(AuthAccessToken, digest(access_token))
    now = utcnow()
    if access is None:
        fail(401, "invalid_access_token")
    session = db.get(AuthSession, access.session_id)
    if session is None or session.expires_at <= now:
        fail(401, "session_expired")
    if session.revoked_at is not None and not allow_revoked:
        fail(401, "session_revoked")
    if access.expires_at <= now and not allow_expired_access:
        fail(401, "access_token_expired")
    return session


def refresh(db: Session, raw_token: str, *, remembered: bool, idempotency_key: str) -> TokenPair:
    token_hash = digest(raw_token)
    # Session lock first serializes rotation, reuse detection and logout for the family.
    token = db.get(AuthRenewalToken, token_hash)
    if token is None:
        fail(401, "invalid_session_token")
    session = db.scalar(select(AuthSession).where(AuthSession.id == token.session_id).with_for_update())
    db.refresh(token)
    now = utcnow()
    if session is None or session.expires_at <= now:
        fail(401, "session_expired")
    if session.revoked_at is not None:
        fail(401, "session_revoked")
    if (session.kind == "remembered") != remembered:
        fail(401, "invalid_session_token")
    user = db.get(User, session.user_id)
    if user is None or user.email_verified_at is None or user.legacy_claim_pending:
        fail(401, "invalid_session")
    # Length-prefix encoding prevents ambiguities without storing any bearer secret.
    seed = f"{len(raw_token)}:{raw_token}:{idempotency_key}"
    rotated = (keyed_digest("refresh-access:" + seed), keyed_digest("refresh-renewal:" + seed))
    if token.used_at is not None:
        if (token.request_key_hash == digest(idempotency_key) and token.replay_until is not None
                and token.replay_until > now):
            # Response is identical, including original expiry; client retries carry same key.
            result = issue_tokens(db, session, user, token.used_at, tokens=rotated, persist=False)
            db.commit()
            return result
        session.revoked_at = now
        db.commit()
        fail(401, "session_token_reused")
    token.used_at = now
    token.request_key_hash = digest(idempotency_key)
    token.replay_until = min(now + timedelta(seconds=120), session.expires_at)
    result = issue_tokens(db, session, user, now, tokens=rotated)
    db.commit()
    return result


def logout(db: Session, raw_access_token: str) -> None:
    authenticated = authenticate_session(db, raw_access_token, allow_revoked=True, allow_expired_access=True)
    session = db.scalar(select(AuthSession).where(AuthSession.id == authenticated.id).with_for_update())
    if session.revoked_at is None:
        session.revoked_at = utcnow()
    db.commit()
