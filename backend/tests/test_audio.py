import hashlib
import io
import uuid
import wave
import threading
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

import pytest
from sqlalchemy import func, select, text
from app.core.config import settings
from app.db.audio_models import AudioChunk, AudioSession
from app.db.models import Transcript
from app.db.session import initialize_database
from app.integrations.ollama import get_generator
from app.main import app
from app.services.audio import claim_chunk, finish_chunk, merge_texts, recover_worker
from test_processing import FakeGenerator

pytestmark = pytest.mark.integration
BASE = "/api/v1/audio-sessions"


def wav_bytes(value=0):
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(int(value).to_bytes(2, "little", signed=True) * 3200)
    return output.getvalue()


def session(client, **kwargs):
    fid = client.post("/api/v1/folders", json={"name": str(uuid.uuid4())}).json()["id"]
    body = {"title": "Аудиозапись", "folder_ids": [fid]}
    result = client.post(BASE, json=body, **kwargs)
    assert result.status_code == 201, result.text
    return result.json()["id"], body


def upload(client, sid, seq=0, *, data=None, start=None, **params):
    return client.post(f"{BASE}/{sid}/chunks", params={"sequence_number": seq,
        "start_ms": seq * 200 if start is None else start, **params},
        content=wav_bytes() if data is None else data, headers={"Content-Type": "application/octet-stream"})


def worker(database):
    generation = uuid.uuid4()
    with database.begin() as db:
        recover_worker(db, generation, 999)
    return generation


def do_job(database, generation, value="Текст совещания.", error=None):
    with database.begin() as db:
        job = claim_chunk(db, generation)
    assert job and job["payload"]
    # A separate connection sees the durable input before inference; no open tx.
    with database() as db:
        assert db.get(AudioChunk, job["id"]).payload == wav_bytes()
        assert db.scalar(text("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='idle in transaction'")) == 0
    with database.begin() as db:
        assert finish_chunk(db, job, generation, text=value, error=error)
    return job


def test_create_idempotent_and_conflict(client, database):
    sid, body = session(client, headers={"Idempotency-Key": "session-key"})
    retry = client.post(BASE, json=body, headers={"Idempotency-Key": "session-key"})
    assert retry.status_code == 200 and retry.json()["id"] == sid
    assert client.post(BASE, json={**body, "title": "other"}, headers={"Idempotency-Key": "session-key"}).status_code == 409
    with database() as db:
        assert db.scalar(select(func.count()).select_from(AudioSession)) == 1


def test_upload_durable_duplicate_conflict_and_cleanup(client, database):
    sid, _ = session(client)
    result = upload(client, sid)
    assert result.status_code == 201 and result.json()["safe_to_delete_local"] is True
    assert result.json()["chunk"]["duration_ms"] == 200
    assert upload(client, sid).status_code == 200
    assert upload(client, sid, data=wav_bytes(1)).status_code == 409
    assert upload(client, sid, start=1).status_code == 409
    generation = worker(database)
    job = do_job(database, generation)
    with database() as db:
        assert db.get(AudioChunk, job["id"]).payload is None
    assert upload(client, sid).status_code == 200  # Hash remains after audio cleanup.


def test_simultaneous_uploads_do_not_duplicate(client, database):
    sid, _ = session(client)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: upload(client, sid), range(2)))
    assert sorted(r.status_code for r in results) == [200, 201]
    with database() as db:
        assert db.scalar(select(func.count()).select_from(AudioChunk)) == 1


def test_only_one_claim_for_a_chunk(client, database):
    sid, _ = session(client)
    upload(client, sid)
    generation = worker(database)
    def claim():
        with database.begin() as db:
            return claim_chunk(db, generation)
    with ThreadPoolExecutor(max_workers=2) as pool:
        jobs = list(pool.map(lambda _: claim(), range(2)))
    assert sum(job is not None for job in jobs) == 1


