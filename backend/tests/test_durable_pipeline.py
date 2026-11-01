"""Synthetic PostgreSQL crash-window, lease and opt-in pipeline checks."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Event
from uuid import UUID, uuid4
import hashlib
import json

import pytest
from fastapi import BackgroundTasks
from sqlalchemy import func, select, text

from app.core.config import settings
from app.db.audio_models import AudioChunk, AudioSession
from app.db.job_models import ProcessingJob
from app.db.models import Summary, Transcript, User
from app.db.session import initialize_database
from app.db.variant_models import SummaryCandidate, SummarySelection
from app.integrations.ollama import get_generator
from app.main import app
from app.services.audio import claim_chunk, finish_chunk
from app.services.jobs import Lease, JobLost, claim, execute, now, run_job
from test_audio import do_job, upload, worker
from test_processing import FakeGenerator, prepare
from test_summary_variants import candidate, create, new_selection
from test_templates import definition

pytestmark = pytest.mark.integration
BASE = '/api/v1/audio-sessions'


@pytest.fixture
def deferred(monkeypatch):
    tasks = []
    monkeypatch.setattr(BackgroundTasks, 'add_task', lambda self, fn, *a, **kw: tasks.append((fn, a, kw)))
    return tasks


def automatic(client, **overrides):
    folder = client.post('/api/v1/folders', json={'name': 'Automatic QA'}).json()['id']
    body = {'title': 'Synthetic automatic meeting', 'folder_ids': [folder], 'processing_mode': 'automatic', **overrides}
    response = client.post(BASE, json=body, headers={'Idempotency-Key': str(uuid4())})
    assert response.status_code == 201, response.text
    return response.json(), body


def assembled(client, database, **overrides):
    session, body = automatic(client, **overrides)
    sid = session['id']
    assert upload(client, sid).status_code == 201
    assert client.post(f'{BASE}/{sid}/complete', json={'expected_chunk_count': 1}).status_code == 202
    do_job(database, worker(database))
    response = client.get(f'{BASE}/{sid}').json()
    assert response['transcript_id']
    return response, body


def only_job(database):
    with database() as db:
        return db.scalar(select(ProcessingJob.id))


def test_auto_durable_source_and_job_before_qwen_then_one_atomic_summary(client, database):
    session, body = assembled(client, database)
    tid = UUID(session['transcript_id'])
    assert session['pipeline']['phase'] == 'queued_qwen'
    assert session['processing']['status'] == 'summarizing'
    assert client.patch(f'/api/v1/transcripts/{tid}', json={'text': 'blocked'}).status_code == 409
    class Observed(FakeGenerator):
        def generate(self, source, *, options=None):
            with database() as db:
                assert db.get(Transcript, tid).text == source
                assert db.scalar(select(func.count()).select_from(Summary)) == 0
                assert db.scalar(text("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='idle in transaction'")) == 0
                assert options['template_snapshot']['version']
            return super().generate(source, options=options)
    fake = Observed()
    jid = only_job(database)
    run_job(database, jid, fake)
    run_job(database, jid, fake)
    state = client.get(f"{BASE}/{session['id']}").json()
    assert state['status'] == 'completed' and state['pipeline']['phase'] == 'completed'
    assert state['pipeline']['summary_id'] == state['processing']['summary_id']
    summary = client.get('/api/v1/summaries/'+state['pipeline']['summary_id']).json()
    assert summary['folder_ids'] == body['folder_ids'] and summary['transcript_id'] == str(tid)
    assert fake.calls == 1
    with database() as db:
        assert db.get(ProcessingJob, jid).status == 'done'
        assert db.get(Transcript, tid).first_processed_at is not None
        assert db.scalar(select(func.count()).select_from(Summary)) == 1


def test_restart_after_acceptance_before_dispatch_keeps_classic_and_candidate_jobs(client, database, deferred):
    tid, body = prepare(client)
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    assert client.post(f'/api/v1/transcripts/{tid}/process', json=body).status_code == 202
    selection, _ = new_selection(client)
    selected = candidate(client, selection)
    initialize_database(database)
    assert client.get(f'/api/v1/transcripts/{tid}/processing').json()['status'] == 'summarizing'
    assert client.get('/api/v1/summary-candidates/'+selected['id']).json()['status'] == 'queued'
    fake = FakeGenerator()
    while record := claim(database):
        execute(database, record, fake)
    assert fake.calls == 2
    assert client.get(f'/api/v1/transcripts/{tid}/processing').json()['status'] == 'ready'
    assert client.get('/api/v1/summary-candidates/'+selected['id']).json()['status'] == 'ready'


def test_two_dispatchers_only_one_claim_and_result(client, database):
    session, _ = assembled(client, database)
    with ThreadPoolExecutor(2) as pool:
        claims = list(pool.map(lambda _: claim(database), range(2)))
    assert sum(record is not None for record in claims) == 1
    execute(database, next(record for record in claims if record), FakeGenerator())
    assert client.get(f"{BASE}/{session['id']}").json()['pipeline']['phase'] == 'completed'


def test_expired_lease_reclaimed_same_attempt_old_fence_cannot_save(client, database, monkeypatch):
    session, _ = assembled(client, database)
    monkeypatch.setattr(settings, 'asr_gpu_serial', False)
    monkeypatch.setattr(settings, 'qwen_max_deliveries', 3)
    old = claim(database)
    started, release = Event(), Event()
    slow = FakeGenerator(started=started, release=release)
    with ThreadPoolExecutor(2) as pool:
        pending = pool.submit(execute, database, old, slow)
        assert started.wait(5)
        try:
            with database.begin() as db:
                db.get(ProcessingJob, old['id']).lease_until = now()-timedelta(seconds=1)
            new = claim(database)
            assert new['claim_epoch'] == old['claim_epoch']+1 and new['target_attempt'] == old['target_attempt']
            execute(database, new, FakeGenerator())
        finally:
            release.set()
        pending.result(timeout=10)
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 1
        assert db.get(ProcessingJob, old['id']).status == 'done'


def test_independent_heartbeat_runs_during_blocking_model(client, database, monkeypatch):
    session, _ = assembled(client, database)
    monkeypatch.setattr(settings, 'qwen_lease_seconds', 1)
    monkeypatch.setattr(settings, 'qwen_heartbeat_seconds', .05)
    started, release = Event(), Event()
    record = claim(database)
    with ThreadPoolExecutor(1) as pool:
        pending = pool.submit(execute, database, record, FakeGenerator(started=started, release=release))
        assert started.wait(5)
        try:
            Event().wait(1.3)
            assert claim(database) is None
            with database() as db:
                assert db.get(ProcessingJob, record['id']).lease_until > now()
        finally:
            release.set()
        pending.result(timeout=10)


def test_bounded_infrastructure_retry_preserves_source_and_user_attempt(client, database, monkeypatch):
    session, _ = assembled(client, database)
    monkeypatch.setattr(settings, 'qwen_max_deliveries', 3)
    jid = only_job(database)
    fake = FakeGenerator(error='llm_unavailable')
    for delivery in range(3):
        run_job(database, jid, fake)
        with database.begin() as db:
            row = db.get(ProcessingJob, jid)
            assert row.delivery_count == delivery+1 and row.target_attempt == 1
            assert row.status == ('queued' if delivery < 2 else 'error')
            row.available_at = now()-timedelta(seconds=1)
    state = client.get(f"{BASE}/{session['id']}").json()
    assert state['pipeline']['phase'] == 'error' and state['processing']['status'] == 'error'
    assert client.get('/api/v1/transcripts/'+session['transcript_id']).json()['text']
    assert fake.calls == 3


def test_qwen_error_retry_receipt_and_repair_without_asr_repeat(client, database):
    session, body = assembled(client, database)
    run_job(database, only_job(database), FakeGenerator(error='llm_invalid_response'))
    source_url = '/api/v1/transcripts/'+session['transcript_id']
    assert client.patch(source_url, json={'text': 'Explicit corrected synthetic source.'}).status_code == 200
    with database() as db:
        before_attempts = list(db.scalars(select(AudioChunk.attempt)))
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    retry_url = f"{BASE}/{session['id']}/pipeline/retry"
    headers = {'Idempotency-Key': 'retry-same-operation'}
    first = client.post(retry_url, json={}, headers=headers)
    assert first.status_code == 202
    repeated = client.post(retry_url, json={}, headers=headers)
    assert repeated.status_code == 200 and repeated.json() == first.json()
    assert client.post(retry_url, json={'parameters': {key:value for key,value in body.items() if key != 'processing_mode'}}, headers=headers).status_code == 409
    state = client.get(f"{BASE}/{session['id']}").json()
    assert state['pipeline']['phase'] == 'completed'
    with database() as db:
        assert list(db.scalars(select(AudioChunk.attempt))) == before_attempts
        assert db.scalar(select(func.count()).select_from(Summary)) == 1
    assert client.post(retry_url, json={}, headers={'Idempotency-Key': 'different'}).json()['error']['code'] == 'summary_exists'


def test_missing_folder_after_asr_needs_input_repair_reuses_source(client, database):
    session, body = automatic(client)
    sid = session['id']
    assert upload(client, sid).status_code == 201
    assert client.post(f'{BASE}/{sid}/complete', json={'expected_chunk_count': 1}).status_code == 202
    assert client.delete('/api/v1/folders/'+body['folder_ids'][0], params={'mode':'with_contents','confirm':True}).status_code == 204
    do_job(database, worker(database))
    state = client.get(f'{BASE}/{sid}').json()
    assert state['pipeline']['phase'] == 'needs_input' and state['pipeline']['error_code'] == 'folders_unavailable'
    with database() as db:
        assert db.scalar(select(func.count()).select_from(ProcessingJob)) == 0
    replacement = client.post('/api/v1/folders', json={'name':'Repair folder'}).json()['id']
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    repaired = client.post(f'{BASE}/{sid}/pipeline/retry', json={'parameters':{'title':body['title'],'folder_ids':[replacement]}}, headers={'Idempotency-Key':'repair'})
    assert repaired.status_code == 202
    final = client.get(f'{BASE}/{sid}').json()
    assert final['transcript_id'] == state['transcript_id'] and final['pipeline']['phase'] == 'completed'
    assert client.get('/api/v1/summaries/'+final['pipeline']['summary_id']).json()['folder_ids'] == [replacement]


def test_snapshot_survives_template_edit_and_expected_version_conflicts(client, database):
    template = client.post('/api/v1/summary-templates', json=definition()).json()
    session, body = automatic(client, template_id=template['id'], expected_template_version=template['version'])
    changed = {**definition(), 'name':'Explicit new template definition'}
    assert client.put('/api/v1/summary-templates/'+template['id'], json=changed).status_code == 200
    stale = client.post(BASE, json=body, headers={'Idempotency-Key':str(uuid4())})
    assert stale.status_code == 409 and stale.json()['error']['code'] == 'template_version_conflict'
    sid = session['id']
    upload(client, sid)
    client.post(f'{BASE}/{sid}/complete', json={'expected_chunk_count':1})
    do_job(database, worker(database))
    run_job(database, only_job(database), FakeGenerator())
    final = client.get(f'{BASE}/{sid}').json()
    saved = client.get('/api/v1/summaries/'+final['pipeline']['summary_id']).json()
    assert saved['template_snapshot']['name'] == template['name']
    assert saved['template_snapshot']['version'] == template['version']


def test_boundary_warning_requires_existing_explicit_review(client, database):
    session, _ = automatic(client)
    sid = session['id']
    upload(client, sid, 0)
    upload(client, sid, 1, start=100, overlap_ms=100)
    client.post(f'{BASE}/{sid}/complete', json={'expected_chunk_count':2})
    gen = worker(database)
    do_job(database, gen, 'Unmatched first words.')
    do_job(database, gen, 'Different second words.')
    state = client.get(f'{BASE}/{sid}').json()
    assert state['boundary_warnings'] and state['pipeline']['phase'] == 'review_required'
    retry = client.post(f'{BASE}/{sid}/pipeline/retry', json={}, headers={'Idempotency-Key':'not-reviewed'})
    assert retry.status_code == 409 and retry.json()['error']['code'] == 'boundary_review_required'
    with database() as db:
        assert db.scalar(select(func.count()).select_from(ProcessingJob)) == 0


@pytest.mark.parametrize('before_asr', [True, False])
def test_cancel_then_delete_tombstone_and_late_worker_cannot_resurrect(client, database, before_asr):
    session, body = automatic(client)
    sid = session['id']
    upload(client, sid)
    client.post(f'{BASE}/{sid}/complete', json={'expected_chunk_count':1})
    gen = worker(database)
    with database.begin() as db:
        late_asr = claim_chunk(db, gen)
    if not before_asr:
        with database.begin() as db:
            assert finish_chunk(db, late_asr, gen, text='Synthetic completed ASR')
        old_qwen = claim(database)
    assert client.post(f'{BASE}/{sid}/pipeline/cancel', json={}).status_code == 422
    cancelled = client.post(f'{BASE}/{sid}/pipeline/cancel', json={'confirm':True})
    assert cancelled.status_code == 200 and cancelled.json()['pipeline']['phase'] == 'cancelled'
    assert client.post(f'{BASE}/{sid}/pipeline/cancel', json={'confirm':True}).status_code == 200
    assert client.delete(f'{BASE}/{sid}', params={'confirm':True}).status_code == 204
    assert client.delete(f'{BASE}/{sid}', params={'confirm':True}).status_code == 204
    with database.begin() as db:
        assert not finish_chunk(db, late_asr, gen, text='Late data must not return')
    if not before_asr:
        execute(database, old_qwen, FakeGenerator())
    assert client.get(f'{BASE}/{sid}').status_code == 404
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 0
        assert db.scalar(select(func.count()).select_from(Transcript)) == 0


def test_queued_qwen_blocks_folder_deletion_and_other_retry_key(client, database):
    session, body = assembled(client, database)
    deletion = client.delete('/api/v1/folders/'+body['folder_ids'][0], params={'mode':'with_contents','confirm':True})
    assert deletion.status_code == 409 and deletion.json()['error']['code'] == 'folder_processing'
    retry = client.post(f"{BASE}/{session['id']}/pipeline/retry", json={}, headers={'Idempotency-Key':'another'})
    assert retry.status_code == 409 and retry.json()['error']['code'] == 'pipeline_busy'


def test_default_review_hash_and_empty_folder_compatibility(client, database):
    body = {'title':'Legacy offline review'}
    first = client.post(BASE, json=body, headers={'Idempotency-Key':'legacy'})
    assert first.status_code == 201 and first.json()['pipeline'] is None
    same = client.post(BASE, json={**body,'folder_ids':[],'processing_mode':'review'}, headers={'Idempotency-Key':'legacy'})
    assert same.status_code == 200 and same.json()['id'] == first.json()['id']
    old_parameters = {'title':body['title'],'folder_ids':[],'detail_level':'normal','focus_areas':[],'additional_instructions':''}
    old_hash = hashlib.sha256(json.dumps(old_parameters, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    with database() as db:
        assert db.get(AudioSession, UUID(first.json()['id'])).request_hash == old_hash
    assert client.post(BASE, json={**body,'processing_mode':'automatic'}).status_code == 422


def test_candidate_expiry_and_cancel_fence_job_backed_late_result(client, database, deferred):
    selection, _ = new_selection(client)
    item = candidate(client, selection)
    record = claim(database)
    with database.begin() as db:
        db.get(SummarySelection, UUID(selection['id'])).expires_at = now()-timedelta(seconds=1)
    execute(database, record, FakeGenerator())
    assert client.get('/api/v1/summary-candidates/'+item['id']).status_code == 410
    with database() as db:
        assert db.get(ProcessingJob, record['id']).status == 'cancelled'
        assert db.scalar(select(func.count()).select_from(Summary)) == 0


def test_automatic_endpoints_do_not_expose_foreign_session(client, database):
    with database.begin() as db:
        other = User(email='pipeline-other@example.test')
        db.add(other)
        db.flush()
        hidden = AudioSession(user_id=other.id, request_data={'title':'Private'}, request_hash='a'*64,
            pipeline_config={'mode':'automatic','phase':'receiving'})
        db.add(hidden)
        db.flush()
        sid = hidden.id
    assert client.post(f'{BASE}/{sid}/pipeline/cancel', json={'confirm':True}).status_code == 404
    assert client.post(f'{BASE}/{sid}/pipeline/retry', json={}, headers={'Idempotency-Key':'private'}).status_code == 404


def test_review_required_confirm_sha_boundaries_resumes_auto_saved_summary(client, database):
    session, body = automatic(client)
    sid = session['id']
    upload(client, sid, 0)
    upload(client, sid, 1, start=100, overlap_ms=100)
    client.post(f'{BASE}/{sid}/complete', json={'expected_chunk_count':2})
    gen = worker(database)
    do_job(database, gen, 'First synthetic phrase.')
    do_job(database, gen, 'Other synthetic phrase.')
    state = client.get(f'{BASE}/{sid}').json()
    assert state['pipeline']['phase'] == 'review_required'
    parameters = {key:value for key,value in body.items() if key != 'processing_mode'}
    confirm = {**parameters, 'confirm':True, 'reviewed_text_sha256':state['transcript_sha256'], 'boundaries_reviewed':True}
    attempted_selection = create(client, {**confirm,'audio_session_id':sid})
    assert attempted_selection.status_code == 409
    assert attempted_selection.json()['error']['code'] == 'automatic_confirmation_required'
    assert client.post(f'{BASE}/{sid}/confirm', json={**confirm,'reviewed_text_sha256':'0'*64}).status_code == 409
    assert client.post(f'{BASE}/{sid}/confirm', json={**confirm,'boundaries_reviewed':False}).status_code == 409
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    accepted = client.post(f'{BASE}/{sid}/confirm', json=confirm)
    assert accepted.status_code == 202
    final = client.get(f'{BASE}/{sid}').json()
    assert final['pipeline']['phase'] == 'completed' and final['pipeline']['summary_id']
    assert final['transcript_id'] == state['transcript_id']
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 1
        assert db.scalar(select(func.count()).select_from(SummaryCandidate)) == 0
    # A lost confirm response does not create another job or summary.
    assert client.post(f'{BASE}/{sid}/confirm', json=confirm).status_code == 200
    with database() as db:
        assert db.scalar(select(func.count()).select_from(ProcessingJob)) == 1


def test_cancel_during_model_call_fences_result_and_preserves_source(client, database):
    session, _ = assembled(client, database)
    record = claim(database)
    started, release = Event(), Event()
    fake = FakeGenerator(started=started, release=release)
    with ThreadPoolExecutor(1) as pool:
        pending = pool.submit(execute, database, record, fake)
        assert started.wait(5)
        try:
            cancelled = client.post(f"{BASE}/{session['id']}/pipeline/cancel", json={'confirm':True})
            assert cancelled.status_code == 200
        finally:
            release.set()
        pending.result(timeout=10)
    state = client.get(f"{BASE}/{session['id']}").json()
    assert state['pipeline']['phase'] == 'cancelled' and state['pipeline']['summary_id'] is None
    assert client.get('/api/v1/transcripts/'+state['transcript_id']).json()['text']
    with database() as db:
        assert db.get(ProcessingJob, record['id']).status == 'cancelled'
        assert db.scalar(select(func.count()).select_from(Summary)) == 0


def test_concurrent_retry_same_key_lost_ack_creates_one_user_attempt(client, database):
    session, _ = assembled(client, database)
    run_job(database, only_job(database), FakeGenerator(error='llm_invalid_response'))
    started, release = Event(), Event()
    fake = FakeGenerator(started=started, release=release)
    app.dependency_overrides[get_generator] = lambda: fake
    url = f"{BASE}/{session['id']}/pipeline/retry"
    headers = {'Idempotency-Key':'concurrent-retry'}
    with ThreadPoolExecutor(2) as pool:
        first = pool.submit(client.post, url, json={}, headers=headers)
        assert started.wait(5)
        try:
            second = client.post(url, json={}, headers=headers)
            assert second.status_code == 200
        finally:
            release.set()
        original = first.result(timeout=10)
    assert original.status_code == 202 and second.json() == original.json()
    with database() as db:
        assert db.scalar(select(func.count()).select_from(ProcessingJob)) == 2
        assert db.scalar(select(func.count()).select_from(Summary)) == 1
    assert fake.calls == 1


def test_attempt_deadline_is_terminal_with_no_model_execution(client, database):
    assembled(client, database)
    jid = only_job(database)
    with database.begin() as db:
        db.get(ProcessingJob, jid).deadline_at = now()-timedelta(seconds=1)
    fake = FakeGenerator()
    run_job(database, jid, fake)
    assert fake.calls == 0
    with database() as db:
        assert db.get(ProcessingJob, jid).status == 'error'
        assert db.scalar(select(Transcript)).processing_status == 'error'


def test_auto_create_lost_ack_returns_same_session_and_keeps_snapshot(client, database):
    folder = client.post('/api/v1/folders', json={'name':'Create replay'}).json()['id']
    body = {'title':'Frozen create', 'folder_ids':[folder], 'processing_mode':'automatic'}
    headers = {'Idempotency-Key':'create-lost-ack'}
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda _: client.post(BASE, json=body, headers=headers), range(2)))
    assert sorted(r.status_code for r in results) == [200,201]
    assert results[0].json()['id'] == results[1].json()['id']
    changed = client.post(BASE, json={**body,'title':'Edited local draft'}, headers=headers)
    assert changed.status_code == 409
    sid = results[0].json()['id']
    client.post(f'{BASE}/{sid}/pipeline/cancel', json={'confirm':True})
    client.delete(f'{BASE}/{sid}', params={'confirm':True})
    assert client.post(BASE, json=body, headers=headers).status_code == 410


def test_auto_result_save_failure_rolls_back_summary_and_keeps_source(client, database, monkeypatch):
    session, _ = assembled(client, database)
    from app.services.jobs import Lease
    def fail_after_changes(self, db):
        raise RuntimeError('Synthetic commit-boundary failure')
    monkeypatch.setattr(Lease, 'done', fail_after_changes)
    run_job(database, only_job(database), FakeGenerator())
    state = client.get(f"{BASE}/{session['id']}").json()
    assert state['pipeline']['phase'] == 'error'
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 0
        assert db.get(Transcript, UUID(state['transcript_id'])).first_processed_at is None


def test_job_owner_mismatch_never_calls_model_or_exposes_source(client, database):
    assembled(client, database)
    jid = only_job(database)
    with database.begin() as db:
        other = User(email='wrong-job-owner@example.test')
        db.add(other)
        db.flush()
        db.get(ProcessingJob, jid).owner_user_id = other.id
    fake = FakeGenerator()
    run_job(database, jid, fake)
    assert fake.calls == 0
    with database() as db:
        assert db.get(ProcessingJob, jid).status == 'cancelled'
        assert db.scalar(select(func.count()).select_from(Summary)) == 0

