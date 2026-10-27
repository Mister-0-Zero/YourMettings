from pathlib import Path
from datetime import datetime, timezone
import re

from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field, model_validator

BACKEND_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_ROOT / ".env", env_file_encoding="utf-8", extra="ignore", hide_input_in_errors=True
    )
    database_url: str = Field("", repr=False)
    test_database_url: str = Field("", repr=False)
    auth_secret: str = Field("", repr=False)
    demo_enabled: bool = False
    demo_secret: str = Field("", repr=False)
    demo_expires_at: datetime | None = None
    backend_lan_enabled: bool = True

    @model_validator(mode="after")
    def validate_demo_configuration(self):
        if self.demo_enabled:
            if not re.fullmatch(r"[A-Za-z0-9_-]{43,256}", self.demo_secret):
                raise ValueError("DEMO_SECRET must contain 43-256 random URL-safe characters")
            expiry = self.demo_expires_at
            if expiry is None or expiry.tzinfo is None or expiry.utcoffset() is None:
                raise ValueError("DEMO_EXPIRES_AT must be an explicit timezone-aware timestamp")
            if expiry <= datetime.now(timezone.utc):
                raise ValueError("DEMO_EXPIRES_AT must be in the future")
        return self
    auth_admin_emails: list[str] = Field(default_factory=list)
    auth_legacy_admin_email: str = ""
    smtp_host: str = ""
    smtp_port: int = Field(587, ge=1, le=65535)
    smtp_username: str = ""
    smtp_password: str = Field("", repr=False)
    smtp_from_email: str = ""
    smtp_security: str = "starttls"
    trusted_proxy_ips: list[str] = Field(default_factory=list)
    max_json_request_bytes: int = Field(2 * 1024 * 1024, ge=1024, le=8 * 1024 * 1024)
    ollama_base_url: str = "http://127.0.0.1:11434"
    ollama_model: str = ""
    llm_timeout_seconds: float = Field(300, gt=0)
    max_transcript_chars: int = Field(100_000, gt=0)
    asr_home: Path = BACKEND_ROOT.parent / "asr"
    asr_enabled: bool = True
    asr_gpu_serial: bool = True
    asr_startup_timeout_seconds: int = Field(180, ge=10)
    asr_job_timeout_seconds: int = Field(600, ge=10)
    audio_chunk_target_seconds: int = Field(300, ge=1)
    audio_chunk_max_seconds: int = Field(360, ge=1)
    audio_max_upload_bytes: int = Field(32 * 1024 * 1024, ge=1024)
    audio_max_active_sessions_per_user: int = Field(10, ge=1, le=100)
    audio_max_pending_chunks_per_user: int = Field(48, ge=1, le=240)
    audio_max_pending_bytes_per_user: int = Field(256 * 1024 * 1024, ge=1024)
    audio_max_chunks: int = Field(240, ge=1, le=240)
    audio_max_overlap_ms: int = Field(3000, ge=0, le=10000)
    audio_validation_timeout_seconds: int = Field(30, ge=1)


settings = Settings()
