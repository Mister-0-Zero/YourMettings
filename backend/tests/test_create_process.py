import threading
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi import BackgroundTasks
from sqlalchemy import func, select, text

from app.db.models import Summary, Transcript
from app.integrations.ollama import get_generator
from app.main import app
from test_processing import FakeGenerator

pytestmark = pytest.mark.integration
URL = "/api/v1/transcripts/process"


def request_body(client):
    folder = client.post("/api/v1/folders", json={"name": "Combined"}).json()["id"]
    return {"text": "Исходный текст встречи", "title": "Planning", "folder_ids": [folder]}


def test_atomic_creation_visible_before_llm_and_summary_saved(client, database):
    body = request_body(client)
    class InspectGenerator(FakeGenerator):
        def generate(self, source):
            with database() as db:
                row = db.scalar(select(Transcript))
                assert row.text == source == body["text"]
                assert row.processing_status == "summarizing"
                assert row.processing_title == body["title"]
                assert list(map(str, row.processing_folder_ids)) == body["folder_ids"]
                assert row.processing_attempt == 1
                assert db.scalar(text("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='idle in transaction'")) == 0
            return super().generate(source)
    fake = InspectGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    response = client.post(URL, json=body)
    assert response.status_code == 202
    accepted = response.json()
    assert accepted["status"] == "summarizing"
    tid = accepted["transcript_id"]
    state = client.get(f"/api/v1/transcripts/{tid}/processing").json()
    assert state["status"] == "ready"
    result = client.get(f'/api/v1/summaries/{state["summary_id"]}').json()
    assert result["title"] == body["title"] and result["folder_ids"] == body["folder_ids"]
    assert "Проверенный результат" in result["content"]
    assert fake.calls == 1


def test_error_preserves_text_and_repeat_does_not_restart(client, database):
    body = request_body(client)
    fake = FakeGenerator(error="llm_timeout")
    app.dependency_overrides[get_generator] = lambda: fake
    headers = {"Idempotency-Key": "error-key"}
    tid = client.post(URL, json=body, headers=headers).json()["transcript_id"]
    repeat = client.post(URL, json=body, headers=headers)
    assert repeat.status_code == 202 and repeat.json()["status"] == "error"
    assert repeat.json()["transcript_id"] == tid and fake.calls == 1
    assert client.get(f"/api/v1/transcripts/{tid}").json()["text"] == body["text"]
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "Исправленный текст"}).status_code == 200
    assert client.post(URL, json=body, headers=headers).json()["transcript_id"] == tid
    success = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: success
    retry = client.post(f"/api/v1/transcripts/{tid}/process", json={"title": body["title"], "folder_ids": body["folder_ids"]})
    assert retry.status_code == 202
    assert client.get(f"/api/v1/transcripts/{tid}/processing").json()["status"] == "ready"
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "edit"}).status_code == 409
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Transcript)) == 1


@pytest.mark.parametrize("field", ["text", "title", "folder_ids"])
def test_changed_original_parameters_conflict(client, field):
    body = request_body(client)
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    headers = {"Idempotency-Key": "same"}
    first = client.post(URL, json=body, headers=headers)
    assert first.status_code == 202
    changed = dict(body)
    changed[field] = [str(uuid.uuid4())] if field == "folder_ids" else "different"
    conflict = client.post(URL, json=changed, headers=headers)
    assert conflict.status_code == 409 and conflict.json()["error"]["code"] == "idempotency_conflict"
    repeat = client.post(URL, json=body, headers=headers)
    assert repeat.status_code == 202 and repeat.json()["status"] == "ready"
    assert fake.calls == 1


def test_concurrent_same_key_creates_and_generates_once(client, database):
    body = request_body(client)
    started, release = threading.Event(), threading.Event()
    fake = FakeGenerator(started=started, release=release)
    app.dependency_overrides[get_generator] = lambda: fake
    headers = {"Idempotency-Key": "concurrent"}
    with ThreadPoolExecutor(max_workers=5) as pool:
        first = pool.submit(client.post, URL, json=body, headers=headers)
        assert started.wait(5)
        try:
            futures = [pool.submit(client.post, URL, json=body, headers=headers) for _ in range(3)]
            responses = [future.result(timeout=5) for future in futures]
            assert all(r.status_code == 202 for r in responses)
            tids = {r.json()["transcript_id"] for r in responses}
            assert len(tids) == 1
            tid = tids.pop()
            assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "edit"}).status_code == 409
            changed = dict(body, title="other")
            assert client.post(URL, json=changed, headers=headers).status_code == 409
        finally:
            release.set()
        assert first.result(timeout=5).json()["transcript_id"] == tid
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Transcript)) == 1
        assert db.scalar(select(func.count()).select_from(Summary)) == 1
    assert fake.calls == 1


def test_uncommitted_identical_requests_are_serialized(client, database):
    body = request_body(client)
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    barrier = threading.Barrier(4)
    def send():
        barrier.wait(timeout=5)
        return client.post(URL, json=body, headers={"Idempotency-Key": "race"})
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(send) for _ in range(4)]
        responses = [future.result(timeout=10) for future in futures]
    assert all(r.status_code == 202 for r in responses)
    assert len({r.json()["transcript_id"] for r in responses}) == 1
    assert fake.calls == 1


def test_committed_but_unscheduled_processing_recovers_on_restart(client, database, monkeypatch):
    body = request_body(client)
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    headers = {"Idempotency-Key": "interrupted"}
    original = BackgroundTasks.add_task
    # Simulate a scheduling gap after commit without starting the worker.
    monkeypatch.setattr(BackgroundTasks, "add_task", lambda *args, **kwargs: None)
    tid = client.post(URL, json=body, headers=headers).json()["transcript_id"]
    assert client.get(f"/api/v1/transcripts/{tid}/processing").json()["status"] == "summarizing"
    monkeypatch.setattr(BackgroundTasks, "add_task", original)
    # Exercise the actual app lifespan startup, rather than only the SQL helper.
    import asyncio
    async def restart():
        async with app.router.lifespan_context(app):
            pass
    asyncio.run(restart())
    response = client.post(URL, json=body, headers=headers)
    assert response.json()["status"] == "error"
    assert response.json()["error"]["code"] == "processing_interrupted"
    assert response.json()["transcript_id"] == tid and fake.calls == 0
    assert client.get(f"/api/v1/transcripts/{tid}").json()["text"] == body["text"]
    client.post(f"/api/v1/transcripts/{tid}/process", json={"title": body["title"], "folder_ids": body["folder_ids"]})
    assert fake.calls == 1


def test_invalid_folder_rolls_back_creation_and_key_is_reusable(client, database):
    body = request_body(client)
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    headers = {"Idempotency-Key": "validation"}
    assert client.post(URL, json=dict(body, folder_ids=[str(uuid.uuid4())]), headers=headers).status_code == 404
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Transcript)) == 0
    assert client.post(URL, json=body, headers=headers).status_code == 202
    assert fake.calls == 1


def test_keys_are_shared_between_creation_endpoints(client):
    body = request_body(client)
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    headers = {"Idempotency-Key": "combined"}
    client.post(URL, json=body, headers=headers)
    assert client.post("/api/v1/transcripts", json={"text": body["text"]}, headers=headers).status_code == 409
    legacy_headers = {"Idempotency-Key": "legacy"}
    client.post("/api/v1/transcripts", json={"text": body["text"]}, headers=legacy_headers)
    assert client.post(URL, json=body, headers=legacy_headers).status_code == 409
