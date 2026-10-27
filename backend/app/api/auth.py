from fastapi import APIRouter, Depends, Header, Request, Response
from typing import Annotated
from fastapi.security import APIKeyHeader, HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.auth_schemas import AuthUser, CodeRequested, RefreshToken, RequestCode, TokenPair, VerifyCode
from app.db.models import User
from app.db.session import get_db
from app.integrations.email import EmailSender, get_email_sender
from app.services import auth
from app.core.config import settings
from app.services import demo_access

router = APIRouter(prefix="/auth", tags=["auth"])
bearer = HTTPBearer(auto_error=False)
demo_key = APIKeyHeader(name="X-Demo-Key", auto_error=False)


def access_credential(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> str:
    if credentials is None or credentials.scheme.lower() != "bearer":
        auth.fail(401, "authentication_required")
    return credentials.credentials


def get_current_user(db: Session = Depends(get_db),
                     credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
                     key: str | None = Depends(demo_key)) -> User:
    if settings.demo_enabled:
        demo_access.check_key(key)
        user = db.get(User, demo_access.DEMO_USER_ID)
        if (user is None or user.email != demo_access.DEMO_EMAIL or user.role != "user" or
                user.email_verified_at is not None or user.legacy_claim_pending):
            demo_access.fail(503, "demo_not_configured")
        db.info["user_id"] = user.id
        return user
    session = auth.authenticate_session(db, access_credential(credentials))
    user = db.get(User, session.user_id)
    if user is None or user.email_verified_at is None or user.legacy_claim_pending:
        auth.fail(401, "invalid_session")
    db.info["user_id"] = user.id
    db.commit()
    return user


@router.post("/request-code", response_model=CodeRequested, status_code=202)
def request_code(body: RequestCode, request: Request, db: Session = Depends(get_db),
                 sender: EmailSender = Depends(get_email_sender)):
    # Trusted proxy interpretation belongs to the ASGI server; never read forwarded headers here.
    ip = request.client.host if request.client else "unknown"
    return auth.request_code(db, body.email, ip, sender)


@router.post("/verify-code", response_model=TokenPair, response_model_exclude_none=True)
def verify_code(body: VerifyCode, db: Session = Depends(get_db)):
    return auth.verify_code(db, body.challenge_id, body.email, body.code, body.remember_me)


@router.post("/refresh", response_model=TokenPair, response_model_exclude_none=True)
def refresh(body: RefreshToken, idempotency_key: Annotated[str, Header(min_length=1, max_length=128)],
            db: Session = Depends(get_db)):
    return auth.refresh(db, body.refresh_token or body.session_token,
                        remembered=body.refresh_token is not None, idempotency_key=idempotency_key)


@router.post("/logout", status_code=204)
def logout(db: Session = Depends(get_db), token: str = Depends(access_credential)):
    auth.logout(db, token)
    return Response(status_code=204)


@router.get("/me", response_model=AuthUser)
def me(user: User = Depends(get_current_user)):
    return AuthUser.model_validate(user).model_copy(update={
        "access_mode": "demo" if settings.demo_enabled else "email"})
