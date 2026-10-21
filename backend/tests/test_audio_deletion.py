import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import func, select, text

from app.core.config import settings
from app.db.audio_models import AudioChunk, AudioSession, AudioSessionDeletion, ASRWorkerState
from app.db.models import Summary, Transcript, User
from app.db.session import TEST_USER_ID
from app.integrations.ollama import get_generator
from app.main import app
from app.services.audio import claim_chunk, finish_chunk, recover_worker
from app.services import audio_files
from test_audio import BASE, upload, worker, do_job, wav_bytes
from test_processing import FakeGenerator

pytestmark = pytest.mark.integration


def ready(client, database, *, key=None):
    key = key or str(uuid.uuid4())
    body = {"title": "Unconfirmed meeting"}
    result = client.post(BASE, json=body, headers={"Idempotency-Key": key})
    assert result.status_code == 201, result.text
    sid = result.json()["id"]
    assert upload(client, sid).status_code == 201
    assert client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 1}).status_code == 202
    generation = worker(database)
    job = do_job(database, generation)
    state = client.get(f"{BASE}/{sid}").json()
    assert state["status"] == "ready_for_review"
    return sid, state, key, body, generation, job


def delete(client, sid, **kwargs):
    return client.delete(f"{BASE}/{sid}", params={"confirm": "true"}, **kwargs)


def confirmation(client, state):
    fid = client.post("/api/v1/folders", json={"name": str(uuid.uuid4())}).json()["id"]
    return {"title": "Confirmed", "folder_ids": [fid], "confirm": True,
        "reviewed_text_sha256": state["transcript_sha256"]}


def test_delete_review_and_safe_repeat_with_retired_creation_key(client, database):
    sid, state, key, body, generation, job = ready(client, database)
    # POST retries remain blocked even if the reviewed transcript was edited.
    client.patch(f"/api/v1/transcripts/{state['transcript_id']}", json={"text": "Edited source"})
    first = delete(client, sid)
    assert first.status_code == 204 and first.content == b""
    assert delete(client, sid).status_code == 204
    assert client.get(f"{BASE}/{sid}").status_code == 404
    assert client.get(f"/api/v1/transcripts/{state['transcript_id']}").status_code == 404
    with database() as db:
        assert db.get(AudioSession, uuid.UUID(sid)) is None
        assert db.scalar(select(func.count()).select_from(AudioChunk)) == 0
        assert db.scalar(select(func.count()).select_from(Summary)) == 0
        receipt = db.get(AudioSessionDeletion, uuid.UUID(sid))
        assert receipt.user_id == TEST_USER_ID and receipt.idempotency_key == key
        assert db.get(ASRWorkerState, 1).generation == generation  # Shared worker state survives.
    old = client.post(BASE, json={**body, "folder_ids": []}, headers={"Idempotency-Key": key})
    assert old.status_code == 410 and old.json()["error"]["code"] == "audio_session_deleted"
    assert client.post(BASE, json={"title": "Other parameters"}, headers={"Idempotency-Key": key}).status_code == 409
    assert client.post(BASE, json=body, headers={"Idempotency-Key": "new-recording"}).status_code == 201
    with database.begin() as db:
        assert finish_chunk(db, job, generation, text="Late result") is False
    assert client.get(f"{BASE}/{sid}").status_code == 404
    assert upload(client, sid).status_code == 404
    assert client.post(f"{BASE}/{sid}/retry", json={}).status_code == 404
    assert client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 1}).status_code == 404


@pytest.mark.parametrize("query", [{}, {"confirm": "false"}])
def test_explicit_confirmation_is_required(client, database, query):
    sid, state, *_ = ready(client, database)
    result = client.delete(f"{BASE}/{sid}", params=query)
    assert result.status_code == 422 and result.json()["error"]["code"] == "confirmation_required"
    assert client.get(f"{BASE}/{sid}").json()["status"] == "ready_for_review"
    assert client.get(f"/api/v1/transcripts/{state['transcript_id']}").status_code == 200


