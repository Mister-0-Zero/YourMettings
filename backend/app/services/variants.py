"""Candidate lifecycle. All mutations use the existing user lock; model work never holds a transaction."""
import hashlib
import json
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select, update

from app.api.errors import fail
from app.core.config import settings
from app.db.models import Transcript
from app.db.session import current_user_id
from app.db.variant_models import SummarySelection, SummaryCandidate
from app.integrations.ollama import LLMError
from app.schemas import ProcessingError
from app.services.deletion import lock_user_data, cleanup_transcript
from app.services.gpu import gpu_slot
from app.services.long_generation import generate_long
from app.services.processing import ERROR_MESSAGES
from app.services.template_rendering import navigation
from app.variant_schemas import SelectionOut, CandidateOut

SELECTION_TTL = timedelta(hours=24)
PREVIEW_TTL = timedelta(hours=1)
JOB_DEADLINE = timedelta(minutes=30)
MAX_ACTIVE_JOBS = 2
MAX_CANDIDATES = 12


def now():
    return datetime.now(timezone.utc)


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, default=str).encode()).hexdigest()


def summary_version(item):
    return fingerprint({"id": str(item.id), "title": item.title, "content": item.content,
        "template_snapshot": item.template_snapshot, "generation_options": item.generation_options,
        "content_revision": item.content_revision})


def clear_selection(db, item, status, *, selected_id=None):
    """Keep operation/key tombstones, remove source and unchosen result payloads."""
    source = db.get(Transcript, item.transcript_id) if item.transcript_id else None
    for candidate in db.scalars(select(SummaryCandidate).where(SummaryCandidate.selection_id == item.id)):
        if candidate.id != selected_id:
            candidate.status = "expired" if status == "expired" else "discarded"
            candidate.content = None
            candidate.options = None
            candidate.processing_metadata = {}
            candidate.error_code = None
    item.status = status
    item.source_text = None
    item.transcript_id = None
    if status != "accepted":
        item.title = None
        item.folder_ids = []
    db.flush()
    if item.owns_transcript and source is not None and status != "accepted":
        cleanup_transcript(db, source)


def expire_selections(db):
    lock_user_data(db)
    rows = list(db.scalars(select(SummarySelection).where(SummarySelection.status == "open",
        SummarySelection.expires_at <= now(), SummarySelection.user_id == current_user_id(db)).with_for_update()))
    for item in rows:
        clear_selection(db, item, "expired")
    # Also cover a lost callback after the acceptance commit without requiring restart.
    overdue = select(SummaryCandidate.id).join(SummarySelection).where(
        SummarySelection.user_id == current_user_id(db), SummarySelection.status == "open",
        SummaryCandidate.status.in_(["queued", "generating"]),
        SummaryCandidate.created_at <= now()-JOB_DEADLINE)
    db.execute(update(SummaryCandidate).where(SummaryCandidate.id.in_(overdue))
        .values(status="error", error_code="llm_timeout", completed_at=now()))


def initialize_variants(db):
    expire_all_selections(db)
    db.execute(update(SummaryCandidate).where(SummaryCandidate.status.in_(["queued", "generating"]))
        .values(status="error", error_code="processing_interrupted", completed_at=now()))


def expire_all_selections(db):
    """Internal maintenance only: visit each tenant with its own mutation lock."""
    previous = db.info.get("user_id")
    owners = db.scalars(select(SummarySelection.user_id).where(
        SummarySelection.status == "open").distinct().order_by(SummarySelection.user_id)).all()
    try:
        for owner in owners:
            db.info["user_id"] = owner
            expire_selections(db)
    finally:
        if previous is None:
            db.info.pop("user_id", None)
        else:
            db.info["user_id"] = previous


def source_has_open_selection(db, transcript_id):
    return db.scalar(select(SummarySelection.id).where(SummarySelection.transcript_id == transcript_id,
        SummarySelection.user_id == current_user_id(db), SummarySelection.status == "open",
        SummarySelection.expires_at > now()).limit(1)) is not None


def guard_source_selection(db, transcript_id):
    if source_has_open_selection(db, transcript_id):
        fail(409, "selection_in_progress", "Завершите или отмените выбор варианта перед изменением источника.")


def owned_selection(db, id, *, lock=False):
    query = select(SummarySelection).where(SummarySelection.id == id, SummarySelection.user_id == current_user_id(db))
    item = db.scalar(query.with_for_update() if lock else query)
    if item is None:
        fail(404, "not_found", "Сессия выбора не найдена.")
    return item


def require_open(item):
    if item.status in ("cancelled", "expired"):
        fail(410, "selection_expired" if item.status == "expired" else "selection_cancelled", "Сессия выбора завершена; сохранённый документ не изменён.")
    if item.status != "open":
        fail(409, "selection_closed", "Вариант уже принят. Откройте новую сессию для другого результата.")