def test_invalid_audio_limits_and_checksum(client, monkeypatch):
    sid, _ = session(client)
    assert upload(client, sid, data=b"not audio").status_code == 422
    assert upload(client, sid, data=wav_bytes()[:40]).status_code == 422
    assert upload(client, sid, duration_ms=5000).status_code == 422
    assert upload(client, sid, content_sha256="0"*64).status_code == 422
    monkeypatch.setattr(settings, "audio_max_upload_bytes", 100)
    assert upload(client, sid).status_code == 413
    monkeypatch.setattr(settings, "audio_max_upload_bytes", 32000)
    monkeypatch.setattr(settings, "audio_chunk_max_seconds", .1)
    assert upload(client, sid).status_code == 413
    monkeypatch.setattr(settings, "audio_chunk_max_seconds", 360)
    assert client.get(f"{BASE}/{sid}").json()["received_chunk_count"] == 0


def test_out_of_order_missing_and_complete_during_asr(client, database):
    sid, _ = session(client)
    upload(client, sid, 1)
    state = client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 2}).json()
    assert state["missing_sequence_numbers"] == [0] and state["transcript_id"] is None
    generation = worker(database)
    do_job(database, generation, "Второй фрагмент.")
    assert client.get(f"{BASE}/{sid}").json()["transcript_id"] is None
    upload(client, sid, 0)
    with database.begin() as db:
        job = claim_chunk(db, generation)
    state = client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 2}).json()
    assert state["status"] == "transcribing" and state["transcript_id"] is None
    with database.begin() as db:
        finish_chunk(db, job, generation, text="Первый фрагмент.")
    state = client.get(f"{BASE}/{sid}").json()
    assert state["status"] == "ready_for_review" and state["transcribed_chunk_count"] == 2
    source = client.get(f"/api/v1/transcripts/{state['transcript_id']}").json()
    assert source["text"] == "Первый фрагмент.\n\nВторой фрагмент."
    assert upload(client, sid, 2).status_code == 409
    assert client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 1}).status_code == 409
    client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 2})
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Transcript)) == 1


def test_failed_chunk_retry_preserves_other_text(client, database):
    sid, _ = session(client)
    upload(client, sid, 0)
    upload(client, sid, 1)
    client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 2})
    generation = worker(database)
    good = do_job(database, generation, "Один.")
    bad = do_job(database, generation, error="asr_gpu_memory")
    state = client.get(f"{BASE}/{sid}").json()
    assert state["status"] == "failed" and state["transcribed_chunk_count"] == 1
    with database() as db:
        assert db.get(AudioChunk, bad["id"]).payload is not None
        assert db.get(AudioChunk, good["id"]).text == "Один."
    assert client.post(f"{BASE}/{sid}/retry", json={"sequence_numbers": [5]}).status_code == 404
    client.post(f"{BASE}/{sid}/retry", json={"sequence_numbers": [1]})
    do_job(database, generation, "Два.")
    assert client.get(f"{BASE}/{sid}").json()["status"] == "ready_for_review"


def test_worker_restart_fences_old_result_and_backend_restart_preserves_queue(client, database):
    sid, _ = session(client)
    upload(client, sid)
    old = worker(database)
    with database.begin() as db:
        abandoned = claim_chunk(db, old)
    initialize_database(database)  # Same recovery invoked by FastAPI startup.
    assert client.get(f"{BASE}/{sid}").json()["chunks"][0]["status"] == "transcribing"
    new = worker(database)
    with database.begin() as db:
        assert not finish_chunk(db, abandoned, old, text="stale")
    job = do_job(database, new, "Recovered.")
    assert job["attempt"] == 2
    assert client.get(f"{BASE}/{sid}").json()["chunks"][0]["text"] == "Recovered."


def test_review_edit_confirm_once_and_delete_cleanup(client, database):
    sid, body = session(client)
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    assert client.post(f"{BASE}/{sid}/confirm", json={**body, "confirm": True, "reviewed_text_sha256": "0"*64}).status_code == 409
    upload(client, sid)
    client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 1})
    do_job(database, worker(database))
    state = client.get(f"{BASE}/{sid}").json()
    tid = state["transcript_id"]
    assert fake.calls == 0
    assert client.post(f"/api/v1/transcripts/{tid}/process", json=body).status_code == 409
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "Исправленный текст."}).status_code == 200
    confirmation = {**body, "confirm": True, "reviewed_text_sha256": state["transcript_sha256"]}
    assert client.post(f"{BASE}/{sid}/confirm", json=confirmation).status_code == 409
    confirmation["reviewed_text_sha256"] = hashlib.sha256("Исправленный текст.".encode()).hexdigest()
    accepted = client.post(f"{BASE}/{sid}/confirm", json=confirmation)
    assert accepted.status_code == 202, accepted.text
    assert client.post(f"{BASE}/{sid}/confirm", json=confirmation).status_code == 200
    assert fake.calls == 1
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "changed"}).status_code == 409
    summary_id = client.get(f"/api/v1/transcripts/{tid}/processing").json()["summary_id"]
    assert client.delete(f"/api/v1/summaries/{summary_id}").status_code == 204
    assert client.get(f"{BASE}/{sid}").status_code == 404
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 404


