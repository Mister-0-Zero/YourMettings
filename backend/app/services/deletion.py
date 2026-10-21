"""Transactional deletion policy; callers own the transaction and row locks."""
import hashlib

from sqlalchemy import and_, column, select, table, text

from app.db.models import Summary, Transcript
from app.db.session import TEST_USER_ID


def lock_user_data(db, user_id=TEST_USER_ID):
    # Serialize tree/placement mutations with worker persistence. No LLM call
    # occurs while this transaction-scoped PostgreSQL lock is held.
    key = int.from_bytes(hashlib.sha256(f"yourmettings:{user_id}".encode()).digest()[:8], "big", signed=True)
    db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": key})


def has_external_references(db, transcript_id):
    return has_references(db, "transcripts", [transcript_id], ignored={("audio_sessions", "transcript_id")})


def has_references(db, target, ids, *, ignored=frozenset()):
    # Future sharing/ACL tables must use a FK to transcripts. Conservatively
    # preserve any referenced transcript, including CASCADE references.
    references = db.execute(text("""
        SELECT n.nspname, t.relname, parent_ns.nspname,
               array_agg(a.attname ORDER BY k.position), array_agg(r.attname ORDER BY k.position)
        FROM pg_constraint c
        JOIN pg_class t ON t.oid=c.conrelid
        JOIN pg_namespace n ON n.oid=t.relnamespace
        JOIN pg_class parent ON parent.oid=c.confrelid
        JOIN pg_namespace parent_ns ON parent_ns.oid=parent.relnamespace
        CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS k(src, dst, position)
        JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.src
        JOIN pg_attribute r ON r.attrelid=c.confrelid AND r.attnum=k.dst
        WHERE c.contype='f' AND c.confrelid=to_regclass(:target)
        GROUP BY c.oid, n.nspname, t.relname, parent_ns.nspname
    """), {"target": target})
    for schema, name, target_schema, fields, target_fields in references:
        if schema == target_schema and all((name, field) in ignored for field in fields):
            continue
        referenced = table(name, *(column(field) for field in fields), schema=schema).alias("dependent")
        parent = table(target, *(column(field) for field in dict.fromkeys(["id", *target_fields])),
            schema=target_schema).alias("deleting_parent")
        condition = and_(*(referenced.c[src] == parent.c[dst] for src, dst in zip(fields, target_fields)))
        query = select(parent.c.id).select_from(referenced.join(parent, condition)).where(parent.c.id.in_(ids)).limit(1)
        if db.scalar(query) is not None:
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
    from app.db.audio_models import AudioSession
    audio = db.scalar(select(AudioSession).where(AudioSession.transcript_id == transcript.id))
    if audio is not None and audio.status != "completed":
        return False
    if has_external_references(db, transcript.id):
        # Keep immutable history and a retriable state for external consumers.
        transcript.processing_status = "not_started"
        transcript.error_code = None
        return False
    if audio is not None:
        db.delete(audio)  # Completed audio metadata must not pin deleted meetings.
        db.flush()
    db.delete(transcript)
    db.flush()
    return True
