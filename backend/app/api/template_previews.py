"""Durable technical preview jobs; no ordinary transcript, meeting or summary is created."""
import hashlib
from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, BackgroundTasks, Depends, Header, Query, Response
from pydantic import BaseModel, Field, StringConstraints, model_validator
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from app.api.errors import fail
from app.api.summary_variants import prepare, validate_source
from app.db.session import current_user_id, get_db
from app.db.variant_models import SummarySelection, SummaryCandidate
from app.integrations.ollama import get_generator
from app.schemas import GenerationOptionsInput, NavigationHeading, ProcessingError
from app.services.variants import (PREVIEW_TTL, now, fingerprint, check_capacity, candidate_response,
    clear_selection, owned_selection, run_candidate)
from app.template_schemas import TemplateInput

router = APIRouter(prefix="/template-previews", tags=["summary-templates"])


class PreviewInput(GenerationOptionsInput):
    text: Annotated[str, StringConstraints(min_length=1, max_length=200000)]
    template: TemplateInput

    @model_validator(mode="after")
    def nonblank(self):
        if not self.text.strip():
            raise ValueError("Preview source must not be blank")
        return self


class PreviewOut(BaseModel):
    id: UUID
    status: Literal["queued", "generating", "ready", "error"]
    content: str | None = None
    navigation: list[NavigationHeading] = Field(default_factory=list)
    template_snapshot: dict | None = None
    generation_options: dict | None = None
    processing_metadata: dict = Field(default_factory=dict)
    error: ProcessingError | None = None
    expires_at: datetime


def response(candidate, session):
    if session.kind != "preview":
        fail(404, "not_found", "Тест шаблона не найден.")
    if session.status != "open" or candidate.status in ("discarded", "expired"):
        fail(410, "preview_expired", "Тест шаблона завершён или истёк. Старый ключ не запускает модель повторно.")
    result = candidate_response(candidate, session).model_dump()
    return PreviewOut(**{k: v for k, v in result.items() if k in PreviewOut.model_fields})


@router.post("", response_model=PreviewOut, status_code=202, responses={
    409: {"description": "Idempotency key conflicts with original input"},
    410: {"description": "Previously accepted preview expired or was cancelled"},
    413: {"description": "Source exceeds word, character or UTF-8 byte limit"},
    429: {"description": "Two generations are already active"}})
def create_preview(body: PreviewInput, tasks: BackgroundTasks,
    idempotency_key: Annotated[str | None, Header(min_length=1, max_length=128)] = None,
    db: Session = Depends(get_db), generator=Depends(get_generator)):
    validate_source(body.text)
    prepare(db)
    params = body.model_dump(mode="json")
    params["focus_areas"] = sorted(params["focus_areas"])
    request_hash = fingerprint(params)
    key = "preview:" + (idempotency_key or str(uuid4()))
    session = db.scalar(select(SummarySelection).where(SummarySelection.user_id == current_user_id(db),
        SummarySelection.idempotency_key == key))
    if session:
        if session.request_hash != request_hash:
            fail(409, "idempotency_conflict", "Ключ уже использован для другого теста шаблона.")
        candidate = db.scalar(select(SummaryCandidate).where(SummaryCandidate.selection_id == session.id))
        result = response(candidate, session)
        db.commit()
        return result
    check_capacity(db)
    open_previews = list(db.scalars(select(SummarySelection).where(SummarySelection.user_id == current_user_id(db),
        SummarySelection.kind == "preview", SummarySelection.status == "open").order_by(SummarySelection.created_at)))
    if len(open_previews) >= 20:
        for old in open_previews:
            active = db.scalar(select(SummaryCandidate.id).where(SummaryCandidate.selection_id == old.id,
                SummaryCandidate.status.in_(["queued", "generating"])).limit(1))
            if active is None:
                clear_selection(db, old, "expired")
                break
        else:
            fail(429, "generation_busy", "Дождитесь окончания предыдущих тестов.")
    session = SummarySelection(user_id=current_user_id(db), kind="preview", idempotency_key=key,
        request_hash=request_hash, source_text=body.text, source_hash=hashlib.sha256(body.text.encode()).hexdigest(),
        owns_transcript=False, title=None, folder_ids=[], expires_at=now()+PREVIEW_TTL)
    db.add(session)
    db.flush()
    options = {**body.generation_options(), "template_snapshot": body.template.model_dump(mode="json")}
    candidate = SummaryCandidate(selection_id=session.id, options=options, generation_hash=fingerprint(options))
    db.add(candidate)
    db.flush()
    result = response(candidate, session)
    db.commit()
    tasks.add_task(run_candidate, sessionmaker(db.get_bind(), expire_on_commit=False), candidate.id, generator)
    return result


@router.get("/{id}", response_model=PreviewOut, responses={
    404: {"description": "Unknown or inaccessible preview"}, 410: {"description": "Preview expired or cancelled"}})
def get_preview(id: UUID, db: Session = Depends(get_db)):
    prepare(db)
    candidate = db.get(SummaryCandidate, id)
    if candidate is None:
        fail(404, "not_found", "Тест шаблона не найден.")
    session = owned_selection(db, candidate.selection_id)
    result = response(candidate, session)
    db.commit()
    return result


@router.delete("/{id}", status_code=204)
def cancel_preview(id: UUID, confirm: bool = Query(False), db: Session = Depends(get_db)):
    if not confirm:
        fail(422, "confirmation_required", "Подтвердите отмену теста.")
    prepare(db)
    candidate = db.get(SummaryCandidate, id)
    if candidate is None:
        fail(404, "not_found", "Тест шаблона не найден.")
    session = owned_selection(db, candidate.selection_id, lock=True)
    if session.kind != "preview":
        fail(404, "not_found", "Тест шаблона не найден.")
    if session.status == "open":
        clear_selection(db, session, "cancelled")
    db.commit()
    return Response(status_code=204)
