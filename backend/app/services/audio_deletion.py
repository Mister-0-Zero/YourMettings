"""Deletion policy and upload guard; no LLM or filesystem source of truth."""
import hashlib
from uuid import UUID

from anyio import CancelScope
from fastapi import Depends
from sqlalchemy import select, text
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from app.api.errors import fail
from app.db.audio_models import AudioChunk, AudioSession, AudioSessionDeletion
from app.db.models import Transcript
from app.db.session import TEST_USER_ID, get_db
from app.services.audio_files import cleanup_session_files
from app.services.deletion import has_external_references, has_references, lock_user_data


def upload_lock_key(session_id):
    return int.from_bytes(hashlib.sha256(f"ym-audio-upload:{session_id}".encode()).digest()[:8], "big", signed=True)


async def guard_audio_upload(id: UUID, db: Session = Depends(get_db)):
    """Shared session lock spans HTTP staging/validation, but no DB transaction."""
    connection = await run_in_threadpool(db.get_bind().connect)
    key = upload_lock_key(id)
    def acquire():
        connection.execute(text("SELECT pg_advisory_lock_shared(:key)"), {"key": key})
        connection.commit()
    def release():
        try:
            connection.execute(text("SELECT pg_advisory_unlock_shared(:key)"), {"key": key})
            connection.commit()
        except Exception:
            connection.invalidate()  # Never return a possibly locked connection to the pool.
            raise
        finally:
            connection.close()
    try:
        await run_in_threadpool(acquire)
        yield
    finally:
        with CancelScope(shield=True):
            await run_in_threadpool(release)


def delete_unconfirmed_session(db, session_id, *, confirm):
    if not confirm:
        fail(422, "confirmation_required", "Подтвердите удаление аудиовстречи.")
    lock_user_data(db)
    receipt = db.scalar(select(AudioSessionDeletion).where(
        AudioSessionDeletion.session_id == session_id, AudioSessionDeletion.user_id == TEST_USER_ID))
    if receipt is not None:
        return
    item = db.scalar(select(AudioSession).where(AudioSession.id == session_id,
        AudioSession.user_id == TEST_USER_ID).with_for_update())
    if item is None:
        fail(404, "not_found", "Аудиосессия не найдена.")
    if item.status != "ready_for_review":
        fail(409, "audio_session_not_deletable", "Удаление доступно только после ASR и до подтверждения Qwen.")
    if not db.scalar(text("SELECT pg_try_advisory_xact_lock(:key)"), {"key": upload_lock_key(session_id)}):
        fail(409, "audio_session_busy", "Дождитесь завершения загрузки фрагмента и повторите удаление.")
    source = db.scalar(select(Transcript).where(Transcript.id == item.transcript_id).with_for_update())
    chunks = list(db.scalars(select(AudioChunk).where(AudioChunk.session_id == session_id)
        .order_by(AudioChunk.sequence_number).with_for_update()))
    if (source is None or source.owner_user_id != TEST_USER_ID or source.processing_status != "not_started"
        or source.processing_attempt != 0 or source.first_processed_at is not None
        or source.idempotency_key is not None or source.request_hash is not None
        or not item.expected_chunk_count or len(chunks) != item.expected_chunk_count
        or [c.sequence_number for c in chunks] != list(range(item.expected_chunk_count))
        or any(c.status != "done" for c in chunks)):
        fail(409, "audio_session_not_deletable", "Сессия или её транскрипт ещё используются обработкой.")
    if (has_external_references(db, source.id)
        or has_references(db, "audio_sessions", [session_id], ignored={("audio_chunks", "session_id")})
        or has_references(db, "audio_chunks", [c.id for c in chunks])):
        fail(409, "audio_session_in_use", "Сессию, фрагменты или транскрипт используют другие данные.")
    try:
        cleanup_session_files(session_id)
    except (OSError, RuntimeError):
        fail(409, "audio_cleanup_failed", "Не удалось безопасно очистить рабочие копии аудио; повторите позже.")
    db.add(AudioSessionDeletion(session_id=item.id, user_id=item.user_id,
        idempotency_key=item.idempotency_key, request_hash=item.request_hash))
    db.delete(item)  # PostgreSQL cascades chunks, their payloads and ASR job state.
    db.flush()
    db.delete(source)
    db.flush()