def test_unknown_foreign_and_foreign_receipt_are_not_disclosed(client, database):
    assert delete(client, uuid.uuid4()).status_code == 404
    sid, state, key, body, *_ = ready(client, database)
    with database.begin() as db:
        other = User(email="foreign-audio@example.com")
        db.add(other)
        db.flush()
        db.get(AudioSession, uuid.UUID(sid)).user_id = other.id
    assert delete(client, sid).status_code == 404
    with database.begin() as db:
        db.get(AudioSession, uuid.UUID(sid)).user_id = TEST_USER_ID
    assert delete(client, sid).status_code == 204
    with database.begin() as db:
        db.get(AudioSessionDeletion, uuid.UUID(sid)).user_id = other.id
    assert delete(client, sid).status_code == 404
    # Receipt keys are scoped to their owner.
    assert client.post(BASE, json=body, headers={"Idempotency-Key": key}).status_code == 201


@pytest.mark.parametrize("status", ["recording", "transcribing", "failed", "completed"])
def test_unsupported_session_states_preserve_everything(client, database, status):
    sid, state, *_ = ready(client, database)
    with database.begin() as db:
        db.get(AudioSession, uuid.UUID(sid)).status = status
    result = delete(client, sid)
    assert result.status_code == 409 and result.json()["error"]["code"] == "audio_session_not_deletable"
    with database() as db:
        assert db.get(AudioSession, uuid.UUID(sid)).status == status
        assert db.get(Transcript, uuid.UUID(state["transcript_id"]))
        assert db.scalar(select(func.count()).select_from(AudioChunk)) == 1
        assert db.get(AudioSessionDeletion, uuid.UUID(sid)) is None


@pytest.mark.parametrize("chunk_status", ["queued", "transcribing", "failed"])
def test_inconsistent_ready_with_unfinished_job_is_rejected(client, database, chunk_status):
    sid, state, *_ = ready(client, database)
    with database.begin() as db:
        chunk = db.scalar(select(AudioChunk))
        chunk.status, chunk.payload = chunk_status, wav_bytes()
    assert delete(client, sid).status_code == 409
    with database() as db:
        assert db.scalar(select(AudioChunk)).payload == wav_bytes()


def test_qwen_attempt_cannot_be_deleted_by_forging_review_status(client, database):
    sid, state, *_ = ready(client, database)
    with database.begin() as db:
        source = db.get(Transcript, uuid.UUID(state["transcript_id"]))
        source.processing_status, source.processing_attempt = "error", 1
    assert delete(client, sid).status_code == 409


def test_shared_source_and_unrelated_meetings_are_preserved(client, database):
    sid, state, *_ = ready(client, database)
    other_sid, other_state, *_ = ready(client, database)
    with database.begin() as db:
        other = User(email="shared-audio@example.com")
        db.add(other)
        db.flush()
        shared = Summary(user_id=other.id, transcript_id=uuid.UUID(state["transcript_id"]), title="Shared", content="Keep this")
        db.add(shared)
        db.flush()
        shared_id = shared.id
    conflict = delete(client, sid)
    assert conflict.status_code == 409 and conflict.json()["error"]["code"] == "audio_session_in_use"
    assert delete(client, other_sid).status_code == 204
    with database() as db:
        assert db.get(Summary, shared_id).content == "Keep this"
        assert db.get(Transcript, uuid.UUID(state["transcript_id"]))
    assert client.get(f"{BASE}/{sid}").status_code == 200


@pytest.mark.parametrize("target", ["audio_sessions", "audio_chunks", "transcripts"])
def test_external_cascade_dependencies_are_conflicts(client, database, target):
    sid, state, _, _, _, job = ready(client, database)
    identifier = {"audio_sessions": uuid.UUID(sid), "audio_chunks": job["id"],
        "transcripts": uuid.UUID(state["transcript_id"])}[target]
    with database.begin() as db:
        db.execute(text(f"CREATE TABLE test_audio_dependency (id uuid PRIMARY KEY, reference uuid REFERENCES {target}(id) ON DELETE CASCADE)"))
        db.execute(text("INSERT INTO test_audio_dependency VALUES (:id, :reference)"), {"id": uuid.uuid4(), "reference": identifier})
    try:
        result = delete(client, sid)
        assert result.status_code == 409 and result.json()["error"]["code"] == "audio_session_in_use"
        with database() as db:
            assert db.scalar(text("SELECT count(*) FROM test_audio_dependency")) == 1
    finally:
        with database.begin() as db:
            db.execute(text("DROP TABLE test_audio_dependency"))


