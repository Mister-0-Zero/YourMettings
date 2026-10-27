"""Internal retention; never delete renewal reuse evidence from an active session."""
from datetime import datetime, timedelta, timezone
from sqlalchemy import delete, or_
from app.auth_models import AuthSession, EmailChallenge


def cleanup_auth_records(db):
    cutoff = datetime.now(timezone.utc) - timedelta(days=1)
    db.execute(delete(AuthSession).where(or_(AuthSession.expires_at < cutoff, AuthSession.revoked_at < cutoff)))
    db.execute(delete(EmailChallenge).where(EmailChallenge.expires_at < cutoff))
