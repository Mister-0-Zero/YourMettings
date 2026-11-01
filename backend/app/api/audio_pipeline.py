"""Explicit retry/repair/cancel for the opt-in automatic pipeline."""
import hashlib
from typing import Annotated
from uuid import UUID
from fastapi import APIRouter, BackgroundTasks, Depends, Header, Response
from sqlalchemy import select, text
from sqlalchemy.orm import Session, sessionmaker

from app.api.dependencies import validate_folders
from app.api.errors import fail
from app.audio_schemas import AudioPipelineRetry, AudioPipelineCancel, AudioAutomaticParameters, AudioSessionOut
from app.db.audio_models import AudioChunk
from app.db.job_models import AudioPipelineRequest
from app.db.models import Summary, Transcript
from app.db.session import get_db
from app.integrations.ollama import get_generator
from app.services.audio import owned_session, session_response
from app.services.audio_deletion import upload_lock_key
from app.services.audio_pipeline import enqueue_automatic, phase, snapshot_parameters
from app.services.deletion import lock_user_data
from app.services.jobs import cancel_target_jobs, run_job
from app.services.variants import fingerprint

router = APIRouter(prefix='/audio-sessions', tags=['audio pipeline'], responses={
    404: {'description': 'Session or requested folder/template not accessible'},
    409: {'description': 'pipeline_busy, boundary_review_required, transcript_not_ready, summary_exists, idempotency_conflict or template_version_conflict'}})


def automatic(db, id):
    item = owned_session(db, id, lock=True)
    if not item.pipeline_config or item.pipeline_config['mode'] != 'automatic':
        fail(409, 'automatic_required', 'Операция доступна только для автоматической встречи.')
    return item


@router.post('/{id}/pipeline/retry', response_model=AudioSessionOut, status_code=202)
def retry(id: UUID, body: AudioPipelineRetry, response: Response, tasks: BackgroundTasks,
    idempotency_key: Annotated[str, Header(min_length=1, max_length=128, alias='Idempotency-Key')],
    db: Session = Depends(get_db), generator=Depends(get_generator)):
    lock_user_data(db)
    item = automatic(db, id)
    digest = fingerprint({'operation':'retry', 'body':body.model_dump(mode='json')})
    receipt = db.get(AudioPipelineRequest, (id, idempotency_key))
    if receipt:
        if receipt.request_hash != digest:
            fail(409, 'idempotency_conflict', 'Ключ уже использован с другими параметрами.')
        response.status_code = 200
        return receipt.response
    if item.transcript_id is None:
        fail(409, 'transcript_not_ready', 'Дождитесь готового исходного транскрипта.')
    source = db.scalar(select(Transcript).where(Transcript.id == item.transcript_id).with_for_update())
    if source.first_processed_at is not None or db.scalar(select(Summary.id).where(Summary.transcript_id == source.id)):
        fail(409, 'summary_exists', 'Встреча уже обработана; используйте сохранённый summary.')
    if source.processing_status == 'summarizing':
        fail(409, 'pipeline_busy', 'Обработка уже принята. Проверяйте статус.')
    if item.boundary_warnings and item.pipeline_config.get("reviewed_source_hash") != hashlib.sha256(source.text.encode()).hexdigest():
        fail(409, 'boundary_review_required', 'Подтвердите проверку границ через ручной сценарий.')
    from app.services.variants import guard_source_selection, check_capacity
    guard_source_selection(db, source.id)
    check_capacity(db)
    if body.parameters is not None:
        validate_folders(db, body.parameters.folder_ids)
        item.pipeline_config = {**item.pipeline_config, 'title': body.parameters.title,
            'folder_ids': [str(fid) for fid in body.parameters.folder_ids],
            'options': snapshot_parameters(db, body.parameters)}
        item.request_data = {**body.parameters.model_dump(mode="json"), "processing_mode": "automatic"}
    # An explicit retry may resume a cancelled pipeline with an already durable source.
    phase(item, 'needs_input')
    job = enqueue_automatic(db, item, source)
    result = AudioSessionOut.model_validate(session_response(db, item)).model_dump(mode='json')
    db.add(AudioPipelineRequest(session_id=id, key=idempotency_key, request_hash=digest, response=result))
    db.commit()
    if job:
        tasks.add_task(run_job, sessionmaker(db.get_bind(), expire_on_commit=False), job.id, generator)
    return result


@router.post('/{id}/pipeline/cancel', response_model=AudioSessionOut)
def cancel(id: UUID, body: AudioPipelineCancel, db: Session = Depends(get_db)):
    if not body.confirm:
        fail(422, 'confirmation_required', 'Подтвердите отмену обработки.')
    lock_user_data(db)
    item = automatic(db, id)
    source = db.scalar(select(Transcript).where(Transcript.id == item.transcript_id).with_for_update()) if item.transcript_id else None
    if source and (source.first_processed_at is not None or db.scalar(select(Summary.id).where(Summary.transcript_id == source.id))):
        fail(409, 'summary_exists', 'Сохранённую встречу удаляйте через summary.')
    if not db.scalar(text('SELECT pg_try_advisory_xact_lock(:key)'), {'key': upload_lock_key(id)}):
        fail(409, 'audio_session_busy', 'Дождитесь завершения загрузки.')
    if source:
        from app.services.variants import guard_source_selection
        guard_source_selection(db, source.id)
        cancel_target_jobs(db, transcript_id=source.id)
        source.processing_status, source.error_code = 'error', 'processing_cancelled'
    for chunk in db.scalars(select(AudioChunk).where(AudioChunk.session_id == id, AudioChunk.status.in_(['queued', 'transcribing'])).with_for_update()):
        chunk.status, chunk.error_code, chunk.claimed_by = 'failed', 'processing_cancelled', None
    phase(item, 'cancelled', 'processing_cancelled')
    item.status = 'ready_for_review' if source else 'failed'
    db.flush()
    result = session_response(db, item)
    db.commit()
    return result



@router.put('/{id}/pipeline/parameters', response_model=AudioSessionOut, responses={
    409: {'description': 'pipeline_parameters_locked after complete/cancel, template_version_conflict or idempotency_conflict'}})
def update_parameters(id: UUID, body: AudioAutomaticParameters,
    idempotency_key: Annotated[str, Header(min_length=1, max_length=128, alias='Idempotency-Key')],
    db: Session = Depends(get_db)):
    lock_user_data(db)
    item = automatic(db, id)
    digest = fingerprint({'operation':'parameters', 'body':body.model_dump(mode='json')})
    receipt = db.get(AudioPipelineRequest, (id, idempotency_key))
    if receipt:
        if receipt.request_hash != digest:
            fail(409, 'idempotency_conflict', 'Ключ уже использован с другими параметрами или операцией.')
        return receipt.response
    if (item.expected_chunk_count is not None or item.transcript_id is not None
        or item.status != 'recording' or item.pipeline_config['phase'] != 'receiving'):
        fail(409, 'pipeline_parameters_locked', 'Настройки можно изменить только до complete. Перечитайте состояние встречи.')
    validate_folders(db, body.folder_ids)
    options = snapshot_parameters(db, body)
    item.pipeline_config = {**item.pipeline_config, 'title':body.title,
        'folder_ids':[str(fid) for fid in body.folder_ids], 'options':options}
    item.request_data = {**body.model_dump(mode='json'), 'processing_mode':'automatic'}
    db.flush()
    result = AudioSessionOut.model_validate(session_response(db, item)).model_dump(mode='json')
    db.add(AudioPipelineRequest(session_id=id, key=idempotency_key, request_hash=digest, response=result))
    db.commit()
    return result
