"""Short claims + independent heartbeat. No transaction spans model execution."""
from datetime import datetime, timedelta, timezone
from threading import Event, Thread

from sqlalchemy import or_, select, update

from app.core.config import settings
from app.db.job_models import ProcessingJob, QwenWorkerState
from app.db.models import Transcript
from app.db.variant_models import SummaryCandidate, SummarySelection
from app.integrations.ollama import LLMError
from app.services.deletion import lock_user_data


def now():
    return datetime.now(timezone.utc)


class JobLost(Exception):
    pass


def enqueue(db, *, transcript=None, candidate=None):
    target = transcript or candidate
    field = ProcessingJob.transcript_id if transcript else ProcessingJob.candidate_id
    attempt = target.processing_attempt if transcript else target.attempt
    previous = db.scalar(select(ProcessingJob).where(field == target.id, ProcessingJob.target_attempt == attempt))
    if previous:
        return previous
    owner = transcript.owner_user_id if transcript else db.get(SummarySelection, candidate.selection_id).user_id
    job = ProcessingJob(owner_user_id=owner, transcript_id=transcript.id if transcript else None,
        candidate_id=candidate.id if candidate else None, target_attempt=attempt,
        deadline_at=now()+timedelta(seconds=settings.qwen_job_deadline_seconds))
    db.add(job)
    db.flush()
    return job


def claim(factory, job_id=None):
    with factory.begin() as db:
        query = select(ProcessingJob).where(or_(
            (ProcessingJob.status == "queued") & (ProcessingJob.available_at <= now()),
            (ProcessingJob.status == "running") & (ProcessingJob.lease_until <= now())))
        if job_id is not None:
            query = query.where(ProcessingJob.id == job_id)
        job = db.scalar(query.order_by(ProcessingJob.created_at, ProcessingJob.id).with_for_update(skip_locked=True).limit(1))
        if job is None:
            return None
        job.status, job.claim_epoch = "running", job.claim_epoch+1
        job.delivery_count += 1
        job.lease_until = now()+timedelta(seconds=settings.qwen_lease_seconds)
        return {key: getattr(job, key) for key in ("id", "owner_user_id", "claim_epoch", "transcript_id", "candidate_id", "target_attempt")}


class Lease:
    def __init__(self, factory, record):
        self.factory, self.record = factory, record
        self.stop, self.lost = Event(), Event()

    def check(self, db):
        job = db.scalar(select(ProcessingJob).where(ProcessingJob.id == self.record['id']).with_for_update().execution_options(populate_existing=True))
        if (self.lost.is_set() or job is None or job.status != "running"
            or job.claim_epoch != self.record['claim_epoch'] or job.owner_user_id != self.record['owner_user_id']
            or job.target_attempt != self.record['target_attempt'] or job.lease_until <= now()):
            raise JobLost()
        if job.deadline_at <= now():
            raise LLMError("llm_timeout")
        return job

    def progress(self, metadata=None):
        with self.factory.begin() as db:
            self.check(db)

    def done(self, db):
        job = self.check(db)
        job.status, job.lease_until = "done", None

    def heartbeat(self):
        while not self.stop.wait(settings.qwen_heartbeat_seconds):
            try:
                with self.factory.begin() as db:
                    updated = db.execute(update(ProcessingJob).where(ProcessingJob.id == self.record['id'],
                        ProcessingJob.status == "running", ProcessingJob.claim_epoch == self.record['claim_epoch'],
                        ProcessingJob.lease_until > now(), ProcessingJob.deadline_at > now()).values(
                            lease_until=now()+timedelta(seconds=settings.qwen_lease_seconds)))
                    import os
                    db.execute(update(QwenWorkerState).where(QwenWorkerState.id == 1,
                        QwenWorkerState.pid == os.getpid()).values(heartbeat_at=now()))
                    if updated.rowcount != 1:
                        self.lost.set()
                        return
            except Exception:
                self.lost.set()
                return


def fail_or_retry(factory, lease, exc):
    code = exc.code if isinstance(exc, LLMError) else "processing_failed"
    with factory.begin() as db:
        db.info['user_id'] = lease.record['owner_user_id']
        lock_user_data(db)
        source = db.scalar(select(Transcript).where(Transcript.id == lease.record['transcript_id']).with_for_update()) if lease.record['transcript_id'] else None
        candidate = db.get(SummaryCandidate, lease.record['candidate_id']) if lease.record['candidate_id'] else None
        # Deadline is terminal, but a valid lease can still finish the error transition.
        job = db.scalar(select(ProcessingJob).where(ProcessingJob.id == lease.record['id']).with_for_update())
        if not job or job.status != 'running' or job.claim_epoch != lease.record['claim_epoch'] or job.lease_until <= now():
            return
        valid = source is not None and source.owner_user_id == job.owner_user_id and source.processing_status == 'summarizing' and source.processing_attempt == job.target_attempt
        if candidate:
            selection = db.get(SummarySelection, candidate.selection_id)
            valid = (selection is not None and selection.user_id == job.owner_user_id and selection.status == 'open'
                and selection.expires_at > now() and candidate.status in ('queued', 'generating') and candidate.attempt == job.target_attempt)
        if not valid:
            job.status, job.lease_until = 'cancelled', None
            return
        job.last_error_code = code
        retry = code in ('llm_unavailable', 'llm_timeout') and job.delivery_count < settings.qwen_max_deliveries and job.deadline_at > now()
        job.status, job.lease_until = ('queued' if retry else 'error'), None
        job.available_at = now()+timedelta(seconds=min(30, 2**job.delivery_count))
        if candidate:
            candidate.status = 'queued' if retry else 'error'
            candidate.error_code = None if retry else code
            if not retry:
                candidate.completed_at = now()
        if source:
            if not retry:
                source.processing_status, source.error_code = 'error', code
            from app.services.audio_pipeline import set_source_phase
            set_source_phase(db, source.id, 'queued_qwen' if retry else 'error', None if retry else code)


def execute(factory, record, generator):
    lease = Lease(factory, record)
    pulse = Thread(target=lease.heartbeat, daemon=True)
    pulse.start()
    try:
        with factory.begin() as db:
            job = lease.check(db)
            if job.delivery_count > settings.qwen_max_deliveries:
                raise LLMError('llm_timeout')
        if record['transcript_id']:
            from app.services.processing import run_processing
            run_processing(factory, record['transcript_id'], record['target_attempt'], generator, lease=lease)
        else:
            from app.services.variants import run_candidate
            run_candidate(factory, record['candidate_id'], generator, lease=lease)
    except JobLost:
        pass
    except Exception as exc:
        fail_or_retry(factory, lease, exc)
    finally:
        lease.stop.set()
        pulse.join(timeout=5)


def run_job(factory, job_id, generator):
    """Best-effort post-commit kick; the independent dispatcher recovers a lost kick."""
    record = claim(factory, job_id)
    if record:
        execute(factory, record, generator)


def cancel_target_jobs(db, *, transcript_id=None, candidate_ids=None):
    query = update(ProcessingJob).where(ProcessingJob.status.in_(['queued', 'running']))
    query = query.where(ProcessingJob.transcript_id == transcript_id) if transcript_id else query.where(ProcessingJob.candidate_id.in_(candidate_ids or []))
    db.execute(query.values(status='cancelled', lease_until=None))

