import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, LargeBinary, String, Text, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column
from app.db.models import Base


class AudioSession(Base):
    __tablename__ = "audio_sessions"
    __table_args__ = (UniqueConstraint("user_id", "idempotency_key"),
        CheckConstraint("status IN ('recording','transcribing','ready_for_review','failed','completed')"),)
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), index=True)
    status: Mapped[str] = mapped_column(String(24), default="recording")
    request_data: Mapped[dict] = mapped_column(JSONB)
    idempotency_key: Mapped[str | None] = mapped_column(String(128))
    request_hash: Mapped[str] = mapped_column(String(64))
    expected_chunk_count: Mapped[int | None] = mapped_column(Integer)
    transcript_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("transcripts.id", ondelete="SET NULL"), unique=True)
    error_code: Mapped[str | None] = mapped_column(String(64))
    boundary_warnings: Mapped[list] = mapped_column(JSONB, default=list, server_default="[]")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AudioChunk(Base):
    __tablename__ = "audio_chunks"
    __table_args__ = (UniqueConstraint("session_id", "sequence_number"),
        CheckConstraint("sequence_number >= 0 AND duration_ms > 0 AND start_ms >= 0 AND overlap_ms >= 0"),
        CheckConstraint("status IN ('queued','transcribing','done','failed')"),)
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    session_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("audio_sessions.id", ondelete="CASCADE"), index=True)
    sequence_number: Mapped[int] = mapped_column(Integer)
    start_ms: Mapped[int] = mapped_column(Integer)
    overlap_ms: Mapped[int] = mapped_column(Integer, default=0)
    duration_ms: Mapped[int] = mapped_column(Integer)
    sha256: Mapped[str] = mapped_column(String(64))
    byte_count: Mapped[int] = mapped_column(Integer)
    audio_format: Mapped[str] = mapped_column(String(12))
    payload: Mapped[bytes | None] = mapped_column(LargeBinary, deferred=True)
    status: Mapped[str] = mapped_column(String(16), default="queued", index=True)
    text: Mapped[str | None] = mapped_column(Text)
    segments: Mapped[list | None] = mapped_column(JSONB)
    attempt: Mapped[int] = mapped_column(Integer, default=0)
    claimed_by: Mapped[uuid.UUID | None]
    error_code: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class ASRWorkerState(Base):
    __tablename__ = "asr_worker_state"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    generation: Mapped[uuid.UUID]
    pid: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(16))
    model: Mapped[str] = mapped_column(String(64))
    heartbeat_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    error_code: Mapped[str | None] = mapped_column(String(64))
