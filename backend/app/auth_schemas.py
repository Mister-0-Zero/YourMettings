from datetime import datetime, timezone
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class RequestCode(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str = Field(min_length=3, max_length=320)


class VerifyCode(RequestCode):
    challenge_id: UUID
    code: str = Field(pattern=r"^[0-9]{6}$")
    remember_me: bool = False


class RefreshToken(BaseModel):
    model_config = ConfigDict(extra="forbid")
    refresh_token: str | None = Field(default=None, min_length=40, max_length=256)
    session_token: str | None = Field(default=None, min_length=40, max_length=256)

    @model_validator(mode="after")
    def exactly_one_token(self):
        if (self.refresh_token is None) == (self.session_token is None):
            raise ValueError("Supply exactly one refresh_token or session_token")
        return self


class CodeRequested(BaseModel):
    challenge_id: UUID
    expires_in: int = 600
    resend_after: int = 60


class AuthUser(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: UUID
    email: str
    role: Literal["user", "admin"]
    email_verified_at: datetime | None
    access_mode: Literal["email", "demo"] = "email"

    @field_validator("email_verified_at")
    @classmethod
    def utc_timestamp(cls, value: datetime | None) -> datetime | None:
        return value.astimezone(timezone.utc) if value is not None else None


class TokenPair(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    expires_in: int
    access_expires_at: datetime
    session_expires_at: datetime
    persistence: Literal["secure_storage", "memory_only"]
    refresh_token: str | None = None
    session_token: str | None = None
    user: AuthUser

    @field_validator("session_expires_at", "access_expires_at")
    @classmethod
    def utc_timestamp(cls, value: datetime) -> datetime:
        return value.astimezone(timezone.utc)
