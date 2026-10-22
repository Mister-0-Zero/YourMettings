"""Small, bounded in-memory preview jobs. No preview input is persisted to PostgreSQL."""
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, BackgroundTasks, Depends
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy.orm import Session, sessionmaker

from app.api.errors import fail
from app.core.config import settings
from app.db.session import TEST_USER_ID, get_db
from app.integrations.ollama import get_generator, LLMError
from app.schemas import Input, NavigationHeading, ProcessingError, ProcessInput
from app.services.gpu import gpu_slot
from app.services.processing import ERROR_MESSAGES
from app.services.template_rendering import navigation
from app.template_schemas import TemplateInput

router = APIRouter(prefix="/template-previews", tags=["summary-templates"])
TTL_SECONDS = 900
DEADLINE_SECONDS = 360
MAX_JOBS = 20
MAX_ACTIVE = 2
_jobs = {}
_lock = threading.Lock()


class PreviewInput(Input):
    text: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=12000)]
    template: TemplateInput
    detail_level: Literal["brief", "normal", "detailed"] = "normal"
    # Reuse processing validation for the remaining generation options.
    focus_areas: list[Literal["tasks", "owners", "deadlines", "decisions", "risks", "disagreements"]] = Field(default_factory=list, max_length=6)
    additional_instructions: Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000)] = ""

    def options(self):
        return ProcessInput(title="Preview", folder_ids=[TEST_USER_ID], detail_level=self.detail_level,
            focus_areas=self.focus_areas, additional_instructions=self.additional_instructions).generation_options()


class PreviewOut(BaseModel):
    id: UUID
    status: Literal["queued", "generating", "ready", "error"]
    content: str | None = None
    navigation: list[NavigationHeading] = Field(default_factory=list)
    error: ProcessingError | None = None
    expires_at: datetime


def _purge(id):
    with _lock:
        old = _jobs.pop(id, None)
        if old and old.get("timer"):
            old["timer"].cancel()


def _response(job):
    return PreviewOut(**{k: v for k, v in job.items() if k in PreviewOut.model_fields})


def run_preview(factory, id, text, options, generator):
    def check_deadline():
        with _lock:
            job = _jobs.get(id)
            if not job or time.monotonic() >= job["deadline"]:
                raise LLMError("llm_timeout")
    try:
        with _lock:
            if id not in _jobs:
                return
            _jobs[id]["status"] = "generating"
        check_deadline()
        with gpu_slot(factory, enabled=settings.asr_gpu_serial, on_wait=check_deadline):
            check_deadline()
            content = generator.generate(text, options=options)
        check_deadline()
        if not isinstance(content, str) or not content.strip():
            raise LLMError("llm_invalid_response")
        with _lock:
            if id in _jobs:
                _jobs[id].update(status="ready", content=content, navigation=navigation(content))
    except Exception as exc:
        code = exc.code if isinstance(exc, LLMError) else "processing_failed"
        with _lock:
            if id in _jobs:
                _jobs[id].update(status="error", error={"code": code,
                    "message": ERROR_MESSAGES.get(code, ERROR_MESSAGES["processing_failed"])})

    finally:
        with _lock:
            if id in _jobs:
                _jobs[id]["active"] = False


@router.post("", response_model=PreviewOut, status_code=202,
    summary="Preview the current inline template without saving a meeting",
    responses={422: {"description": "Invalid inline template, text or generation options"},
        429: {"description": "Preview capacity exhausted"}})
def create_preview(body: PreviewInput, tasks: BackgroundTasks, db: Session = Depends(get_db),
    generator=Depends(get_generator)):
    # Validate through the same options schema before scheduling. Never persist test text.
    from pydantic import ValidationError
    try:
        options = body.options()
    except ValidationError:
        fail(422, "validation_error", "Некорректные настройки генерации.")
    options["template_snapshot"] = body.template.model_dump(mode="json")
    with _lock:
        now = datetime.now(timezone.utc)
        for key in list(_jobs):
            if _jobs[key]["expires_at"] <= now:
                old = _jobs.pop(key)
                old["timer"].cancel()
        if sum(j.get("active", j["status"] in ("queued", "generating")) for j in _jobs.values()) >= MAX_ACTIVE:
            fail(429, "preview_busy", "Дождитесь окончания предыдущих тестов шаблона.")
        if len(_jobs) >= MAX_JOBS:
            finished = [k for k, j in _jobs.items() if j["status"] in ("ready", "error") and not j.get("active")]
            if finished:
                old = _jobs.pop(finished[0])
                old["timer"].cancel()
            else:
                fail(429, "preview_busy", "Слишком много тестов шаблона.")
        id = uuid4()
        job = {"id": id, "owner_id": TEST_USER_ID, "status": "queued", "active": True,
            "expires_at": now + timedelta(seconds=TTL_SECONDS),
            "deadline": time.monotonic() + DEADLINE_SECONDS}
        timer = threading.Timer(TTL_SECONDS, _purge, args=(id,))
        timer.daemon = True
        job["timer"] = timer
        _jobs[id] = job
        result = _response(job)
        timer.start()
    factory = sessionmaker(db.get_bind(), expire_on_commit=False)
    tasks.add_task(run_preview, factory, id, body.text, options, generator)
    return result


@router.get("/{id}", response_model=PreviewOut,
    responses={404: {"description": "Preview unknown, expired, evicted or lost after restart"}})
def get_preview(id: UUID):
    with _lock:
        job = _jobs.get(id)
        if not job or job["owner_id"] != TEST_USER_ID or job["expires_at"] <= datetime.now(timezone.utc):
            fail(404, "not_found", "Тест шаблона не найден или истёк; запустите новый тест.")
        if job["status"] in ("queued", "generating") and time.monotonic() >= job["deadline"]:
            job.update(status="error", error={"code": "llm_timeout", "message": ERROR_MESSAGES["llm_timeout"]})
        return _response(job)
