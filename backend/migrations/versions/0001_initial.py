"""Initial MVP schema. Kept independent of mutable application models."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql as pg

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("users",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("email", sa.String(320), nullable=False, unique=True),
        sa.Column("password_hash", sa.Text(), nullable=False))
    op.create_table("folders",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("parent_id", sa.Uuid(), sa.ForeignKey("folders.id")))
    op.create_index("ix_folders_user_id", "folders", ["user_id"])
    op.create_table("transcripts",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("owner_user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("text", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("first_processed_at", sa.DateTime(timezone=True)),
        sa.Column("idempotency_key", sa.String(128)),
        sa.Column("source_hash", sa.String(64), nullable=False),
        sa.Column("processing_status", sa.String(20), nullable=False),
        sa.Column("processing_title", sa.String(200)),
        sa.Column("processing_folder_ids", pg.ARRAY(sa.Uuid())),
        sa.Column("processing_attempt", sa.Integer(), nullable=False),
        sa.Column("error_code", sa.String(64)),
        sa.UniqueConstraint("owner_user_id", "idempotency_key"),
        sa.CheckConstraint("processing_status IN ('not_started','summarizing','ready','error')"))
    op.create_index("ix_transcripts_owner_user_id", "transcripts", ["owner_user_id"])
    op.create_table("summaries",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("transcript_id", sa.Uuid(), sa.ForeignKey("transcripts.id"), nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("user_id", "transcript_id"))
    op.create_index("ix_summaries_user_id", "summaries", ["user_id"])
    op.create_index("ix_summaries_transcript_id", "summaries", ["transcript_id"])
    op.create_table("summary_folders",
        sa.Column("summary_id", sa.Uuid(), sa.ForeignKey("summaries.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("folder_id", sa.Uuid(), sa.ForeignKey("folders.id", ondelete="CASCADE"), primary_key=True))


def downgrade():
    for table in ("summary_folders", "summaries", "transcripts", "folders", "users"):
        op.drop_table(table)
