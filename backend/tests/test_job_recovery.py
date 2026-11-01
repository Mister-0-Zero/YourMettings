"""Recovery under GPU waits, cancellation and actual singleton worker processes."""
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from datetime import timedelta
from pathlib import Path
from uuid import UUID
import os
import subprocess
import sys
import time

import pytest
from sqlalchemy import select, text

from app.core.config import settings
from app.db.job_models import ProcessingJob, QwenWorkerState
from app.db.models import Summary
from app.db.variant_models import SummaryCandidate
from app.integrations.ollama import get_generator
from app.main import app
from app.services.gpu import GPU_LOCK
from app.services.jobs import claim, execute, now, run_job
from test_durable_pipeline import assembled
from test_processing import FakeGenerator
from test_summary_variants import candidate, new_selection

pytestmark = pytest.mark.integration


def test_explicit_retry_cancelled_source_starts_again_without_asr(client, database):
    session, _ = assembled(client, database)
    sid = session['id']
    assert client.post(f'/api/v1/audio-sessions/{sid}/pipeline/cancel', json={'confirm':True}).status_code == 200
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    retry = client.post(f'/api/v1/audio-sessions/{sid}/pipeline/retry', json={}, headers={'Idempotency-Key':'resume-cancelled'})
    assert retry.status_code == 202
    state = client.get(f'/api/v1/audio-sessions/{sid}').json()
    assert state['pipeline']['phase'] == 'completed' and state['transcript_id'] == session['transcript_id']
    with database() as db:
        assert db.scalar(select(Summary)).id is not None


def test_heartbeat_keeps_lease_during_gpu_queue_wait(client, database, monkeypatch):
    assembled(client, database)
    monkeypatch.setattr(settings, 'qwen_lease_seconds', 1)
    monkeypatch.setattr(settings, 'qwen_heartbeat_seconds', .05)
    record = claim(database)
    fake = FakeGenerator()
    engine = database.kw['bind']
    with engine.connect() as connection:
        connection.execute(text('SELECT pg_advisory_lock(:key)'), {'key':GPU_LOCK})
        connection.commit()
        with ThreadPoolExecutor(1) as pool:
            future = pool.submit(execute, database, record, fake)
            try:
                Event().wait(1.3)
                assert fake.calls == 0 and claim(database) is None
                with database() as db:
                    assert db.get(ProcessingJob, record['id']).lease_until > now()
            finally:
                connection.execute(text('SELECT pg_advisory_unlock(:key)'), {'key':GPU_LOCK})
                connection.commit()
            future.result(timeout=10)
    assert fake.calls == 1


def test_legacy_candidate_generation_hash_unchanged_by_new_catalog_version(client, database, monkeypatch):
    from fastapi import BackgroundTasks
    monkeypatch.setattr(BackgroundTasks, 'add_task', lambda *a, **kw: None)
    selection, _ = new_selection(client)
    first = candidate(client, selection)
    # Old stored options did not have the new computed catalog version field.
    with database.begin() as db:
        row = db.get(SummaryCandidate, UUID(first['id']))
        snapshot = dict(row.options['template_snapshot'])
        snapshot.pop('version')
        from app.services.variants import fingerprint
        options = {**row.options,'template_snapshot':snapshot}
        assert row.generation_hash == fingerprint(options)
        row.options = options
    repeated = candidate(client, selection, key='same-settings-new-operation-key')
    assert repeated['id'] == first['id']


def test_actual_dispatcher_singleton_and_crash_recovery(database):
    """Children target only the guarded _test DB, never a user service or GPU job."""
    from sqlalchemy.engine import make_url
    url = settings.test_database_url
    assert make_url(url).database.endswith('_test')
    env = dict(os.environ, DATABASE_URL=url, DEMO_ENABLED='false')
    # Avoid the Windows venv redirector so Popen.pid is the actual test worker.
    packages = Path(sys.executable).resolve().parents[1]/'Lib/site-packages'
    env['PYTHONPATH'] = os.pathsep.join([str(packages), env.get('PYTHONPATH', '')])
    script = Path(__file__).resolve().parents[1]/'scripts/qwen_worker.py'
    children = []
    def spawn():
        flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
        child = subprocess.Popen([sys._base_executable, str(script)], cwd=script.parents[1], env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=flags)
        children.append(child)
        return child
    def wait_pid(pid):
        deadline = time.monotonic()+10
        while time.monotonic()<deadline:
            with database() as db:
                state = db.get(QwenWorkerState, 1)
                if state and state.pid == pid and (now()-state.heartbeat_at).total_seconds()<3:
                    return
            assert children[-1].poll() is None, 'Test dispatcher failed to start'
            Event().wait(.1)
        raise AssertionError('No test dispatcher heartbeat')
    try:
        first = spawn()
        wait_pid(first.pid)
        second = spawn()
        assert second.wait(timeout=10) == 0
        assert first.poll() is None
        # Kill only our own child to simulate crash and release its PG session lock.
        first.terminate()
        first.wait(timeout=10)
        third = spawn()
        wait_pid(third.pid)
        assert third.poll() is None
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=10)

