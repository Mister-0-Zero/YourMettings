"""Durable candidate selection, operation receipts and generation provenance."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("summaries", sa.Column("generation_options", JSONB(), nullable=True))
    op.add_column("summaries", sa.Column("content_revision", sa.Integer(), nullable=False, server_default="1"))
    op.create_table("summary_selections",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("idempotency_key", sa.String(160), nullable=False),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("transcript_id", UUID(as_uuid=True), sa.ForeignKey("transcripts.id", ondelete="CASCADE")),
        sa.Column("source_transcript_id", UUID(as_uuid=True)),
        sa.Column("summary_id", UUID(as_uuid=True), sa.ForeignKey("summaries.id", ondelete="SET NULL")),
        sa.Column("owns_transcript", sa.Boolean(), nullable=False),
        sa.Column("source_text", sa.Text()),
        sa.Column("source_hash", sa.String(64), nullable=False),
        sa.Column("title", sa.String(200)),
        sa.Column("folder_ids", ARRAY(UUID(as_uuid=True)), nullable=False),
        sa.Column("base_version", sa.String(64)),
        sa.Column("accepted_candidate_id", UUID(as_uuid=True)),
        sa.Column("accepted_response", JSONB()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "idempotency_key"),
        sa.CheckConstraint("kind IN ('meeting','preview')"),
        sa.CheckConstraint("status IN ('open','accepted','cancelled','expired')"))
    for field in ("user_id", "transcript_id", "summary_id", "expires_at"):
        op.create_index(f"ix_summary_selections_{field}", "summary_selections", [field])
    op.create_table("summary_candidates",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("selection_id", UUID(as_uuid=True), sa.ForeignKey("summary_selections.id", ondelete="CASCADE"), nullable=False),
        sa.Column("generation_hash", sa.String(64), nullable=False),
        sa.Column("options", JSONB()),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("attempt", sa.Integer(), nullable=False),
        sa.Column("content", sa.Text()),
        sa.Column("error_code", sa.String(64)),
        sa.Column("processing_metadata", JSONB(), nullable=False, server_default="{}"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("status IN ('queued','generating','ready','error','discarded','expired')"))
    op.create_index("ix_summary_candidates_selection_id", "summary_candidates", ["selection_id"])
    op.create_table("candidate_requests",
        sa.Column("selection_id", UUID(as_uuid=True), sa.ForeignKey("summary_selections.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("key", sa.String(128), primary_key=True),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("candidate_id", UUID(as_uuid=True), sa.ForeignKey("summary_candidates.id", ondelete="CASCADE"), nullable=False))
    op.create_index("ix_candidate_requests_candidate_id", "candidate_requests", ["candidate_id"])

    # Wipe private technical copies on every deletion path, while retaining
    # tiny operation receipts so a delayed POST cannot recreate a deleted meeting.
    op.execute("""
        CREATE FUNCTION ym_clear_summary_variants() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
            UPDATE summary_candidates SET status='discarded', content=NULL, options=NULL, processing_metadata='{}', error_code=NULL
            WHERE selection_id IN (SELECT id FROM summary_selections WHERE summary_id=OLD.id);
            UPDATE summary_selections SET status='cancelled', source_text=NULL, transcript_id=NULL,
                summary_id=NULL, title=NULL, folder_ids='{}', accepted_candidate_id=NULL, accepted_response=NULL
            WHERE summary_id=OLD.id;
            RETURN OLD;
        END;
        $$
    """)
    op.execute("CREATE TRIGGER ym_summary_variants_before_delete BEFORE DELETE ON summaries "
        "FOR EACH ROW EXECUTE FUNCTION ym_clear_summary_variants()")


def downgrade():
    op.execute("DROP TRIGGER IF EXISTS ym_summary_variants_before_delete ON summaries")
    op.execute("DROP FUNCTION IF EXISTS ym_clear_summary_variants()")
    op.drop_table("candidate_requests")
    op.drop_table("summary_candidates")
    op.drop_table("summary_selections")
    op.drop_column("summaries", "content_revision")
    op.drop_column("summaries", "generation_options")
