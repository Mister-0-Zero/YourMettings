import hashlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, Header, Query, Response
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from app.api.dependencies import owned_summary, owned_transcript, validate_folders
from app.api.errors import fail
from app.db.audio_models import AudioSession
from app.db.models import Summary, SummaryFolder, Transcript
from app.db.session import current_user_id, get_db
from app.db.variant_models import SummarySelection, SummaryCandidate, CandidateRequest
from app.integrations.ollama import get_generator
from app.schemas import SummaryOut
from app.services.deletion import lock_user_data
from app.services.long_generation import validate_long_input, LongInputError
from app.services.template_catalog import resolve_template_snapshot
from app.services.variants import (SELECTION_TTL, MAX_CANDIDATES, now, fingerprint, summary_version,
    expire_selections, owned_selection, require_open, guard_source_selection, clear_selection,
    selection_response, candidate_response, check_capacity, run_candidate)
from app.variant_schemas import SelectionInput, CandidateInput, CandidateOut, SelectionOut, AcceptCandidate

router = APIRouter(tags=["summary variants"], responses={
    404: {"description": "Resource unknown or inaccessible"},
    409: {"description": "Conflicting operation, source or document version; candidate not ready"},
    410: {"description": "Selection cancelled/expired or candidate payload discarded"},
    413: {"description": "Source exceeds explicit character, word or UTF-8 byte limit"},
    429: {"description": "Selection or generation capacity exhausted"},
    503: {"description": "Database unavailable"}})
OperationKey = Annotated[str, Header(min_length=1, max_length=128, alias="Idempotency-Key")]


def prepare(db):
    expire_selections(db)
    db.commit()  # Expiration cleanup must survive even if the requested operation fails.
    lock_user_data(db)


def validate_source(text):
    try:
        validate_long_input(text)
    except LongInputError:
        fail(413, "source_too_large", "Лимит: 15000 слов, 200000 символов и 400000 байт UTF-8.")


def meeting_session(db, id, *, lock=False):
    item = owned_selection(db, id, lock=lock)
    if item.kind != "meeting":
        fail(404, "not_found", "Сессия выбора встречи не найдена.")
    return item


@router.post("/summary-selections", response_model=SelectionOut, status_code=201)
def create_selection(body: SelectionInput, response: Response, idempotency_key: OperationKey,
    db: Session = Depends(get_db)):
    prepare(db)
    parameters = body.model_dump(mode="json")
    parameters["folder_ids"] = sorted(parameters["folder_ids"])
    request_hash = fingerprint(parameters)
    key = "meeting:" + idempotency_key
    existing = db.scalar(select(SummarySelection).where(SummarySelection.user_id == current_user_id(db),
        SummarySelection.idempotency_key == key))
    if existing:
        if existing.request_hash != request_hash:
            fail(409, "idempotency_conflict", "Ключ уже использован для другой сессии выбора.")
        if existing.status in ("cancelled", "expired"):
            fail(410, "selection_closed", "Сессия намеренно завершена или истекла; старый ключ не создаёт её повторно.")
        response.status_code = 200
        result = selection_response(db, existing)
        db.commit()
        return result
    if db.scalar(select(func.count()).select_from(SummarySelection).where(
        SummarySelection.user_id == current_user_id(db), SummarySelection.status == "open", SummarySelection.kind == "meeting")) >= 10:
        fail(429, "selection_limit", "Завершите одну из открытых сессий выбора.")
    target = None
    owns_source = body.text is not None
    if body.summary_id is not None:
        target = owned_summary(db, body.summary_id, lock=True)
        source = owned_transcript(db, target.transcript_id, lock=True)
    elif body.audio_session_id is not None:
        audio = db.scalar(select(AudioSession).where(AudioSession.id == body.audio_session_id,
            AudioSession.user_id == current_user_id(db)).with_for_update())
        if audio is None:
            fail(404, "not_found", "Аудиосессия не найдена.")
        if audio.status != "ready_for_review" or audio.transcript_id is None:
            fail(409, "transcript_not_ready", "Для сохранённой встречи используйте summary_id; для новой дождитесь проверки ASR.")
        source = owned_transcript(db, audio.transcript_id, lock=True)
        if not body.confirm:
            fail(422, "confirmation_required", "Подтвердите проверенный транскрипт.")
        if body.reviewed_text_sha256 != hashlib.sha256(source.text.encode()).hexdigest():
            fail(409, "review_outdated", "Перечитайте текущий проверяемый транскрипт.")
        if audio.boundary_warnings and not body.boundaries_reviewed:
            fail(409, "boundary_review_required", "Проверьте границы фрагментов.")
    elif body.transcript_id is not None:
        source = owned_transcript(db, body.transcript_id, lock=True)
        if db.scalar(select(AudioSession.id).where(AudioSession.transcript_id == source.id)):
            fail(409, "audio_review_required", "Для аудио используйте audio_session_id с подтверждением проверки.")
    else:
        validate_source(body.text)
        source = Transcript(owner_user_id=current_user_id(db), text=body.text,
            source_hash=hashlib.sha256(body.text.encode()).hexdigest())
        db.add(source)
        db.flush()
    validate_source(source.text)
    if source.processing_status == "summarizing":
        fail(409, "processing_in_progress", "Дождитесь текущей обработки источника.")
    if target is None:
        if db.scalar(select(Summary.id).where(Summary.transcript_id == source.id)):
            fail(409, "summary_exists", "Встреча уже сохранена; откройте выбор по summary_id.")
        guard_source_selection(db, source.id)
        validate_folders(db, body.folder_ids)
    item = SummarySelection(user_id=current_user_id(db), kind="meeting", idempotency_key=key,
        request_hash=request_hash, transcript_id=source.id, source_transcript_id=source.id,
        source_text=source.text, source_hash=hashlib.sha256(source.text.encode()).hexdigest(),
        summary_id=target.id if target else None, base_version=summary_version(target) if target else None,
        title=body.title, folder_ids=body.folder_ids, owns_transcript=owns_source, expires_at=now()+SELECTION_TTL)
    db.add(item)
    db.flush()
    result = selection_response(db, item)
    db.commit()
    return result


