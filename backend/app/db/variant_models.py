"""Durable selection operations, candidate outputs and idempotency receipts."""
from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.models import Base


class SummarySelection(Base):
    __tablename__ = "summary_selections"
    __table_args__ = (
        UniqueConstraint("user_id", "idempotency_key"),
        CheckConstraint("kind IN ('meeting','preview')"),
        CheckConstraint("status IN ('open','accepted','cancelled','expired')"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    kind: Mapped[str] = mapped_column(String(16))
    status: Mapped[str] = mapped_column(String(16), default="open")
    idempotency_key: Mapped[str] = mapped_column(String(160))
    request_hash: Mapped[str] = mapped_column(String(64))
    transcript_id: Mapped[UUID | None] = mapped_column(ForeignKey("transcripts.id", ondelete="CASCADE"), index=True)
    source_transcript_id: Mapped[UUID | None] = mapped_column(PGUUID(as_uuid=True))
    summary_id: Mapped[UUID | None] = mapped_column(ForeignKey("summaries.id", ondelete="SET NULL"), index=True)
    owns_transcript: Mapped[bool] = mapped_column(Boolean, default=False)
    source_text: Mapped[str | None] = mapped_column(Text)
    source_hash: Mapped[str] = mapped_column(String(64))
    title: Mapped[str | None] = mapped_column(String(200))
    folder_ids: Mapped[list[UUID]] = mapped_column(ARRAY(PGUUID(as_uuid=True)), default=list)
    base_version: Mapped[str | None] = mapped_column(String(64))
    accepted_candidate_id: Mapped[UUID | None] = mapped_column(PGUUID(as_uuid=True))
    accepted_response: Mapped[dict | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


class SummaryCandidate(Base):
    __tablename__ = "summary_candidates"
    __table_args__ = (CheckConstraint("status IN ('queued','generating','ready','error','discarded','expired')"),)
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    selection_id: Mapped[UUID] = mapped_column(ForeignKey("summary_selections.id", ondelete="CASCADE"), index=True)
    generation_hash: Mapped[str] = mapped_column(String(64))
    options: Mapped[dict | None] = mapped_column(JSONB)
    status: Mapped[str] = mapped_column(String(16), default="queued")
    attempt: Mapped[int] = mapped_column(Integer, default=1)
    content: Mapped[str | None] = mapped_column(Text)
    error_code: Mapped[str | None] = mapped_column(String(64))
    processing_metadata: Mapped[dict] = mapped_column(JSONB, default=dict, server_default="{}")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class CandidateRequest(Base):
    __tablename__ = "candidate_requests"
    selection_id: Mapped[UUID] = mapped_column(ForeignKey("summary_selections.id", ondelete="CASCADE"), primary_key=True)
    key: Mapped[str] = mapped_column(String(128), primary_key=True)
    request_hash: Mapped[str] = mapped_column(String(64))
    candidate_id: Mapped[UUID] = mapped_column(ForeignKey("summary_candidates.id", ondelete="CASCADE"), index=True)
