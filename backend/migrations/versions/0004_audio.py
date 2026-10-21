"""Durable audio sessions and sequential ASR queue."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("audio_sessions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("status", sa.String(24), nullable=False),
        sa.Column("request_data", JSONB(), nullable=False),
        sa.Column("idempotency_key", sa.String(128)), sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("expected_chunk_count", sa.Integer()),
        sa.Column("transcript_id", sa.Uuid(), sa.ForeignKey("transcripts.id", ondelete="SET NULL"), unique=True),
        sa.Column("error_code", sa.String(64)),
        sa.Column("boundary_warnings", JSONB(), nullable=False, server_default="[]"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("user_id", "idempotency_key"),
        sa.CheckConstraint("status IN ('recording','transcribing','ready_for_review','failed','completed')"))
    op.create_index("ix_audio_sessions_user_id", "audio_sessions", ["user_id"])
    op.create_table("audio_chunks",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("session_id", sa.Uuid(), sa.ForeignKey("audio_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("sequence_number", sa.Integer(), nullable=False), sa.Column("start_ms", sa.Integer(), nullable=False),
        sa.Column("overlap_ms", sa.Integer(), nullable=False), sa.Column("duration_ms", sa.Integer(), nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False), sa.Column("byte_count", sa.Integer(), nullable=False),
        sa.Column("audio_format", sa.String(12), nullable=False), sa.Column("payload", sa.LargeBinary()),
        sa.Column("status", sa.String(16), nullable=False), sa.Column("text", sa.Text()), sa.Column("segments", JSONB()),
        sa.Column("attempt", sa.Integer(), nullable=False), sa.Column("claimed_by", sa.Uuid()),
        sa.Column("error_code", sa.String(64)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("session_id", "sequence_number"),
        sa.CheckConstraint("sequence_number >= 0 AND duration_ms > 0 AND start_ms >= 0 AND overlap_ms >= 0"),
        sa.CheckConstraint("status IN ('queued','transcribing','done','failed')"))
    op.create_index("ix_audio_chunks_session_id", "audio_chunks", ["session_id"])
    op.create_index("ix_audio_chunks_status", "audio_chunks", ["status"])
    op.create_table("asr_worker_state",
        sa.Column("id", sa.Integer(), primary_key=True), sa.Column("generation", sa.Uuid(), nullable=False),
        sa.Column("pid", sa.Integer(), nullable=False), sa.Column("status", sa.String(16), nullable=False),
        sa.Column("model", sa.String(64), nullable=False),
        sa.Column("heartbeat_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("error_code", sa.String(64)))


def downgrade():
    op.drop_table("asr_worker_state")
    op.drop_table("audio_chunks")
    op.drop_table("audio_sessions")
