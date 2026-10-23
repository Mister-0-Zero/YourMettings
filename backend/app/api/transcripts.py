import hashlib
import json
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, Header, Response
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.api.dependencies import owned_transcript, validate_folders
from app.api.errors import fail
from app.core.config import settings
from app.db.models import Transcript, Summary
from app.db.audio_models import AudioSession
from app.db.session import TEST_USER_ID, get_db
from app.schemas import TranscriptInput, TranscriptOut, ProcessInput, ProcessingOut, CreateProcessInput
from app.integrations.ollama import OllamaGenerator, get_generator
from app.services.processing import processing_response, run_processing
from app.services.deletion import lock_user_data
from sqlalchemy.orm import sessionmaker

router = APIRouter(prefix="/transcripts", tags=["transcripts"])


def transcript_response(item, db):
    from app.services.variants import source_has_open_selection
    return TranscriptOut(id=item.id, text=item.text, created_at=item.created_at,
        is_locked=item.first_processed_at is not None or item.processing_status == "summarizing" or source_has_open_selection(db, item.id))


def check_size(text):
    if len(text) > settings.max_transcript_chars:
        fail(413, "text_too_large", "Текст превышает установленный лимит.")


@router.post("", response_model=TranscriptOut, status_code=201)
def create_transcript(body: TranscriptInput, response: Response,
    idempotency_key: Annotated[str | None, Header(min_length=1, max_length=128)] = None,
    db: Session = Depends(get_db)):
    check_size(body.text)
    digest = hashlib.sha256(body.text.encode("utf-8")).hexdigest()
    if idempotency_key is not None:
        stmt = insert(Transcript).values(owner_user_id=TEST_USER_ID, text=body.text,
            idempotency_key=idempotency_key, source_hash=digest,
            processing_status="not_started", processing_attempt=0).on_conflict_do_nothing(
                index_elements=[Transcript.owner_user_id, Transcript.idempotency_key]).returning(Transcript)
        item = db.scalar(stmt)
        if item is None:
            item = db.scalar(select(Transcript).where(
                Transcript.owner_user_id == TEST_USER_ID, Transcript.idempotency_key == idempotency_key))
            if item.request_hash is not None or item.source_hash != digest:
                fail(409, "idempotency_conflict", "Ключ уже использован для другого текста.")
            response.status_code = 200
    else:
        item = Transcript(owner_user_id=TEST_USER_ID, text=body.text, source_hash=digest)
        db.add(item)
    db.commit()
    return transcript_response(item, db)


def accept_processing(db, item, body, generator):
    from app.services.variants import guard_source_selection
    guard_source_selection(db, item.id)
    validate_folders(db, body.folder_ids)
    if isinstance(generator, OllamaGenerator) and not generator.model:
        fail(503, "llm_not_configured", "На сервере не задан тег модели.")
    item.processing_status = "summarizing"
    item.processing_title = body.title
    item.processing_folder_ids = body.folder_ids
    from app.services.template_catalog import resolve_template_snapshot
    item.processing_options = {**body.generation_options(),
        "template_snapshot": resolve_template_snapshot(db, body.template_id)}
    item.processing_attempt += 1
    item.error_code = None


def commit_and_schedule(db, item, tasks, generator):
    db.flush()
    id, attempt = item.id, item.processing_attempt
    # Text and accepted parameters become durable together, before scheduling.
    db.commit()
    result = processing_response(db, item)
    db.commit()  # Release the response read transaction before the model call.
    factory = sessionmaker(db.get_bind(), expire_on_commit=False)
    tasks.add_task(run_processing, factory, id, attempt, generator)
    return result


@router.post("/process", response_model=ProcessingOut, status_code=202,
    summary="Create a meeting and start processing (recommended for Flutter)",
    responses={404: {"description": "Folder not found or inaccessible"},
        409: {"description": "Idempotency key conflicts with original parameters"},
        413: {"description": "Transcript exceeds the configured size limit"},
        503: {"description": "Database unavailable or model not configured"},
        500: {"description": "Unexpected server error"}})