@pytest.mark.parametrize("second, warning, expected", [
    ("общие планы. Следующая тема.", False, "Начало и общие планы.\n\nСледующая тема."),
    ("Другая формулировка.", True, "Начало и общие планы.\n\nДругая формулировка."),
])
def test_overlap_preserves_uncertain_text(second, warning, expected):
    chunks = [SimpleNamespace(start_ms=0, overlap_ms=0, duration_ms=5000, text="Начало и общие планы.", sequence_number=0),
        SimpleNamespace(start_ms=4000, overlap_ms=1000, duration_ms=5000, text=second, sequence_number=1)]
    result, warnings = merge_texts(chunks)
    assert result == expected and bool(warnings) == warning


def test_timeline_gap_is_not_silently_assembled(client, database):
    sid, _ = session(client)
    upload(client, sid, 0)
    upload(client, sid, 1, start=5000)
    client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 2})
    gen = worker(database)
    do_job(database, gen)
    do_job(database, gen)
    state = client.get(f"{BASE}/{sid}").json()
    assert state["status"] == "failed" and state["error_code"] == "timeline_mismatch"
    assert state["transcript_id"] is None


def test_interrupted_upload_never_acknowledges_or_queues(client):
    sid, _ = session(client)
    def interrupted():
        yield wav_bytes()[:50]
        raise RuntimeError("connection interrupted")
    with pytest.raises(RuntimeError, match="connection interrupted"):
        upload(client, sid, data=interrupted())
    assert client.get(f"{BASE}/{sid}").json()["received_chunk_count"] == 0


def test_boundary_review_is_required_and_llm_error_uses_existing_retry(client, database):
    sid, body = session(client)
    upload(client, sid)
    client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 1})
    do_job(database, worker(database))
    with database.begin() as db:
        item = db.get(AudioSession, uuid.UUID(sid))
        item.boundary_warnings = [{"sequence_number": 0, "code": "overlap_not_aligned"}]
    state = client.get(f"{BASE}/{sid}").json()
    params = {**body, "confirm": True, "reviewed_text_sha256": state["transcript_sha256"]}
    assert client.post(f"{BASE}/{sid}/confirm", json=params).status_code == 409
    fake = FakeGenerator(error="llm_unavailable")
    app.dependency_overrides[get_generator] = lambda: fake
    assert client.post(f"{BASE}/{sid}/confirm", json={**params, "boundaries_reviewed": True}).status_code == 202
    assert client.post(f"{BASE}/{sid}/confirm", json=params).status_code == 200
    assert fake.calls == 1
    tid = state["transcript_id"]
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "Исправлено после ошибки."}).status_code == 200
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    assert client.post(f"/api/v1/transcripts/{tid}/process", json=body).status_code == 202
    assert client.get(f"/api/v1/transcripts/{tid}/processing").json()["status"] == "ready"


def test_concurrent_confirm_is_single_generation(client, database):
    sid, body = session(client)
    upload(client, sid)
    client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 1})
    do_job(database, worker(database))
    state = client.get(f"{BASE}/{sid}").json()
    started, release = threading.Event(), threading.Event()
    fake = FakeGenerator(started=started, release=release)
    app.dependency_overrides[get_generator] = lambda: fake
    confirmation = {**body, "confirm": True, "reviewed_text_sha256": state["transcript_sha256"]}
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(client.post, f"{BASE}/{sid}/confirm", json=confirmation)
        assert started.wait(5)
        try:
            assert client.post(f"{BASE}/{sid}/confirm", json=confirmation).status_code == 200
        finally:
            release.set()
        assert first.result().status_code == 202
    assert fake.calls == 1
