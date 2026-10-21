"""Durable session state, deterministic assembly and restart-safe ASR jobs."""
import hashlib
import re
import uuid
from datetime import datetime, timezone

from sqlalchemy import select

from app.api.errors import fail
from app.core.config import settings
from app.db.audio_models import ASRWorkerState, AudioChunk, AudioSession
from app.db.models import Transcript
from app.db.session import TEST_USER_ID
from app.services.processing import processing_response


def owned_session(db, id, lock=False):
    query = select(AudioSession).where(AudioSession.id == id, AudioSession.user_id == TEST_USER_ID)
    item = db.scalar(query.with_for_update() if lock else query)
    if item is None:
        fail(404, "not_found", "Аудиосессия не найдена.")
    return item


def chunk_response(item):
    return {key: getattr(item, key) for key in ("id", "sequence_number", "start_ms", "overlap_ms", "duration_ms", "sha256", "byte_count", "audio_format", "status", "text", "segments", "attempt", "error_code")}


def session_response(db, item):
    chunks = db.scalars(select(AudioChunk).where(AudioChunk.session_id == item.id).order_by(AudioChunk.sequence_number)).all()
    present = {chunk.sequence_number for chunk in chunks}
    worker = db.get(ASRWorkerState, 1)
    worker_status = "offline"
    if worker and (datetime.now(timezone.utc) - worker.heartbeat_at).total_seconds() < 15:
        worker_status = worker.status
    transcript = db.get(Transcript, item.transcript_id) if item.transcript_id else None
    return {"id": item.id, "status": item.status, "recording_closed": item.expected_chunk_count is not None,
        "expected_chunk_count": item.expected_chunk_count, "received_chunk_count": len(chunks),
        "transcribed_chunk_count": sum(chunk.status == "done" for chunk in chunks),
        "missing_sequence_numbers": [i for i in range(item.expected_chunk_count or 0) if i not in present],
        "transcript_id": item.transcript_id,
        "transcript_sha256": hashlib.sha256(transcript.text.encode()).hexdigest() if transcript else None,
        "processing": processing_response(db, transcript).model_dump(mode="json") if transcript else None,
        "parameters": item.request_data, "error_code": item.error_code,
        "boundary_warnings": item.boundary_warnings, "chunks": [chunk_response(c) for c in chunks],
        "worker_status": worker_status, "chunk_target_seconds": settings.audio_chunk_target_seconds,
        "max_chunk_seconds": settings.audio_chunk_max_seconds, "max_upload_bytes": settings.audio_max_upload_bytes,
        "max_overlap_ms": settings.audio_max_overlap_ms, "max_chunks": settings.audio_max_chunks}


def duplicate_chunk(existing, digest, start_ms, overlap_ms):
    if existing.sha256 != digest or existing.start_ms != start_ms or existing.overlap_ms != overlap_ms:
        fail(409, "chunk_conflict", "Этот номер уже принят с другим содержимым или временем.")
    return {"accepted": True, "safe_to_delete_local": True, "chunk": chunk_response(existing)}


def merge_texts(chunks):
    output, warnings = [], []
    previous = None
    for chunk in chunks:
        if previous is None:
            if chunk.start_ms != 0 or chunk.overlap_ms != 0:
                raise ValueError("timeline_mismatch")
        else:
            expected = previous.start_ms + previous.duration_ms - chunk.overlap_ms
            if abs(chunk.start_ms - expected) > 250:
                raise ValueError("timeline_mismatch")
        current = (chunk.text or "").strip()
        if previous is not None and chunk.overlap_ms:
            before = re.findall(r"\w+", "\n".join(output).casefold())
            matches = list(re.finditer(r"\w+", current))
            after = [m.group().casefold() for m in matches]
            limit = min(len(before), len(after), 5 + chunk.overlap_ms // 200)
            found = 0
            for size in range(limit, 1, -1):
                if before[-size:] == after[:size]:
                    found = size
                    break
            if found:
                current = current[matches[found - 1].end():].lstrip(" ,.!?:;—-\n")
            else:
                warnings.append({"sequence_number": chunk.sequence_number, "code": "overlap_not_aligned"})
        if current:
            output.append(current)
        previous = chunk
    return "\n\n".join(output), warnings


def assemble(db, session):
    if session.transcript_id is not None or session.expected_chunk_count is None:
        return
    chunks = db.scalars(select(AudioChunk).where(AudioChunk.session_id == session.id).order_by(AudioChunk.sequence_number)).all()
    if any(c.status == "failed" for c in chunks):
        session.status, session.error_code = "failed", "chunk_failed"
        return
    session.status, session.error_code = "transcribing", None
    if [c.sequence_number for c in chunks] != list(range(session.expected_chunk_count)) or any(c.status != "done" for c in chunks):
        return
    try:
        text, warnings = merge_texts(chunks)
    except ValueError:
        session.status, session.error_code = "failed", "timeline_mismatch"
        return
    if not text or len(text) > settings.max_transcript_chars:
        session.status, session.error_code = "failed", "empty_transcript" if not text else "transcript_too_large"
        return
    transcript = Transcript(owner_user_id=session.user_id, text=text, source_hash=hashlib.sha256(text.encode()).hexdigest())
    db.add(transcript)
    db.flush()
    session.transcript_id = transcript.id
    session.boundary_warnings = warnings
    session.status, session.error_code = "ready_for_review", None


def recover_worker(db, generation, pid):
    """Only call while holding the singleton worker locks."""
    state = db.get(ASRWorkerState, 1)
    if state is None:
        state = ASRWorkerState(id=1)
        db.add(state)
    state.generation, state.pid, state.status = generation, pid, "starting"
    state.model, state.heartbeat_at, state.error_code = "v3_e2e_rnnt", datetime.now(timezone.utc), None
    for chunk in db.scalars(select(AudioChunk).where(AudioChunk.status == "transcribing").with_for_update()):
        chunk.status, chunk.claimed_by, chunk.error_code = "queued", None, None


def claim_chunk(db, generation):
    chunk = db.scalar(select(AudioChunk).where(AudioChunk.status == "queued")
        .order_by(AudioChunk.created_at, AudioChunk.sequence_number).with_for_update(skip_locked=True).limit(1))
    if chunk is None:
        return None
    chunk.status, chunk.claimed_by, chunk.error_code = "transcribing", generation, None
    chunk.attempt += 1
    return {"id": chunk.id, "session_id": chunk.session_id, "attempt": chunk.attempt,
        "payload": chunk.payload, "format": chunk.audio_format}


def finish_chunk(db, job, generation, *, text=None, segments=None, error=None):
    state = db.get(ASRWorkerState, 1)
    session = db.scalar(select(AudioSession).where(AudioSession.id == job["session_id"]).with_for_update())
    chunk = db.scalar(select(AudioChunk).where(AudioChunk.id == job["id"]).with_for_update())
    if not session or not state or state.generation != generation or not chunk or chunk.claimed_by != generation or chunk.attempt != job["attempt"] or chunk.status != "transcribing":
        return False
    if error:
        chunk.status, chunk.error_code = "failed", error
        if session.expected_chunk_count is not None:
            session.status, session.error_code = "failed", "chunk_failed"
    else:
        chunk.status, chunk.text, chunk.segments = "done", text or "", segments or []
        # Text/segments and removal of the durable payload commit together.
        chunk.payload, chunk.error_code = None, None
    db.flush()
    assemble(db, session)
    return True
