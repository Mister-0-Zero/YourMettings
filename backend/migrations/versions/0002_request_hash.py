"""Persist the original combined creation request fingerprint."""
from alembic import op
import sqlalchemy as sa

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("transcripts", sa.Column("request_hash", sa.String(64), nullable=True))


def downgrade():
    op.drop_column("transcripts", "request_hash")
