"""Dispatch-only durable jobs; source/options stay with their existing targets."""
from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, String, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column
from app.db.models import Base


class ProcessingJob(Base):
    __tablename__ = "processing_jobs"
    __table_args__ = (
        CheckConstraint("(transcript_id IS NULL) <> (candidate_id IS NULL)"),
        CheckConstraint("status IN ('queued','running','done','error','cancelled')"),
        UniqueConstraint("transcript_id", "target_attempt"),
        UniqueConstraint("candidate_id", "target_attempt"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    owner_user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    transcript_id: Mapped[UUID | None] = mapped_column(ForeignKey("transcripts.id", ondelete="CASCADE"))
    candidate_id: Mapped[UUID | None] = mapped_column(ForeignKey("summary_candidates.id", ondelete="CASCADE"))
    target_attempt: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(16), default="queued", index=True)
    claim_epoch: Mapped[int] = mapped_column(Integer, default=0)
    lease_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    available_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    delivery_count: Mapped[int] = mapped_column(Integer, default=0)
    last_error_code: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    deadline_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class AudioPipelineRequest(Base):
    __tablename__ = "audio_pipeline_requests"
    session_id: Mapped[UUID] = mapped_column(ForeignKey("audio_sessions.id", ondelete="CASCADE"), primary_key=True)
    key: Mapped[str] = mapped_column(String(128), primary_key=True)
    request_hash: Mapped[str] = mapped_column(String(64))
    response: Mapped[dict] = mapped_column(JSONB)


class QwenWorkerState(Base):
    __tablename__ = "qwen_worker_state"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    generation: Mapped[UUID]
    pid: Mapped[int] = mapped_column(Integer)
    heartbeat_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

