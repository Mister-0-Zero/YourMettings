"""Persist atomic edited-accept identity without changing historical receipts."""
from alembic import op
import sqlalchemy as sa

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("summary_selections", sa.Column("accepted_request_hash", sa.String(64), nullable=True))


def downgrade():
    op.drop_column("summary_selections", "accepted_request_hash")
