from fastapi import APIRouter, Depends, Header, Request, Response
from typing import Annotated
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.auth_schemas import AuthUser, CodeRequested, RefreshToken, RequestCode, TokenPair, VerifyCode
from app.db.models import User
from app.db.session import get_db
from app.integrations.email import EmailSender, get_email_sender
from app.services import auth

router = APIRouter(prefix="/auth", tags=["auth"])
bearer = HTTPBearer(auto_error=False)


def access_credential(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> str:
    if credentials is None or credentials.scheme.lower() != "bearer":
        auth.fail(401, "authentication_required")
    return credentials.credentials


def get_current_user(db: Session = Depends(get_db), token: str = Depends(access_credential)) -> User:
    session = auth.authenticate_session(db, token)
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
    return user
