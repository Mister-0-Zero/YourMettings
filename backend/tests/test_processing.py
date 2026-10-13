import threading
from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy import select

from app.db.models import Summary
from app.db.session import initialize_database
from app.integrations.ollama import LLMError, get_generator
from app.main import app

pytestmark = pytest.mark.integration


class FakeGenerator:
    def __init__(self, error=None, started=None, release=None):
        self.error, self.started, self.release = error, started, release
        self.calls = 0

    def generate(self, text):
        self.calls += 1
        if self.started:
            self.started.set()
            assert self.release.wait(10)
        if self.error:
            raise LLMError(self.error)
        return "## Решения\nПроверенный результат"


def prepare(client):
    folder = client.post("/api/v1/folders", json={"name": "folder"}).json()["id"]
    tid = client.post("/api/v1/transcripts", json={"text": "meeting"}).json()["id"]
    return tid, {"title": "Meeting", "folder_ids": [folder]}


def test_success_and_duplicate_processing(client, database):
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    tid, body = prepare(client)
    assert client.post(f"/api/v1/transcripts/{tid}/process", json=body).status_code == 202
    result = client.get(f"/api/v1/transcripts/{tid}/processing").json()
    assert result["status"] == "ready" and result["summary_id"]
    assert client.post(f"/api/v1/transcripts/{tid}/process", json=body).status_code == 200
    assert fake.calls == 1
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "edit"}).status_code == 409
    with database() as db:
        assert len(db.scalars(select(Summary)).all()) == 1


def test_failure_unlocks_and_retry_succeeds(client):
    tid, body = prepare(client)
    app.dependency_overrides[get_generator] = lambda: FakeGenerator(error="llm_timeout")
    client.post(f"/api/v1/transcripts/{tid}/process", json=body)
    assert client.get(f"/api/v1/transcripts/{tid}/processing").json()["error"]["code"] == "llm_timeout"
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "fixed"}).status_code == 200
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    client.post(f"/api/v1/transcripts/{tid}/process", json=body)
    assert client.get(f"/api/v1/transcripts/{tid}/processing").json()["status"] == "ready"


def test_generation_blocks_edit_and_parallel_duplicate(client, database):
    tid, body = prepare(client)
    started, release = threading.Event(), threading.Event()
    fake = FakeGenerator(started=started, release=release)
    app.dependency_overrides[get_generator] = lambda: fake
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(client.post, f"/api/v1/transcripts/{tid}/process", json=body)
        assert started.wait(5)
        try:
            assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "edit"}).status_code == 409
            assert client.post(f"/api/v1/transcripts/{tid}/process", json=body).status_code == 202
            # No transaction stays open in the worker during the fake LLM call.
            with database() as db:
                from sqlalchemy import text
                assert db.scalar(text("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='idle in transaction'")) == 0
        finally:
            release.set()
        assert first.result().status_code == 202
    assert fake.calls == 1


def test_restart_recovers_unfinished_processing(client, database):
    from app.db.models import Transcript
    tid, _ = prepare(client)
    with database.begin() as db:
        row = db.scalar(select(Transcript).where(Transcript.id == tid))
        row.processing_status = "summarizing"
    initialize_database(database)
    result = client.get(f"/api/v1/transcripts/{tid}/processing").json()
    assert result["status"] == "error"
    assert result["error"]["code"] == "processing_interrupted"
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "edit"}).status_code == 200
