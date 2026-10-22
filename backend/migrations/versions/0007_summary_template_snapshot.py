"""Preserve generation provenance independently from the editable catalog."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("summaries", sa.Column("template_snapshot", JSONB(), nullable=True))


def downgrade():
    op.drop_column("summaries", "template_snapshot")
