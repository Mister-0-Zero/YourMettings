"""Durable Qwen dispatch and opt-in automatic audio pipeline (additive)."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql as pg

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("audio_sessions", sa.Column("pipeline_config", pg.JSONB(), nullable=True))
    op.create_table("processing_jobs",
        sa.Column("id", pg.UUID(as_uuid=True), primary_key=True),
        sa.Column("owner_user_id", pg.UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("transcript_id", pg.UUID(as_uuid=True), sa.ForeignKey("transcripts.id", ondelete="CASCADE")),
        sa.Column("candidate_id", pg.UUID(as_uuid=True), sa.ForeignKey("summary_candidates.id", ondelete="CASCADE")),
        sa.Column("target_attempt", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("claim_epoch", sa.Integer(), nullable=False),
        sa.Column("lease_until", sa.DateTime(timezone=True)),
        sa.Column("available_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("delivery_count", sa.Integer(), nullable=False),
        sa.Column("last_error_code", sa.String(64)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("deadline_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("(transcript_id IS NULL) <> (candidate_id IS NULL)"),
        sa.CheckConstraint("status IN ('queued','running','done','error','cancelled')"),
        sa.UniqueConstraint("transcript_id", "target_attempt"),
        sa.UniqueConstraint("candidate_id", "target_attempt"))
    for field in ("owner_user_id", "status", "available_at"):
        op.create_index(f"ix_processing_jobs_{field}", "processing_jobs", [field])
    op.create_table("audio_pipeline_requests",
        sa.Column("session_id", pg.UUID(as_uuid=True), sa.ForeignKey("audio_sessions.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("key", sa.String(128), primary_key=True),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("response", pg.JSONB(), nullable=False))
    op.create_table("qwen_worker_state",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("generation", pg.UUID(as_uuid=True), nullable=False),
        sa.Column("pid", sa.Integer(), nullable=False),
        sa.Column("heartbeat_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False))


def downgrade():
    op.drop_table("qwen_worker_state")
    op.drop_table("audio_pipeline_requests")
    op.drop_table("processing_jobs")
    op.drop_column("audio_sessions", "pipeline_config")