def test_known_session_files_only_are_removed(client, database, tmp_path, monkeypatch):
    sid, state, *_ = ready(client, database)
    monkeypatch.setattr(audio_files, "ASR_SCRATCH", tmp_path)
    own = tmp_path / f"job-{sid}-leftover"
    own.mkdir()
    (own / "audio.bin").write_bytes(wav_bytes())
    (own / "decode-copy").mkdir()
    (own / "decode-copy/input.wav").write_bytes(wav_bytes())
    foreign = tmp_path / f"job-{uuid.uuid4()}-other"
    foreign.mkdir()
    (foreign / "keep.bin").write_bytes(b"keep")
    assert delete(client, sid).status_code == 204
    assert not own.exists() and (foreign / "keep.bin").read_bytes() == b"keep"


def test_composite_chunk_dependency_cannot_be_cascaded_away(client, database):
    sid, state, *_ = ready(client, database)
    unrelated_sid, unrelated_state, *_ = ready(client, database)
    with database.begin() as db:
        db.execute(text("CREATE TABLE test_audio_dependency (session_id uuid, sequence_number integer, FOREIGN KEY (session_id, sequence_number) REFERENCES audio_chunks(session_id, sequence_number) ON DELETE CASCADE)"))
        db.execute(text("INSERT INTO test_audio_dependency VALUES (:id, 0)"), {"id": uuid.UUID(sid)})
    try:
        assert delete(client, sid).status_code == 409
        with database() as db:
            assert db.scalar(text("SELECT count(*) FROM test_audio_dependency")) == 1
        assert delete(client, unrelated_sid).status_code == 204
        assert client.get(f"{BASE}/{sid}").status_code == 200
    finally:
        with database.begin() as db:
            db.execute(text("DROP TABLE test_audio_dependency"))


def test_cleanup_failure_and_commit_failure_do_not_delete_database_state(client, database, monkeypatch):
    sid, state, *_ = ready(client, database)
    import app.services.audio_deletion as service
    def denied(*args):
        raise PermissionError("Locked disposable copy")
    monkeypatch.setattr(service, "cleanup_session_files", denied)
    result = delete(client, sid)
    assert result.status_code == 409 and result.json()["error"]["code"] == "audio_cleanup_failed"
    assert client.get(f"{BASE}/{sid}").status_code == 200
    monkeypatch.undo()
    import app.api.audio_sessions as api
    original = api.delete_unconfirmed_session
    def abort(*args, **kwargs):
        original(*args, **kwargs)
        raise RuntimeError("Before commit")
    monkeypatch.setattr(api, "delete_unconfirmed_session", abort)
    with pytest.raises(RuntimeError, match="Before commit"):
        delete(client, sid)
    with database() as db:
        assert db.get(AudioSession, uuid.UUID(sid)) and db.get(Transcript, uuid.UUID(state["transcript_id"]))
        assert db.get(AudioSessionDeletion, uuid.UUID(sid)) is None


def test_active_upload_blocks_deletion_and_aborted_stream_releases_guard(client, database, monkeypatch):
    sid, state, *_ = ready(client, database)
    import app.api.audio_sessions as api
    original = api.validate_audio
    entered, release = threading.Event(), threading.Event()
    def validating(data):
        entered.set()
        assert release.wait(10)
        return original(data)
    monkeypatch.setattr(api, "validate_audio", validating)
    with ThreadPoolExecutor(max_workers=2) as pool:
        duplicate = pool.submit(upload, client, sid)
        assert entered.wait(5)
        try:
            with database() as db:
                assert db.scalar(text("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='idle in transaction'")) == 0
            result = delete(client, sid)
            assert result.status_code == 409 and result.json()["error"]["code"] == "audio_session_busy"
        finally:
            release.set()
        assert duplicate.result().status_code == 200
    monkeypatch.undo()
    def interrupted():
        yield wav_bytes()[:50]
        raise RuntimeError("Upload interrupted")
    with pytest.raises(RuntimeError, match="Upload interrupted"):
        upload(client, sid, data=interrupted())
    assert delete(client, sid).status_code == 204


