import logging
from datetime import datetime, timezone
from uuid import UUID

from sqlalchemy import select

from app.db.models import Summary, SummaryFolder, Transcript
from app.db.session import TEST_USER_ID
from app.integrations.ollama import LLMError, SummaryGenerator
from app.schemas import ProcessingError, ProcessingOut
from app.services.deletion import lock_user_data
from app.services.gpu import gpu_slot
from app.core.config import settings

logger = logging.getLogger(__name__)
ERROR_MESSAGES = {
    "context_limit_exceeded": "Текст и шаблон не удалось безопасно вместить в окно модели. Сократите структуру или исходный текст.",
    "llm_timeout": "Время ожидания модели истекло.",
    "llm_unavailable": "Модель временно недоступна.",
    "llm_invalid_response": "Модель вернула некорректный результат.",
    "processing_interrupted": "Обработка прервана перезапуском сервера.",
    "processing_failed": "Не удалось завершить обработку.",
}


def processing_response(db, item):
    summary_id = db.scalar(select(Summary.id).where(
        Summary.transcript_id == item.id, Summary.user_id == TEST_USER_ID))
    error = None
    if item.error_code:
        error = ProcessingError(code=item.error_code,
            message=ERROR_MESSAGES.get(item.error_code, ERROR_MESSAGES["processing_failed"]))
    return ProcessingOut(transcript_id=item.id, status=item.processing_status,
        summary_id=summary_id, error=error)


def run_processing(factory, transcript_id: UUID, attempt: int, generator: SummaryGenerator):
    try:
        # Snapshot and close the transaction before any model/network work.
        with factory() as db:
            item = db.get(Transcript, transcript_id)
            if item is None or item.processing_attempt != attempt or item.processing_status != "summarizing":
                return
            source = item.text
            options = dict(item.processing_options)
        with gpu_slot(factory, enabled=settings.asr_gpu_serial):
            content = generator.generate(source, options=options)
        if not isinstance(content, str) or not content.strip():
            raise LLMError("llm_invalid_response")
        with factory.begin() as db:
            lock_user_data(db)
            item = db.scalar(select(Transcript).where(Transcript.id == transcript_id).with_for_update())
            if item is None or item.processing_attempt != attempt or item.processing_status != "summarizing":
                return
            result = Summary(user_id=TEST_USER_ID, transcript_id=item.id,
                title=item.processing_title, content=content, template_snapshot=options.get("template_snapshot"),
                generation_options={k: v for k, v in options.items() if k != "template_snapshot"})
            db.add(result)
            db.flush()
            db.add_all(SummaryFolder(summary_id=result.id, folder_id=id) for id in item.processing_folder_ids)
            item.first_processed_at = item.first_processed_at or datetime.now(timezone.utc)
            item.processing_status = "ready"
            item.error_code = None
            item.processing_title = None
            item.processing_folder_ids = None
        logger.info("Processing succeeded transcript=%s attempt=%s", transcript_id, attempt)
    except Exception as exc:
        code = exc.code if isinstance(exc, LLMError) else "processing_failed"
        logger.error("Processing failed transcript=%s attempt=%s code=%s type=%s",
            transcript_id, attempt, code, type(exc).__name__)
        try:
            with factory.begin() as db:
                item = db.scalar(select(Transcript).where(Transcript.id == transcript_id).with_for_update())
                if item and item.processing_attempt == attempt and item.processing_status == "summarizing":
                    item.processing_status = "error"
                    item.error_code = code
                    item.processing_title = None
                    item.processing_folder_ids = None
        except Exception as recovery_error:
            logger.error("Failed to persist error transcript=%s type=%s", transcript_id, type(recovery_error).__name__)
