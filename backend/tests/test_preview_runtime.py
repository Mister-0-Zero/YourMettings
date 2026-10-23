"""Durable previews: deadlines, idempotency, restart and cancellation fences."""
from datetime import timedelta
from uuid import uuid4, UUID

from fastapi import BackgroundTasks
from sqlalchemy import text

from app.core.config import settings
from app.db.session import TEST_USER_ID, initialize_database
from app.db.variant_models import SummaryCandidate, SummarySelection
from app.integrations.ollama import get_generator
from app.main import app
from app.services.gpu import GPU_LOCK
from app.services import variants
from test_templates import definition
from test_processing import FakeGenerator


def test_preview_waiting_for_gpu_expires_without_calling_model(database, monkeypatch):
    monkeypatch.setattr(settings, "asr_gpu_serial", True)
    monkeypatch.setattr(variants, "JOB_DEADLINE", timedelta(milliseconds=50))
    class NeverCalled:
        def generate(self, *args, **kwargs):
            raise AssertionError("Preview must expire while waiting for the GPU")
    with database.begin() as db:
        session = SummarySelection(user_id=TEST_USER_ID, kind="preview", idempotency_key="deadline",
            request_hash="a"*64, source_hash="b"*64, source_text="Temporary test",
            owns_transcript=False, folder_ids=[], expires_at=variants.now()+timedelta(hours=1))
        db.add(session)
        db.flush()
        candidate = SummaryCandidate(selection_id=session.id, generation_hash="c"*64, options={})
        db.add(candidate)
        db.flush()
        id = candidate.id
    engine = database.kw["bind"]
    with engine.connect() as occupied:
        occupied.execute(text("SELECT pg_advisory_lock(:key)"), {"key": GPU_LOCK})
        occupied.commit()
        try:
            variants.run_candidate(database, id, NeverCalled())
        finally:
            occupied.execute(text("SELECT pg_advisory_unlock(:key)"), {"key": GPU_LOCK})
            occupied.commit()
    with database() as db:
        item = db.get(SummaryCandidate, id)
        assert item.status == "error" and item.error_code == "llm_timeout"


def test_preview_idempotency_restart_and_expired_key_does_not_rerun(client, database):
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    body = {"text": "Тест", "template": definition()}
    headers = {"Idempotency-Key": "same-preview"}
    first = client.post("/api/v1/template-previews", json=body, headers=headers).json()
    initialize_database(database)
    again = client.post("/api/v1/template-previews", json=body, headers=headers).json()
    assert first["id"] == again["id"] and again["status"] == "ready" and fake.calls == 1
    assert client.post("/api/v1/template-previews", json={**body, "text": "Другой"}, headers=headers).status_code == 409
    with database.begin() as db:
        candidate = db.get(SummaryCandidate, UUID(first["id"]))
        db.get(SummarySelection, candidate.selection_id).expires_at = variants.now()-timedelta(seconds=1)
    assert client.post("/api/v1/template-previews", json=body, headers=headers).status_code == 410
    assert fake.calls == 1


def test_cancelled_preview_cannot_publish_late_result(client, database, monkeypatch):
    monkeypatch.setattr(BackgroundTasks, "add_task", lambda *a, **k: None)
    body = {"text": "Тест", "template": definition()}
    accepted = client.post("/api/v1/template-previews", json=body).json()
    id = accepted["id"]
    assert client.delete(f"/api/v1/template-previews/{id}").status_code == 422
    class CancelDuringCall:
        def generate(self, *args, **kwargs):
            assert client.delete(f"/api/v1/template-previews/{id}?confirm=true").status_code == 204
            return "## Late\nMust not reappear"
    variants.run_candidate(database, UUID(id), CancelDuringCall())
    assert client.get(f"/api/v1/template-previews/{id}").status_code == 410
    with database() as db:
        item = db.get(SummaryCandidate, UUID(id))
        assert item.content is None and item.options is None


def test_long_preview_accepts_complete_input_and_rejects_word_overflow(client):
    class Capture(FakeGenerator):
        def generate(self, source, *, options=None):
            assert len(source.split()) == 5000 and source.endswith("ПОСЛЕДНИЙ")
            return super().generate(source, options=options)
    app.dependency_overrides[get_generator] = lambda: Capture()
    body = {"text": "первый " + "совещание "*4998 + "ПОСЛЕДНИЙ", "template": definition()}
    assert client.post("/api/v1/template-previews", json=body).status_code == 202
    assert client.post("/api/v1/template-previews", json={**body, "text": "слово "*15001}).status_code == 413


def test_lost_background_callback_times_out_without_restart(client, database, monkeypatch):
    callbacks = []
    monkeypatch.setattr(BackgroundTasks, "add_task", lambda self, fn, *a, **k: callbacks.append((fn, a, k)))
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    headers = {"Idempotency-Key": "lost-callback"}
    body = {"text": "Тест", "template": definition()}
    first = client.post("/api/v1/template-previews", json=body, headers=headers).json()
    with database.begin() as db:
        db.get(SummaryCandidate, UUID(first["id"])).created_at = variants.now()-timedelta(minutes=31)
    current = client.get(f"/api/v1/template-previews/{first['id']}").json()
    assert current["status"] == "error" and current["error"]["code"] == "llm_timeout"
    assert client.post("/api/v1/template-previews", json=body, headers=headers).json()["id"] == first["id"]
    fn, args, kwargs = callbacks[0]
    fn(*args, **kwargs)
    assert fake.calls == 0