def create_and_process(body: CreateProcessInput, tasks: BackgroundTasks,
    idempotency_key: Annotated[str | None, Header(min_length=1, max_length=128)] = None,
    db: Session = Depends(get_db), generator=Depends(get_generator)):
    check_size(body.text)
    lock_user_data(db)
    source_hash = hashlib.sha256(body.text.encode("utf-8")).hexdigest()
    parameters = {"text": body.text, "title": body.title,
        "folder_ids": sorted(str(id) for id in body.folder_ids)}
    options = body.generation_options()
    # Preserve fingerprints accepted before optional generation settings existed.
    if options != {"detail_level": "normal", "focus_areas": [], "additional_instructions": ""}:
        parameters["generation_options"] = options
    canonical = json.dumps(parameters, ensure_ascii=False, sort_keys=True)
    request_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    values = dict(owner_user_id=TEST_USER_ID, text=body.text, source_hash=source_hash,
        request_hash=request_hash, idempotency_key=idempotency_key,
        processing_status="not_started", processing_attempt=0)
    if idempotency_key is not None:
        # The unique index serializes concurrent requests with the same key.
        stmt = insert(Transcript).values(**values).on_conflict_do_nothing(
            index_elements=[Transcript.owner_user_id, Transcript.idempotency_key]).returning(Transcript)
        item = db.scalar(stmt)
        if item is None:
            item = db.scalar(select(Transcript).where(Transcript.owner_user_id == TEST_USER_ID,
                Transcript.idempotency_key == idempotency_key))
            if item.request_hash != request_hash:
                fail(409, "idempotency_conflict", "Ключ уже использован для другого запроса.")
            return processing_response(db, item)
    else:
        item = Transcript(**values)
        db.add(item)
    # Validation failure rolls back creation; no orphan transcript is committed.
    accept_processing(db, item, body, generator)
    return commit_and_schedule(db, item, tasks, generator)


@router.get("/{id}", response_model=TranscriptOut)
def get_transcript(id: UUID, db: Session = Depends(get_db)):
    return transcript_response(owned_transcript(db, id), db)


@router.patch("/{id}", response_model=TranscriptOut)
def edit_transcript(id: UUID, body: TranscriptInput, db: Session = Depends(get_db)):
    check_size(body.text)
    lock_user_data(db)
    from app.services.variants import guard_source_selection
    guard_source_selection(db, id)
    item = owned_transcript(db, id, lock=True)
    if item.first_processed_at is not None or item.processing_status == "summarizing":
        fail(409, "transcript_locked", "Транскрипт недоступен для редактирования.")
    item.text = body.text
    db.commit()
    return transcript_response(item, db)


@router.post("/{id}/process", response_model=ProcessingOut, status_code=202)
def process_transcript(id: UUID, body: ProcessInput, response: Response,
    tasks: BackgroundTasks, db: Session = Depends(get_db), generator=Depends(get_generator)):
    lock_user_data(db)
    item = owned_transcript(db, id, lock=True)
    audio = db.scalar(select(AudioSession).where(AudioSession.transcript_id == id))
    if audio is not None and audio.status != "completed":
        fail(409, "audio_review_required", "Подтвердите проверенный текст через аудиосессию перед Qwen.")
    if item.processing_status == "summarizing":
        return processing_response(db, item)
    existing = db.scalar(select(Summary.id).where(Summary.transcript_id == id, Summary.user_id == TEST_USER_ID))
    if existing is not None:
        response.status_code = 200
        return processing_response(db, item)
    accept_processing(db, item, body, generator)
    return commit_and_schedule(db, item, tasks, generator)


@router.get("/{id}/processing", response_model=ProcessingOut)
def get_processing(id: UUID, db: Session = Depends(get_db)):
    return processing_response(db, owned_transcript(db, id))
