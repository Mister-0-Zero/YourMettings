"""Per-operation generation preferences, preserving existing transcripts."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("transcripts", sa.Column("processing_options", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")))


def downgrade():
    op.drop_column("transcripts", "processing_options")