def candidate_response(item, session):
    options = item.options or {}
    error = None
    if item.error_code:
        error = ProcessingError(code=item.error_code, message=ERROR_MESSAGES.get(item.error_code, "Обработка не завершена."))
    return CandidateOut(id=item.id, selection_id=session.id, status=item.status,
        content=item.content, navigation=navigation(item.content) if item.content else [],
        template_snapshot=options.get("template_snapshot"),
        generation_options={k: v for k, v in options.items() if k != "template_snapshot"} if item.options is not None else None,
        processing_metadata=item.processing_metadata, error=error,
        created_at=item.created_at, expires_at=session.expires_at)


def selection_response(db, item):
    candidates = db.scalars(select(SummaryCandidate).where(SummaryCandidate.selection_id == item.id)
        .order_by(SummaryCandidate.created_at, SummaryCandidate.id)).all()
    return SelectionOut(id=item.id, status=item.status, transcript_id=item.source_transcript_id,
        summary_id=item.summary_id, summary_version=item.base_version,
        accepted_candidate_id=item.accepted_candidate_id, expires_at=item.expires_at,
        candidates=[candidate_response(c, item) for c in candidates])


def check_capacity(db):
    active = list(db.scalars(select(SummaryCandidate.id).join(SummarySelection).where(
        SummarySelection.user_id == current_user_id(db), SummarySelection.status == "open",
        SummaryCandidate.status.in_(["queued", "generating"])).limit(MAX_ACTIVE_JOBS)))
    classic = db.scalar(select(func.count()).select_from(Transcript).where(
        Transcript.owner_user_id == current_user_id(db), Transcript.processing_status == "summarizing"))
    if len(active) + classic >= MAX_ACTIVE_JOBS:
        fail(429, "generation_busy", "Уже выполняются две генерации. Дождитесь завершения.")


class CandidateCancelled(Exception):
    pass


def run_candidate(factory, candidate_id, generator):
    attempt = None
    with factory() as lookup:
        candidate = lookup.get(SummaryCandidate, candidate_id)
        selection = lookup.get(SummarySelection, candidate.selection_id) if candidate else None
        if selection is None:
            return
        owner_id = selection.user_id
    try:
        with factory.begin() as db:
            db.info["user_id"] = owner_id
            lock_user_data(db)
            candidate = db.get(SummaryCandidate, candidate_id)
            if candidate is None or candidate.status != "queued":
                return
            session = owned_selection(db, candidate.selection_id, lock=True)
            if session.status != "open" or session.expires_at <= now():
                if session.status == "open":
                    clear_selection(db, session, "expired")
                return
            candidate.status = "generating"
            source, options, attempt = session.source_text, dict(candidate.options), candidate.attempt
            deadline = candidate.created_at + JOB_DEADLINE

        def progress(metadata=None):
            with factory.begin() as db:
                db.info["user_id"] = owner_id
                lock_user_data(db)
                candidate = db.get(SummaryCandidate, candidate_id)
                if candidate is None or candidate.status != "generating" or candidate.attempt != attempt:
                    raise CandidateCancelled()
                session = owned_selection(db, candidate.selection_id, lock=True)
                if session.status != "open" or session.expires_at <= now():
                    raise CandidateCancelled()
                if now() >= deadline:
                    raise LLMError("llm_timeout")
                if metadata:
                    candidate.processing_metadata = metadata

        progress()
        with gpu_slot(factory, enabled=settings.asr_gpu_serial, on_wait=progress):
            progress()
            content, metadata = generate_long(generator, source, options=options, on_progress=progress)
        progress()
        if not isinstance(content, str) or not content.strip():
            raise LLMError("llm_invalid_response")
        with factory.begin() as db:
            db.info["user_id"] = owner_id
            lock_user_data(db)
            candidate = db.get(SummaryCandidate, candidate_id)
            if candidate is None or candidate.status != "generating" or candidate.attempt != attempt:
                return
            session = owned_selection(db, candidate.selection_id, lock=True)
            if session.status != "open" or session.expires_at <= now():
                if session.status == "open":
                    clear_selection(db, session, "expired")
                return
            candidate.content, candidate.status = content, "ready"
            candidate.processing_metadata = metadata
            candidate.completed_at = now()
    except CandidateCancelled:
        return
    except Exception as exc:
        code = exc.code if isinstance(exc, LLMError) else "processing_failed"
        with factory.begin() as db:
            db.info["user_id"] = owner_id
            lock_user_data(db)
            candidate = db.get(SummaryCandidate, candidate_id)
            if candidate is None or candidate.status not in ("queued", "generating") or (attempt is not None and candidate.attempt != attempt):
                return
            session = owned_selection(db, candidate.selection_id, lock=True)
            if session.status != "open" or session.expires_at <= now():
                if session.status == "open":
                    clear_selection(db, session, "expired")
                return
            candidate.status, candidate.error_code, candidate.completed_at = "error", code, now()
