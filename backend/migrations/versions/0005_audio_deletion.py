"""Durable receipts for explicitly deleted unconfirmed audio sessions."""
from alembic import op
import sqlalchemy as sa

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("audio_session_deletions",
        sa.Column("session_id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("idempotency_key", sa.String(128)),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("user_id", "idempotency_key"))
    op.create_index("ix_audio_session_deletions_user_id", "audio_session_deletions", ["user_id"])


def downgrade():
    op.drop_table("audio_session_deletions")
