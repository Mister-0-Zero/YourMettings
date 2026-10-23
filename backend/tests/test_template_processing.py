"""Template acceptance, immutable history and isolated preview integration tests."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest
from fastapi import BackgroundTasks
from sqlalchemy import func, select

from app.db.models import Folder, Summary, SummaryFolder, Transcript, User
from app.db.audio_models import AudioChunk, AudioSession
from app.db.template_models import SummaryTemplate
from app.db.session import TEST_USER_ID
from app.integrations.ollama import get_generator
from app.main import app
from app.services.template_catalog import DEFAULT_TEMPLATE_ID
from test_create_process import URL, request_body
from test_processing import FakeGenerator
from test_templates import PREFIX, definition

pytestmark = pytest.mark.integration
PREVIEWS = "/api/v1/template-previews"


def summary_for(client, tid):
    state = client.get(f"/api/v1/transcripts/{tid}/processing").json()
    assert state["status"] == "ready", state
    response = client.get(f"/api/v1/summaries/{state['summary_id']}")
    assert response.status_code == 200
    return response.json()


def test_snapshot_committed_before_generation_and_survives_edit_delete(client, database):
    saved = client.post(PREFIX, json=definition()).json()
    body = {**request_body(client), "template_id": saved["id"]}
    captured = []
    class Capture(FakeGenerator):
        def generate(self, text, *, options=None):
            captured.append(deepcopy(options["template_snapshot"]))
            with database() as db:
                row = db.scalar(select(Transcript))
                assert row.processing_options["template_snapshot"] == captured[0]
                assert db.scalar(select(func.count()).select_from(Summary)) == 0
            changed = definition()
            changed["name"] = "Изменён во время генерации"
            assert client.put(f"{PREFIX}/{saved['id']}", json=changed).status_code == 200
            assert client.delete(f"{PREFIX}/{saved['id']}").status_code == 204
            assert options["template_snapshot"] == captured[0]
            return super().generate(text, options=options)
    fake = Capture()
    app.dependency_overrides[get_generator] = lambda: fake
    response = client.post(URL, json=body)
    assert response.status_code == 202
    result = summary_for(client, response.json()["transcript_id"])
    assert result["template_snapshot"] == captured[0]
    assert result["template_snapshot"]["sections"] == saved["sections"]
    assert result["template_snapshot"]["name"] == saved["name"]
    assert fake.calls == 1


@pytest.mark.parametrize("foreign", [False, True])
def test_invalid_template_rolls_back_new_transcript_and_idempotency_key(client, database, foreign):
    missing = uuid4()
    if foreign:
        with database.begin() as db:
            owner = User(email="hidden-processing@example.test")
            db.add(owner)
            db.flush()
            row = SummaryTemplate(**definition(), owner_user_id=owner.id)
            db.add(row)
            db.flush()
            missing = row.id
    body = request_body(client)
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    headers = {"Idempotency-Key": "template-rollback"}
    invalid = client.post(URL, json={**body, "template_id": str(missing)}, headers=headers)
    assert invalid.status_code == 404
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Transcript)) == 0
        assert db.scalar(select(func.count()).select_from(Summary)) == 0
    assert fake.calls == 0
    assert client.post(URL, json=body, headers=headers).status_code == 202
    assert fake.calls == 1


def test_template_selection_affects_idempotency_and_default_preserves_original_hash(client, database):
    body = request_body(client)
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    headers = {"Idempotency-Key": "template-choice"}
    response = client.post(URL, json=body, headers=headers)
    assert response.status_code == 202
    tid = response.json()["transcript_id"]
    # Omitted and explicit null must share the legacy fingerprint.
    assert client.post(URL, json={**body, "template_id": None}, headers=headers).json()["transcript_id"] == tid
    changed = client.post(URL, json={**body, "template_id": str(DEFAULT_TEMPLATE_ID)}, headers=headers)
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "idempotency_conflict"
    assert summary_for(client, tid)["template_snapshot"]["id"] == str(DEFAULT_TEMPLATE_ID)


def test_failed_processing_retry_accepts_new_template(client, database):
    first = client.post(PREFIX, json=definition()).json()
    second_payload = definition()
    second_payload["name"] = "Для повтора"
    second = client.post(PREFIX, json=second_payload).json()
    body = {**request_body(client), "template_id": first["id"]}
    app.dependency_overrides[get_generator] = lambda: FakeGenerator(error="llm_timeout")
    tid = client.post(URL, json=body).json()["transcript_id"]
    assert client.get(f"/api/v1/transcripts/{tid}/processing").json()["status"] == "error"
    class Capture(FakeGenerator):
        def generate(self, text, *, options=None):
            assert options["template_snapshot"]["id"] == second["id"]
            with database() as db:
                row = db.get(Transcript, UUID(tid))
                assert row.processing_attempt == 2
                assert row.processing_options["template_snapshot"]["id"] == second["id"]
            return super().generate(text, options=options)
    app.dependency_overrides[get_generator] = lambda: Capture()
    retry = {k: v for k, v in body.items() if k != "text"}
    assert client.post(f"/api/v1/transcripts/{tid}/process", json={**retry, "template_id": second["id"]}).status_code == 202
    assert summary_for(client, tid)["template_snapshot"]["id"] == second["id"]


def test_audio_confirmation_uses_selected_template(client, database):
    from test_audio import BASE, do_job, session, upload, worker
    saved = client.post(PREFIX, json=definition()).json()
    sid, body = session(client)
    upload(client, sid)
    client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 1})
    do_job(database, worker(database))
    state = client.get(f"{BASE}/{sid}").json()
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    response = client.post(f"{BASE}/{sid}/confirm", json={**body,
        "confirm": True, "reviewed_text_sha256": state["transcript_sha256"], "template_id": saved["id"]})
    assert response.status_code == 202, response.text
    assert summary_for(client, state["transcript_id"])["template_snapshot"]["id"] == saved["id"]


def test_legacy_summary_has_null_snapshot_and_navigation_updates_on_edit(client, database):
    with database.begin() as db:
        source = Transcript(owner_user_id=TEST_USER_ID, text="Старый текст", source_hash="0" * 64)
        db.add(source)
        db.flush()
        row = Summary(user_id=TEST_USER_ID, transcript_id=source.id, title="Старый документ", content="## Старый заголовок\nФакт")
        db.add(row)
        db.flush()
        identifier = row.id
    old = client.get(f"/api/v1/summaries/{identifier}").json()
    assert old["template_snapshot"] is None
    assert old["navigation"][0]["title"] == "Старый заголовок"
    changed = client.patch(f"/api/v1/summaries/{identifier}", json={"content": "Вступление\n\n## Новая тема\n\n## Новая тема"}).json()
    assert changed["template_snapshot"] is None
    assert [(h["id"], h["title"], h["line_index"]) for h in changed["navigation"]] == [
        ("ym-h-0", "Новая тема", 2), ("ym-h-1", "Новая тема", 4)]


@pytest.fixture
def preview_store():
    from app.api import template_previews as previews
    return previews


def history_counts(database):
    with database() as db:
        return tuple(db.scalar(select(func.count()).select_from(model)) for model in
            (Transcript, Summary, Folder, SummaryFolder, AudioSession, AudioChunk, SummaryTemplate))


def test_preview_uses_unsaved_inline_draft_and_writes_no_history(client, database, preview_store):
    original = client.post(PREFIX, json=definition()).json()
    draft = definition("flexible")
    draft["name"] = "Несохранённые правки"
    before = history_counts(database)
    class Capture(FakeGenerator):
        def generate(self, text, *, options=None):
            assert text == "Тестовый текст"
            assert options["template_snapshot"] == draft
            assert options["detail_level"] == "detailed"
            assert options["focus_areas"] == ["decisions", "risks"]
            assert options["additional_instructions"] == "Раскрой аргументы"
            return super().generate(text, options=options)
    fake = Capture()
    app.dependency_overrides[get_generator] = lambda: fake
    response = client.post(PREVIEWS, json={"text": "Тестовый текст", "template": draft,
        "detail_level": "detailed", "focus_areas": ["risks", "decisions"], "additional_instructions": "Раскрой аргументы"})
    assert response.status_code == 202, response.text
    accepted = response.json()
    assert accepted["status"] == "queued" and accepted["expires_at"]
    ready = client.get(f"{PREVIEWS}/{accepted['id']}").json()
    assert ready["status"] == "ready" and "Проверенный результат" in ready["content"]
    assert ready["navigation"][0]["id"] == "ym-h-0"
    assert history_counts(database) == before
    assert client.get(f"{PREFIX}/{original['id']}").json()["name"] == original["name"]
    assert fake.calls == 1


def test_preview_error_is_pollable_and_retry_uses_new_job(client, preview_store):
    body = {"text": "Текст", "template": definition()}
    app.dependency_overrides[get_generator] = lambda: FakeGenerator(error="llm_timeout")
    first = client.post(PREVIEWS, json=body).json()
    failed = client.get(f"{PREVIEWS}/{first['id']}").json()
    assert failed["status"] == "error" and failed["error"]["code"] == "llm_timeout"
    assert failed["content"] is None
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    second = client.post(PREVIEWS, json=body).json()
    assert first["id"] != second["id"]
    assert client.get(f"{PREVIEWS}/{second['id']}").json()["status"] == "ready"


def test_preview_unknown_expired_and_ready_survives_restart(client, database, preview_store):
    from app.db.variant_models import SummarySelection, SummaryCandidate
    from app.db.session import initialize_database
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    assert client.get(f"{PREVIEWS}/{uuid4()}").status_code == 404
    identifier = client.post(PREVIEWS, json={"text": "Текст", "template": definition()}).json()["id"]
    with database.begin() as db:
        candidate = db.get(SummaryCandidate, UUID(identifier))
        session = db.get(SummarySelection, candidate.selection_id)
        session.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    assert client.get(f"{PREVIEWS}/{identifier}").status_code == 410
    with database() as db:
        candidate = db.get(SummaryCandidate, UUID(identifier))
        assert candidate.content is None and candidate.options is None
        assert db.get(SummarySelection, candidate.selection_id).source_text is None
    identifier = client.post(PREVIEWS, json={"text": "Текст", "template": definition()}).json()["id"]
    before = client.get(f"{PREVIEWS}/{identifier}").json()
    initialize_database(database)
    assert client.get(f"{PREVIEWS}/{identifier}").json() == before
    assert fake.calls == 2


def test_preview_active_limit_rejects_without_creating_history(client, database, preview_store, monkeypatch):
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    monkeypatch.setattr(BackgroundTasks, "add_task", lambda *args, **kwargs: None)
    body = {"text": "Текст", "template": definition()}
    before = history_counts(database)
    for _ in range(2):
        assert client.post(PREVIEWS, json=body).status_code == 202
    rejected = client.post(PREVIEWS, json=body)
    assert rejected.status_code == 429 and rejected.json()["error"]["code"] == "generation_busy"
    assert history_counts(database) == before
    from app.db.variant_models import SummaryCandidate
    with database() as db:
        assert db.scalar(select(func.count()).select_from(SummaryCandidate)) == 2



@pytest.mark.parametrize("deleted", [False, True], ids=["existing-session", "deletion-receipt"])
def test_legacy_audio_key_without_template_field_accepts_omitted_and_null(client, database, deleted):
    from app.db.audio_models import AudioSessionDeletion
    # Fixed pre-template persisted parameters and SHA256, independent of the current schema.
    parameters = {"title": "Legacy", "folder_ids": [], "detail_level": "normal",
        "focus_areas": [], "additional_instructions": ""}
    legacy_hash = "d791e7249a4a53fbc204d24791be10f43813383d251dbedcdc6b94ec2c96661d"
    identifier = uuid4()
    key = "accepted-before-templates"
    with database.begin() as db:
        if deleted:
            db.add(AudioSessionDeletion(session_id=identifier, user_id=TEST_USER_ID,
                idempotency_key=key, request_hash=legacy_hash))
        else:
            db.add(AudioSession(id=identifier, user_id=TEST_USER_ID, request_data=parameters,
                idempotency_key=key, request_hash=legacy_hash))
    headers = {"Idempotency-Key": key}
    for body in ({"title": "Legacy"}, {"title": "Legacy", "template_id": None}):
        response = client.post("/api/v1/audio-sessions", json=body, headers=headers)
        assert response.status_code == (410 if deleted else 200), response.text
        if deleted:
            assert response.json()["error"]["code"] == "audio_session_deleted"
        else:
            assert response.json()["id"] == str(identifier)
    changed = client.post("/api/v1/audio-sessions", json={"title": "Legacy",
        "template_id": str(DEFAULT_TEMPLATE_ID)}, headers=headers)
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "idempotency_conflict"
    with database() as db:
        assert db.scalar(select(func.count()).select_from(AudioSession)) == (0 if deleted else 1)
        assert db.scalar(select(func.count()).select_from(AudioSessionDeletion)) == (1 if deleted else 0)