@router.get("/summary-selections/{id}", response_model=SelectionOut)
def get_selection(id: UUID, db: Session = Depends(get_db)):
    prepare(db)
    result = selection_response(db, meeting_session(db, id))
    db.commit()
    return result


def accept_candidate_request(db, item, body, key):
    params = body.model_dump(mode="json")
    params["focus_areas"] = sorted(params["focus_areas"])
    request_hash = fingerprint(params)
    previous = db.get(CandidateRequest, (item.id, key))
    if previous:
        if previous.request_hash != request_hash:
            fail(409, "idempotency_conflict", "Ключ уже использован с другими параметрами кандидата.")
        candidate = db.get(SummaryCandidate, previous.candidate_id)
        if candidate.status in ("expired", "discarded"):
            fail(410, "candidate_expired", "Этот кандидат уже очищен.")
        return candidate, False
    require_open(item)
    options = body.generation_options()
    if body.template_id is not None:
        options["template_id"] = str(body.template_id)
    options["template_snapshot"] = resolve_template_snapshot(db, body.template_id)
    generation_hash = fingerprint(options)
    candidate = db.scalar(select(SummaryCandidate).where(SummaryCandidate.selection_id == item.id,
        SummaryCandidate.generation_hash == generation_hash,
        SummaryCandidate.status.in_(["queued", "generating", "ready"])).order_by(SummaryCandidate.created_at).limit(1))
    created = candidate is None
    if created:
        check_capacity(db)
        if db.scalar(select(func.count()).select_from(SummaryCandidate).where(SummaryCandidate.selection_id == item.id)) >= MAX_CANDIDATES:
            fail(409, "candidate_limit", "В сессии допускается не более 12 запусков. Завершите или отмените выбор.")
        candidate = SummaryCandidate(selection_id=item.id, generation_hash=generation_hash, options=options)
        db.add(candidate)
        db.flush()
    db.add(CandidateRequest(selection_id=item.id, key=key, request_hash=request_hash, candidate_id=candidate.id))
    return candidate, created


@router.post("/summary-selections/{id}/candidates", response_model=CandidateOut, status_code=202)
def create_candidate(id: UUID, body: CandidateInput, tasks: BackgroundTasks,
    idempotency_key: OperationKey, db: Session = Depends(get_db), generator=Depends(get_generator)):
    prepare(db)
    item = meeting_session(db, id, lock=True)
    candidate, created = accept_candidate_request(db, item, body, idempotency_key)
    db.flush()
    result = candidate_response(candidate, item)
    db.commit()
    if created:
        tasks.add_task(run_candidate, sessionmaker(db.get_bind(), expire_on_commit=False), candidate.id, generator)
    return result