def test_delete_wins_confirm_retry_upload_and_concurrent_delete(client, database, monkeypatch):
    sid, state, key, body, *_ = ready(client, database)
    params = confirmation(client, state)
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    import app.services.audio_deletion as service
    entered, release = threading.Event(), threading.Event()
    def cleanup(*args):
        entered.set()
        assert release.wait(10)
    monkeypatch.setattr(service, "cleanup_session_files", cleanup)
    with ThreadPoolExecutor(max_workers=5) as pool:
        deletion = pool.submit(delete, client, sid)
        assert entered.wait(5)
        confirms = pool.submit(client.post, f"{BASE}/{sid}/confirm", json=params)
        retries = pool.submit(client.post, f"{BASE}/{sid}/retry", json={})
        uploads = pool.submit(upload, client, sid)
        repeats = pool.submit(delete, client, sid)
        release.set()
        assert deletion.result().status_code == 204
        assert confirms.result().status_code == 404
        assert retries.result().status_code == 404
        assert uploads.result().status_code == 404
        assert repeats.result().status_code == 204
    assert fake.calls == 0
    assert client.post(BASE, json=body, headers={"Idempotency-Key": key}).status_code == 410


def test_cancelled_upload_releases_its_session_lock(client, database):
    import anyio
    from app.services.audio_deletion import guard_audio_upload
    sid, state, *_ = ready(client, database)
    with database() as db:
        async def cancelled():
            with anyio.CancelScope() as scope:
                guard = guard_audio_upload(uuid.UUID(sid), db)
                await anext(guard)
                scope.cancel()
                try:
                    await anyio.sleep(0)
                finally:
                    await guard.aclose()
        anyio.run(cancelled)
    with database() as db:
        assert db.scalar(text("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND database=(SELECT oid FROM pg_database WHERE datname=current_database())")) == 0
    assert delete(client, sid).status_code == 204


def test_confirm_wins_deletion_and_preserves_summary_deletion_path(client, database):
    sid, state, *_ = ready(client, database)
    params = confirmation(client, state)
    started, release = threading.Event(), threading.Event()
    fake = FakeGenerator(started=started, release=release)
    app.dependency_overrides[get_generator] = lambda: fake
    with ThreadPoolExecutor(max_workers=2) as pool:
        confirmed = pool.submit(client.post, f"{BASE}/{sid}/confirm", json=params)
        assert started.wait(5)
        try:
            assert delete(client, sid).status_code == 409
        finally:
            release.set()
        assert confirmed.result().status_code == 202
    state = client.get(f"{BASE}/{sid}").json()
    assert state["processing"]["status"] == "ready" and fake.calls == 1
    assert delete(client, sid).status_code == 409
    assert client.delete(f"/api/v1/summaries/{state['processing']['summary_id']}").status_code == 204
    assert client.get(f"{BASE}/{sid}").status_code == 404
    # Only explicit draft deletion issues a deletion receipt.
    with database() as db:
        assert db.get(AudioSessionDeletion, uuid.UUID(sid)) is None


def test_migration_preserves_existing_ready_session(database, client):
    sid, state, *_ = ready(client, database)
    cfg = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    cfg.attributes["database_url"] = settings.test_database_url
    try:
        command.downgrade(cfg, "0004")
        command.upgrade(cfg, "head")
        command.check(cfg)
        assert client.get(f"{BASE}/{sid}").json() == state
        assert delete(client, sid).status_code == 204
    finally:
        command.upgrade(cfg, "head")
