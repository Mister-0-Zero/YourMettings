"""Temporary single-account access. State and rate limits belong to one process."""
from collections import deque
from datetime import datetime, timezone
import hashlib
import hmac
import math
import re
import threading
import time
from uuid import UUID

from fastapi import HTTPException

from app.core.config import settings

DEMO_USER_ID = UUID("00000000-0000-0000-0000-000000000002")
DEMO_EMAIL = "demo@yourmettings.invalid"
DISABLED_AUTH_PATHS = frozenset(
    f"/api/v1/auth/{name}" for name in ("request-code", "verify-code", "refresh", "logout")
)


def fail(status: int, code: str, *, retry_after: int | None = None):
    messages = {
        "demo_key_required": "Требуется демонстрационный ключ.",
        "demo_key_invalid": "Недействительный демонстрационный ключ.",
        "demo_access_expired": "Срок демонстрационного доступа истёк.",
        "demo_not_configured": "Демонстрационный доступ не настроен.",
        "demo_rate_limited": "Слишком много запросов. Повторите позже.",
        "auth_unavailable_demo": "В демонстрационном режиме вход по почте недоступен.",
    }
    headers = {"Cache-Control": "no-store"}
    if retry_after is not None:
        headers["Retry-After"] = str(retry_after)
    raise HTTPException(status, detail={"code": code, "message": messages[code], "details": {}}, headers=headers)


def check_key(value: str | bytes | None):
    # Re-check configuration on requests: changing/revoking settings must fail closed.
    expiry = settings.demo_expires_at
    if expiry is None or expiry.tzinfo is None or expiry.utcoffset() is None:
        fail(503, "demo_not_configured")
    if expiry <= datetime.now(timezone.utc):
        fail(403, "demo_access_expired")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43,256}", settings.demo_secret):
        fail(503, "demo_not_configured")
    if value is None or value == b"" or value == "":
        fail(401, "demo_key_required")
    raw = value.encode("utf-8") if isinstance(value, str) else value
    # Fixed-size byte digests accept arbitrary header bytes without Unicode errors.
    if not hmac.compare_digest(hashlib.sha256(raw).digest(),
                               hashlib.sha256(settings.demo_secret.encode("ascii")).digest()):
        fail(401, "demo_key_invalid")


def ensure_demo_user(db):
    from sqlalchemy import select
    from app.db.models import User
    user = db.get(User, DEMO_USER_ID)
    if user is None:
        if db.scalar(select(User.id).where(User.email == DEMO_EMAIL)) is not None:
            raise RuntimeError("Reserved demo identity conflicts with an existing account")
        user = User(id=DEMO_USER_ID, email=DEMO_EMAIL, role="user",
                    email_verified_at=None, legacy_claim_pending=False)
        db.add(user)
        db.flush()
    if (user.email != DEMO_EMAIL or user.role != "user" or
            user.email_verified_at is not None or user.legacy_claim_pending):
        raise RuntimeError("Reserved demo identity has unexpected account attributes")
    return user


class DemoRateLimiter:
    """Rolling minute windows, bounded IP buckets and total events; no forwarded headers."""
    def __init__(self, max_buckets=2048, global_invalid=600, global_valid=6000):
        self.max_buckets = max_buckets
        self.global_limits = {False: global_invalid, True: global_valid}
        self.global_events = {False: deque(), True: deque()}
        self.buckets = {}
        self.lock = threading.Lock()

    def check(self, ip: str, valid: bool):
        now = time.monotonic()
        cutoff = now - 60
        with self.lock:
            for key, events in list(self.buckets.items()):
                while events and events[0] <= cutoff:
                    events.popleft()
                if not events:
                    del self.buckets[key]
            total = self.global_events[valid]
            while total and total[0] <= cutoff:
                total.popleft()
            if len(total) >= self.global_limits[valid]:
                fail(429, "demo_rate_limited", retry_after=max(1, math.ceil(total[0] + 60 - now)))
            key = (ip, valid)
            events = self.buckets.get(key)
            if events is None:
                if len(self.buckets) >= self.max_buckets:
                    fail(429, "demo_rate_limited", retry_after=60)
                events = self.buckets[key] = deque()
            if len(events) >= (360 if valid else 10):
                fail(429, "demo_rate_limited", retry_after=max(1, math.ceil(events[0] + 60 - now)))
            events.append(now)
            total.append(now)
