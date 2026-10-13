"""Transactional deletion policy; callers own the transaction and row locks."""
import hashlib

from sqlalchemy import column, select, table, text

from app.db.models import Summary, Transcript
from app.db.session import TEST_USER_ID


def lock_user_data(db, user_id=TEST_USER_ID):
    # Serialize tree/placement mutations with worker persistence. No LLM call
    # occurs while this transaction-scoped PostgreSQL lock is held.
    key = int.from_bytes(hashlib.sha256(f"yourmettings:{user_id}".encode()).digest()[:8], "big", signed=True)
    db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": key})


def has_external_references(db, transcript_id):
    # Future sharing/ACL tables must use a FK to transcripts. Conservatively
    # preserve any referenced transcript, including CASCADE references.
    references = db.execute(text("""
        SELECT n.nspname, t.relname, a.attname
        FROM pg_constraint c
        JOIN pg_class t ON t.oid=c.conrelid
        JOIN pg_namespace n ON n.oid=t.relnamespace
        CROSS JOIN LATERAL unnest(c.conkey, c.confkey) AS k(src, dst)
        JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.src
        JOIN pg_attribute r ON r.attrelid=c.confrelid AND r.attnum=k.dst
        WHERE c.contype='f' AND c.confrelid='transcripts'::regclass
          AND r.attname='id'
    """))
    for schema, name, field in references:
        referenced = table(name, column(field), schema=schema)
        if db.scalar(select(referenced.c[field]).where(referenced.c[field] == transcript_id).limit(1)) is not None:
            return True
    return False


def cleanup_transcript(db, transcript):
    db.flush()
    if transcript.processing_status == "summarizing":
        return False
    transcript.processing_status = "not_started"
    transcript.error_code = None
    if db.scalar(select(Summary.id).where(Summary.transcript_id == transcript.id).limit(1)) is not None:
        return False
    if has_external_references(db, transcript.id):
        # Keep immutable history and a retriable state for external consumers.
        transcript.processing_status = "not_started"
        transcript.error_code = None
        return False
    db.delete(transcript)
    db.flush()
    return True
