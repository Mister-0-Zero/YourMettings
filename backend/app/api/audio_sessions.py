import hashlib
import json
import tempfile
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, Header, Query, Request, Response
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker
from starlette.concurrency import run_in_threadpool

from app.api.dependencies import owned_transcript, validate_folders
from app.api.errors import fail
from app.api.transcripts import accept_processing, commit_and_schedule
from app.audio_schemas import AudioSessionInput, AudioComplete, AudioConfirm, AudioRetry, AudioSessionOut, AudioChunkAccepted
from app.core.config import settings
from app.db.audio_models import AudioChunk, AudioSession
from app.db.session import TEST_USER_ID, get_db
from app.integrations.ollama import get_generator
from app.schemas import ProcessingOut
from app.services.audio import owned_session, session_response, duplicate_chunk, chunk_response, assemble
from app.services.audio_validation import validate_audio
from app.services.deletion import lock_user_data
from app.services.processing import processing_response

router = APIRouter(prefix="/audio-sessions", tags=["audio sessions"])


@router.post("", status_code=201, response_model=AudioSessionOut)
def create(body: AudioSessionInput, response: Response,
    idempotency_key: Annotated[str | None, Header(min_length=1, max_length=128)] = None,
    db: Session = Depends(get_db)):
    lock_user_data(db)
    params = body.model_dump(mode="json")
    canonical = {**params, "folder_ids": sorted(params["folder_ids"]), "focus_areas": sorted(params["focus_areas"])}
    digest = hashlib.sha256(json.dumps(canonical, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    if idempotency_key:
        existing = db.scalar(select(AudioSession).where(AudioSession.user_id == TEST_USER_ID, AudioSession.idempotency_key == idempotency_key))
        if existing:
            if existing.request_hash != digest:
                fail(409, "idempotency_conflict", "Ключ аудиосессии уже использован для других параметров.")
            response.status_code = 200
            return session_response(db, existing)
    validate_folders(db, body.folder_ids)
    item = AudioSession(user_id=TEST_USER_ID, request_data=params, request_hash=digest, idempotency_key=idempotency_key)
    db.add(item)
    db.commit()
    return session_response(db, item)


@router.get("/{id}", response_model=AudioSessionOut)
def get_session(id: UUID, db: Session = Depends(get_db)):
    return session_response(db, owned_session(db, id))


@router.post("/{id}/chunks", response_model=AudioChunkAccepted, status_code=201,
    openapi_extra={"requestBody": {"required": True, "content": {
        "application/octet-stream": {"schema": {"type": "string", "format": "binary"}}}}})
async def upload(id: UUID, request: Request, response: Response,
    sequence_number: int = Query(ge=0, le=239), start_ms: int = Query(ge=0, le=2_000_000_000),
    overlap_ms: int = Query(0, ge=0, le=10000), duration_ms: int | None = Query(None, gt=0),
    content_sha256: str | None = Query(None, pattern="^[0-9a-f]{64}$"), db: Session = Depends(get_db)):
    factory = sessionmaker(db.get_bind(), expire_on_commit=False)
    def check_owner():
        with factory() as session:
            owned_session(session, id)
    await run_in_threadpool(check_owner)
    if sequence_number >= settings.audio_max_chunks or overlap_ms > settings.audio_max_overlap_ms:
        fail(422, "invalid_chunk_parameters", "Номер фрагмента или перекрытие превышает лимит.")
    size = 0
    # Interrupted uploads never create queue records. This staging file is not
    # the source of durability: only the committed BYTEA + metadata are acknowledged.
    with tempfile.TemporaryFile(prefix="yourmettings-upload-") as file:
        async for part in request.stream():
            size += len(part)
            if size > settings.audio_max_upload_bytes:
                fail(413, "audio_too_large", "Аудиофрагмент превышает лимит размера.")
            file.write(part)
        file.seek(0)
        data = file.read()
    digest = hashlib.sha256(data).hexdigest()
    if content_sha256 is not None and digest != content_sha256:
        fail(422, "checksum_mismatch", "SHA256 не совпадает с полученным содержимым.")
    fmt, actual_ms = await run_in_threadpool(validate_audio, data)
    if duration_ms is not None and abs(duration_ms - actual_ms) > 250:
        fail(422, "duration_mismatch", "Заявленная длительность не совпадает с декодированным аудио.")
    def persist():
        with factory.begin() as session:
            lock_user_data(session)
            item = owned_session(session, id, lock=True)
            existing = session.scalar(select(AudioChunk).where(AudioChunk.session_id == id, AudioChunk.sequence_number == sequence_number))
            if existing:
                return duplicate_chunk(existing, digest, start_ms, overlap_ms), True
            if item.transcript_id or item.status == "completed":
                fail(409, "session_closed", "Итоговый транскрипт уже собран.")
            if item.expected_chunk_count is not None and sequence_number >= item.expected_chunk_count:
                fail(409, "unexpected_chunk", "Номер не входит в заявленное количество фрагментов.")
            chunk = AudioChunk(session_id=id, sequence_number=sequence_number, start_ms=start_ms, overlap_ms=overlap_ms,
                duration_ms=actual_ms, sha256=digest, byte_count=size, audio_format=fmt, payload=data)
            session.add(chunk)
            session.flush()
            return {"accepted": True, "safe_to_delete_local": True, "chunk": chunk_response(chunk)}, False
    result, duplicate = await run_in_threadpool(persist)
    if duplicate:
        response.status_code = 200
    return result


@router.post("/{id}/complete", response_model=AudioSessionOut, status_code=202)
def complete(id: UUID, body: AudioComplete, db: Session = Depends(get_db)):
    lock_user_data(db)
    item = owned_session(db, id, lock=True)
    if body.expected_chunk_count > settings.audio_max_chunks:
        fail(422, "invalid_chunk_count", "Превышен лимит фрагментов.")
    if item.expected_chunk_count is not None and item.expected_chunk_count != body.expected_chunk_count:
        fail(409, "chunk_count_conflict", "Завершение уже принято с другим количеством фрагментов.")
    maximum = db.scalar(select(AudioChunk.sequence_number).where(AudioChunk.session_id == id).order_by(AudioChunk.sequence_number.desc()).limit(1))
    if maximum is not None and maximum >= body.expected_chunk_count:
        fail(409, "chunk_count_conflict", "Уже приняты фрагменты за пределами заявленного количества.")
    item.expected_chunk_count = body.expected_chunk_count
    assemble(db, item)
    db.commit()
    return session_response(db, item)


@router.post("/{id}/retry", response_model=AudioSessionOut)
def retry(id: UUID, body: AudioRetry, db: Session = Depends(get_db)):
    lock_user_data(db)
    item = owned_session(db, id, lock=True)
    if item.transcript_id is not None:
        return session_response(db, item)
    chunks = db.scalars(select(AudioChunk).where(AudioChunk.session_id == id)).all()
    if body.sequence_numbers is not None and not set(body.sequence_numbers).issubset({c.sequence_number for c in chunks}):
        fail(404, "not_found", "Запрошенный фрагмент ещё не загружен.")
    for chunk in chunks:
        if body.sequence_numbers is not None and chunk.sequence_number not in body.sequence_numbers:
            continue
        if chunk.status == "failed":
            if chunk.payload is None:
                fail(409, "audio_unavailable", "Исходное аудио отсутствует; повтор невозможен.")
            chunk.status, chunk.error_code, chunk.claimed_by = "queued", None, None
    db.flush()
    item.status, item.error_code = "recording" if item.expected_chunk_count is None else "transcribing", None
    assemble(db, item)
    db.commit()
    return session_response(db, item)


@router.post("/{id}/confirm", response_model=ProcessingOut, status_code=202)
def confirm(id: UUID, body: AudioConfirm, tasks: BackgroundTasks, response: Response,
    db: Session = Depends(get_db), generator=Depends(get_generator)):
    if not body.confirm:
        fail(422, "confirmation_required", "Подтвердите проверку итогового транскрипта.")
    lock_user_data(db)
    item = owned_session(db, id, lock=True)
    if item.transcript_id is None:
        fail(409, "transcript_not_ready", "Все фрагменты ещё не распознаны и не собраны.")
    transcript = owned_transcript(db, item.transcript_id, lock=True)
    if item.status == "completed":
        response.status_code = 200
        return processing_response(db, transcript)
    if hashlib.sha256(transcript.text.encode()).hexdigest() != body.reviewed_text_sha256:
        fail(409, "review_outdated", "Текст изменился после просмотра; перечитайте транскрипт.")
    if item.boundary_warnings and not body.boundaries_reviewed:
        fail(409, "boundary_review_required", "Проверьте и при необходимости исправьте границы фрагментов.")
    item.status = "completed"
    item.request_data = {key: value for key, value in body.model_dump(mode="json").items()
        if key not in ("confirm", "reviewed_text_sha256", "boundaries_reviewed")}
    accept_processing(db, transcript, body, generator)
    return commit_and_schedule(db, transcript, tasks, generator)