@router.get("/summary-candidates/{id}", response_model=CandidateOut)
def get_candidate(id: UUID, db: Session = Depends(get_db)):
    prepare(db)
    candidate = db.get(SummaryCandidate, id)
    if candidate is None:
        fail(404, "not_found", "Кандидат не найден.")
    item = meeting_session(db, candidate.selection_id)
    if candidate.status in ("discarded", "expired"):
        fail(410, "candidate_expired", "Кандидат очищен после завершения выбора.")
    result = candidate_response(candidate, item)
    db.commit()
    return result


@router.post("/summary-selections/{id}/accept", response_model=SummaryOut)
def accept_selection(id: UUID, body: AcceptCandidate, db: Session = Depends(get_db)):
    from app.api.summaries import summary_response
    prepare(db)
    item = meeting_session(db, id, lock=True)
    if item.status == "accepted":
        if item.accepted_candidate_id != body.candidate_id:
            fail(409, "selection_closed", "Уже принят другой кандидат.")
        result = SummaryOut.model_validate(item.accepted_response)
        db.commit()
        return result
    require_open(item)
    candidate = db.get(SummaryCandidate, body.candidate_id)
    if candidate is None or candidate.selection_id != item.id:
        fail(404, "not_found", "Кандидат не принадлежит этой сессии.")
    if candidate.status != "ready":
        fail(409, "candidate_not_ready", "Кандидат ещё не готов.")
    source = owned_transcript(db, item.transcript_id, lock=True)
    if hashlib.sha256(source.text.encode()).hexdigest() != item.source_hash:
        fail(409, "source_conflict", "Исходный текст изменился; откройте новую сессию.")
    existing_target = item.summary_id is not None
    if item.summary_id:
        result = owned_summary(db, item.summary_id, lock=True)
        if body.expected_version != item.base_version or summary_version(result) != item.base_version:
            fail(409, "summary_version_conflict", "Сохранённый документ изменён. Перечитайте его и откройте новую сессию.")
    else:
        if body.expected_version is not None:
            fail(409, "summary_version_conflict", "У новой встречи нет предыдущей версии.")
        if db.scalar(select(Summary.id).where(Summary.transcript_id == source.id)):
            fail(409, "summary_version_conflict", "Для источника уже сохранён результат.")
        validate_folders(db, item.folder_ids)
        result = Summary(user_id=current_user_id(db), transcript_id=source.id, title=item.title, content=candidate.content)
        db.add(result)
        db.flush()
        db.add_all(SummaryFolder(summary_id=result.id, folder_id=fid) for fid in item.folder_ids)
        item.summary_id = result.id
    if existing_target:
        result.content_revision += 1
    result.content = candidate.content
    result.template_snapshot = candidate.options["template_snapshot"]
    result.generation_options = {k: v for k, v in candidate.options.items() if k != "template_snapshot"}
    result.updated_at = func.now()
    source.processing_status, source.error_code = "ready", None
    source.first_processed_at = source.first_processed_at or now()
    audio = db.scalar(select(AudioSession).where(AudioSession.transcript_id == source.id).with_for_update())
    if audio:
        audio.status = "completed"
    db.flush()
    response = summary_response(db, result)
    item.accepted_candidate_id = candidate.id
    item.accepted_response = response.model_dump(mode="json")
    clear_selection(db, item, "accepted", selected_id=candidate.id)
    db.commit()
    return response


@router.delete("/summary-selections/{id}", status_code=204)
def cancel_selection(id: UUID, confirm: bool = Query(False), db: Session = Depends(get_db)):
    if not confirm:
        fail(422, "confirmation_required", "Подтвердите отмену выбора. Сохранённая встреча не удаляется.")
    prepare(db)
    item = meeting_session(db, id, lock=True)
    if item.status == "accepted":
        fail(409, "selection_closed", "Принятый результат нельзя отменить этим endpoint.")
    if item.status == "open":
        clear_selection(db, item, "cancelled")
    db.commit()
    return Response(status_code=204)
