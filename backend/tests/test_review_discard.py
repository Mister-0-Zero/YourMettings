"""Explicit review discard before complete, including real file/claim races."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
import importlib
import io
import os
from pathlib import Path
import threading
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select, text

from app.core.config import settings
from app.db.audio_models import AudioChunk, AudioSession, AudioSessionDeletion
from app.db.models import Summary, Transcript, User
from app.db.variant_models import SummarySelection
from app.services import audio_files
from app.services.audio import claim_chunk, current_asr_claim, finish_chunk
from app.services.audio_files import guard_asr_files
from app.services.variants import now
from test_audio import BASE, upload, worker, wav_bytes
from test_audio_deletion import ready

pytestmark = pytest.mark.integration


def pending(client):
    key = str(uuid4())
    body = {'title':'Synthetic unprocessed review'}
    response = client.post(BASE, json=body, headers={'Idempotency-Key':key})
    assert response.status_code == 201
    return response.json()['id'], key, body


def discard(client, sid, **kwargs):
    return client.delete(f'{BASE}/{sid}', params={'confirm':True,'discard_unprocessed':True}, **kwargs)


@pytest.mark.parametrize('partial_ack', [False, True])
def test_recording_without_complete_and_partial_ack_can_be_discarded(client, database, partial_ack):
    sid, key, body = pending(client)
    if partial_ack:
        accepted = upload(client, sid)
        assert accepted.status_code == 201 and accepted.json()['safe_to_delete_local']
    assert client.delete(f'{BASE}/{sid}', params={'confirm':True}).status_code == 409
    assert discard(client, sid).status_code == 204
    assert discard(client, sid).status_code == 204
    # Lost response may be retried even by a caller omitting the optional flag.
    assert client.delete(f'{BASE}/{sid}', params={'confirm':True}).status_code == 204
    assert client.get(f'{BASE}/{sid}').status_code == 404
    assert client.post(BASE, json=body, headers={'Idempotency-Key':key}).status_code == 410
    assert client.post(BASE, json={**body,'title':'Different'}, headers={'Idempotency-Key':key}).status_code == 409
    with database() as db:
        assert db.get(AudioSessionDeletion, UUID(sid))
        assert db.scalar(select(func.count()).select_from(AudioChunk)) == 0
        assert db.scalar(select(func.count()).select_from(Transcript)) == 0


@pytest.mark.parametrize('status', ['recording','transcribing','failed'])
def test_opt_in_handles_pending_failed_or_incomplete_session_without_source(client, database, status):
    sid, *_ = pending(client)
    upload(client, sid)
    with database.begin() as db:
        row = db.get(AudioSession, UUID(sid))
        row.status = status
        if status != 'recording':
            row.expected_chunk_count = 3  # Partial set will never assemble without further upload.
    assert discard(client, sid).status_code == 204


@pytest.mark.parametrize('confirm', [None, False])
def test_discard_opt_in_does_not_replace_confirmation(client, database, confirm):
    sid, *_ = pending(client)
    upload(client, sid)
    query = {'discard_unprocessed':True}
    if confirm is not None:query['confirm'] = confirm
    response = client.delete(f'{BASE}/{sid}', params=query)
    assert response.status_code == 422 and response.json()['error']['code'] == 'confirmation_required'
    with database() as db:
        assert db.get(AudioSession, UUID(sid))
        assert db.scalar(select(AudioChunk)).payload == wav_bytes()


def test_claimed_but_no_file_copy_is_fenced_and_cannot_resurrect(client, database):
    sid, *_ = pending(client)
    upload(client, sid)
    generation = worker(database)
    with database.begin() as db:
        job = claim_chunk(db, generation)
    with database() as db:
        assert current_asr_claim(db, job, generation)
    assert discard(client, sid).status_code == 204
    with database.begin() as db:
        assert not current_asr_claim(db, job, generation)
        assert not finish_chunk(db, job, generation, text='Late synthetic result')
    assert client.get(f'{BASE}/{sid}').status_code == 404


def test_active_asr_file_guard_conflicts_until_copy_is_closed(client, database, monkeypatch, tmp_path):
    sid, *_ = pending(client)
    upload(client, sid)
    generation = worker(database)
    with database.begin() as db:job = claim_chunk(db, generation)
    monkeypatch.setattr(audio_files, 'ASR_SCRATCH', tmp_path)
    copy = tmp_path/f'job-{sid}-in-use'
    copy.mkdir()
    source = copy/'audio.bin'
    source.write_bytes(wav_bytes())
    with guard_asr_files(database, UUID(sid)):
        response = discard(client, sid)
        assert response.status_code == 409 and response.json()['error']['code'] == 'audio_session_busy'
        assert source.read_bytes() == wav_bytes()
        with database() as db:
            assert db.get(AudioChunk, job['id']).payload == wav_bytes()
    assert discard(client, sid).status_code == 204
    assert not copy.exists()
    with database.begin() as db:
        assert not finish_chunk(db, job, generation, text='Late text')


def test_cleanup_failure_preserves_payload_claim_and_receipt_for_safe_retry(client, database, monkeypatch):
    sid, *_ = pending(client)
    upload(client, sid)
    import app.services.audio_deletion as service
    original = service.cleanup_session_files
    def locked(*args):raise PermissionError('Synthetic Windows lock')
    monkeypatch.setattr(service, 'cleanup_session_files', locked)
    failed = discard(client, sid)
    assert failed.status_code == 409 and failed.json()['error']['code'] == 'audio_cleanup_failed'
    with database() as db:
        assert db.get(AudioSession, UUID(sid))
        assert db.scalar(select(AudioChunk)).payload == wav_bytes()
        assert db.get(AudioSessionDeletion, UUID(sid)) is None
    monkeypatch.setattr(service, 'cleanup_session_files', original)
    assert discard(client, sid).status_code == 204


@pytest.mark.skipif(os.name != 'nt', reason='Actual Windows in-use file semantics')
def test_real_windows_locked_leftover_is_retryable_without_db_loss(client, database, tmp_path, monkeypatch):
    import ctypes
    sid, *_ = pending(client)
    upload(client, sid)
    monkeypatch.setattr(audio_files, 'ASR_SCRATCH', tmp_path)
    own = tmp_path/f'job-{sid}-locked'
    own.mkdir()
    path = own/'audio.bin'
    path.write_bytes(wav_bytes())
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(path), 0x80000000, 0, None, 3, 0x80, None)
    assert handle not in (None, ctypes.c_void_p(-1).value)
    try:
        response = discard(client, sid)
        assert response.status_code == 409 and response.json()['error']['code'] == 'audio_cleanup_failed'
        with database() as db:
            assert db.scalar(select(AudioChunk)).payload == wav_bytes()
            assert db.get(AudioSessionDeletion, UUID(sid)) is None
    finally:
        kernel.CloseHandle(handle)
    assert discard(client, sid).status_code == 204 and not own.exists()


def test_foreign_session_or_receipt_stays_hidden(client, database):
    assert discard(client, uuid4()).status_code == 404
    sid, *_ = pending(client)
    with database.begin() as db:
        other = User(email='review-discard-owner@example.test')
        db.add(other)
        db.flush()
        db.get(AudioSession, UUID(sid)).user_id = other.id
    assert discard(client, sid).status_code == 404


@pytest.mark.parametrize('dependency', ['summary','foreign_selection'])
def test_source_dependencies_and_unrelated_meetings_are_preserved(client, database, dependency):
    sid, state, *_ = ready(client, database)
    other_sid, *_ = pending(client)
    tid = UUID(state['transcript_id'])
    with database.begin() as db:
        if dependency == 'summary':
            db.add(Summary(user_id=db.get(AudioSession, UUID(sid)).user_id, transcript_id=tid, title='Keep summary',content='Keep synthetic data'))
        else:
            other = User(email='review-discard-selection@example.test')
            db.add(other)
            db.flush()
            db.add(SummarySelection(user_id=other.id, kind='meeting', idempotency_key='foreign-dependency',request_hash='a'*64,
                transcript_id=tid,source_transcript_id=tid,source_text='Shared synthetic input',source_hash='b'*64,expires_at=now()+timedelta(hours=1)))
    response = discard(client, sid)
    assert response.status_code == 409 and response.json()['error']['code'] == 'audio_session_in_use'
    assert discard(client, other_sid).status_code == 204
    with database() as db:
        assert db.get(Transcript, tid)
        assert db.get(AudioSession, UUID(sid))


@pytest.mark.parametrize('field,value', [('processing_status','summarizing'),('processing_attempt',1),('first_processed_at','now'),('idempotency_key','shared-source')])
def test_opt_in_never_bypasses_processed_or_reused_source_guards(client, database, field, value):
    sid, state, *_ = ready(client, database)
    with database.begin() as db:
        setattr(db.get(Transcript, UUID(state['transcript_id'])),field,now() if value=='now' else value)
    response = discard(client, sid)
    assert response.status_code == 409 and response.json()['error']['code'] == 'audio_session_not_deletable'
    assert client.get(f'{BASE}/{sid}').status_code == 200


def test_external_chunk_dependency_is_not_cascaded_by_discard(client, database):
    sid, *_ = pending(client)
    upload(client, sid)
    with database.begin() as db:
        db.execute(text('CREATE TABLE test_discard_dependency (session_id uuid, sequence_number integer, FOREIGN KEY(session_id,sequence_number) REFERENCES audio_chunks(session_id,sequence_number) ON DELETE CASCADE)'))
        db.execute(text('INSERT INTO test_discard_dependency VALUES (:id,0)'),{'id':UUID(sid)})
    try:
        assert discard(client, sid).json()['error']['code'] == 'audio_session_in_use'
        with database() as db:assert db.scalar(text('SELECT count(*) FROM test_discard_dependency'))==1
    finally:
        with database.begin() as db:db.execute(text('DROP TABLE test_discard_dependency'))


def test_concurrent_upload_blocks_discard_then_partial_ack_can_be_removed(client, database, monkeypatch):
    sid, *_ = pending(client)
    import app.api.audio_sessions as api
    original = api.validate_audio
    entered, release = threading.Event(), threading.Event()
    def validating(data):
        entered.set()
        assert release.wait(10)
        return original(data)
    monkeypatch.setattr(api, 'validate_audio', validating)
    with ThreadPoolExecutor(2) as pool:
        sending = pool.submit(upload, client, sid)
        assert entered.wait(5)
        try:
            blocked = discard(client, sid)
            assert blocked.status_code == 409 and blocked.json()['error']['code'] == 'audio_session_busy'
        finally:release.set()
        assert sending.result(timeout=10).status_code == 201
    assert discard(client, sid).status_code == 204


def coordinator(monkeypatch, database, generation, tmp_path):
    scripts = Path(__file__).resolve().parents[1]/'scripts'
    monkeypatch.syspath_prepend(str(scripts))
    module = importlib.import_module('scripts.asr_worker')
    monkeypatch.setattr(module, 'SCRATCH', tmp_path)
    monkeypatch.setattr(settings, 'asr_gpu_serial', False)
    result = module.Coordinator(database)
    result.generation = generation
    result.child = SimpleNamespace(stdin=io.StringIO())
    return module, result


def test_delete_before_worker_guard_creates_no_files_or_inference(client, database, monkeypatch, tmp_path):
    sid, *_ = pending(client)
    upload(client, sid)
    generation = worker(database)
    with database.begin() as db:job = claim_chunk(db,generation)
    _, process = coordinator(monkeypatch,database,generation,tmp_path)
    assert discard(client,sid).status_code == 204
    assert process.process_job(job) is False
    assert process.child.stdin.getvalue() == '' and list(tmp_path.iterdir()) == []


def test_real_worker_copy_guard_busy_then_retry_before_complete(client,database,monkeypatch,tmp_path):
    sid,*_ = pending(client)
    upload(client,sid)
    generation=worker(database)
    with database.begin() as db:job=claim_chunk(db,generation)
    _,process=coordinator(monkeypatch,database,generation,tmp_path)
    entered,release=threading.Event(),threading.Event()
    def receive(timeout):
        entered.set()
        assert release.wait(10)
        return {'text':'Synthetic ASR result','segments':[]}
    process.receive=receive
    with ThreadPoolExecutor(1) as pool:
        inference=pool.submit(process.process_job,job)
        assert entered.wait(5)
        try:
            blocked=discard(client,sid)
            assert blocked.status_code==409 and blocked.json()['error']['code']=='audio_session_busy'
            with database() as db:
                assert db.scalar(text("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='idle in transaction'"))==0
        finally:release.set()
        assert inference.result(timeout=10) is True
    assert list(tmp_path.iterdir())==[]
    assert client.get(f'{BASE}/{sid}').json()['transcript_id'] is None
    assert discard(client,sid).status_code==204


def test_delete_after_files_close_before_finish_never_resurrects(client,database,monkeypatch,tmp_path):
    sid,*_=pending(client)
    upload(client,sid)
    generation=worker(database)
    with database.begin() as db:job=claim_chunk(db,generation)
    module,process=coordinator(monkeypatch,database,generation,tmp_path)
    process.receive=lambda timeout:{'text':'Late synthetic result','segments':[]}
    original=module.finish_chunk
    entered,release=threading.Event(),threading.Event()
    def delayed(*args,**kwargs):
        entered.set()
        assert release.wait(10)
        return original(*args,**kwargs)
    monkeypatch.setattr(module,'finish_chunk',delayed)
    with ThreadPoolExecutor(1) as pool:
        inference=pool.submit(process.process_job,job)
        assert entered.wait(5)
        try:
            assert list(tmp_path.iterdir())==[]
            assert discard(client,sid).status_code==204
        finally:release.set()
        assert inference.result(timeout=10) is False
    assert client.get(f'{BASE}/{sid}').status_code==404

