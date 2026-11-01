"""Opt-in orchestration. ASR source survives missing input and Qwen failures."""
import hashlib
from uuid import UUID
from sqlalchemy import select
from app.api.errors import fail
from app.db.audio_models import AudioSession
from app.db.models import Folder
from app.services.jobs import enqueue
from app.services.template_catalog import resolve_template_snapshot


def snapshot_parameters(db, body):
    snapshot = resolve_template_snapshot(db, body.template_id)
    if body.expected_template_version is not None and snapshot['version'] != body.expected_template_version:
        fail(409, 'template_version_conflict', 'Шаблон изменился. Перечитайте его и явно подтвердите настройки.')
    return {**body.generation_options(), 'template_snapshot': snapshot}


def phase(item, value, error=None):
    if item.pipeline_config:
        item.pipeline_config = {**item.pipeline_config, 'phase': value, 'error_code': error}


def set_source_phase(db, transcript_id, value, error=None):
    audio = db.scalar(select(AudioSession).where(AudioSession.transcript_id == transcript_id).with_for_update())
    if audio and audio.pipeline_config:
        phase(audio, value, error)
        if value == 'completed':
            audio.status = 'completed'
        elif value in ('error', 'needs_input', 'review_required', 'cancelled'):
            audio.status = 'ready_for_review'


def enqueue_automatic(db, audio, source):
    config = audio.pipeline_config
    if not config or config['mode'] != 'automatic' or config['phase'] == 'cancelled':
        return None
    if source.processing_status == 'summarizing' or source.first_processed_at is not None:
        return None
    if audio.boundary_warnings and config.get("reviewed_source_hash") != hashlib.sha256(source.text.encode()).hexdigest():
        phase(audio, 'review_required', 'boundary_review_required')
        return None
    ids = config['folder_ids']
    existing = set(db.scalars(select(Folder.id).where(Folder.id.in_(ids), Folder.user_id == audio.user_id)))
    if existing != set(UUID(value) for value in ids):
        phase(audio, 'needs_input', 'folders_unavailable')
        return None
    from app.services.variants import check_capacity
    from fastapi import HTTPException
    try:
        check_capacity(db)
    except HTTPException as exc:
        if exc.status_code != 429:
            raise
        phase(audio, 'needs_input', 'generation_busy')
        return None
    source.processing_title = config['title']
    source.processing_folder_ids = list(existing)
    source.processing_options = config['options']
    source.processing_attempt += 1
    source.processing_status, source.error_code = 'summarizing', None
    phase(audio, 'queued_qwen')
    db.flush()
    return enqueue(db, transcript=source)


def public_pipeline(item, summary_id=None):
    if not item.pipeline_config:
        return None
    return {key: item.pipeline_config.get(key) for key in ('mode', 'phase', 'error_code')} | {'summary_id': summary_id}

