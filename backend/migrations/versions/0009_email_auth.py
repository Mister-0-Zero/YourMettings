"""Email OTP authentication; reserve legacy owner without changing its IDs or data."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("users", sa.Column("role", sa.String(16), nullable=False, server_default="user"))
    op.add_column("users", sa.Column("email_verified_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("users", sa.Column("legacy_claim_pending", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.execute("UPDATE users SET legacy_claim_pending = true WHERE id = '00000000-0000-0000-0000-000000000001'")
    op.create_table("email_challenges",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("email", sa.String(320), nullable=False),
        sa.Column("ip_hash", sa.String(64), nullable=False),
        sa.Column("code_hash", sa.String(64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True)),
        sa.Column("delivered", sa.Boolean(), nullable=False))
    for column in ("email", "ip_hash", "created_at"):
        op.create_index(f"ix_email_challenges_{column}", "email_challenges", [column])
    op.create_table("auth_sessions",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("kind IN ('remembered', 'ephemeral')"))
    for column in ("user_id", "expires_at"):
        op.create_index(f"ix_auth_sessions_{column}", "auth_sessions", [column])
    op.create_table("auth_access_tokens",
        sa.Column("token_hash", sa.String(64), primary_key=True),
        sa.Column("session_id", UUID(as_uuid=True), sa.ForeignKey("auth_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False))
    op.create_index("ix_auth_access_tokens_session_id", "auth_access_tokens", ["session_id"])
    op.create_table("auth_renewal_tokens",
        sa.Column("token_hash", sa.String(64), primary_key=True),
        sa.Column("session_id", UUID(as_uuid=True), sa.ForeignKey("auth_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True)),
        sa.Column("request_key_hash", sa.String(64)),
        sa.Column("replay_until", sa.DateTime(timezone=True)))
    op.create_index("ix_auth_renewal_tokens_session_id", "auth_renewal_tokens", ["session_id"])


def downgrade():
    op.drop_table("auth_renewal_tokens")
    op.drop_table("auth_access_tokens")
    op.drop_table("auth_sessions")
    op.drop_table("email_challenges")
    op.drop_column("users", "legacy_claim_pending")
    op.drop_column("users", "email_verified_at")
    op.drop_column("users", "role")
