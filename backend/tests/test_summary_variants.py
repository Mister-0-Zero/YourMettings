"""PostgreSQL lifecycle/contract tests; all model and ASR input is synthetic."""
import hashlib
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from fastapi import BackgroundTasks
from sqlalchemy import func, select

from app.db.audio_models import AudioChunk, AudioSession
from app.db.models import Summary, Transcript, User
from app.db.session import initialize_database
from app.db.variant_models import CandidateRequest, SummaryCandidate, SummarySelection
from app.integrations.ollama import get_generator
from app.main import app
from app.services.variants import now
from test_audio import do_job, session as audio_session, upload, worker
from test_processing import FakeGenerator, prepare
from test_summaries import processed
from test_templates import definition

pytestmark = pytest.mark.integration
BASE = "/api/v1/summary-selections"


class RecordingGenerator(FakeGenerator):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.inputs = []

    def generate(self, text, *, options=None):
        self.inputs.append((text, options))
        super().generate(text, options=options)
        return f"## Variant {self.calls}\nSynthetic result {self.calls}"


@pytest.fixture
def generator():
    fake = RecordingGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    return fake


@pytest.fixture
def deferred(monkeypatch):
    """Persist queued jobs without running them, for deterministic restart tests."""
    tasks = []
    monkeypatch.setattr(BackgroundTasks, "add_task", lambda self, fn, *args, **kw: tasks.append((fn, args, kw)))
    return tasks


def create(client, body, key="selection"):
    return client.post(BASE, json=body, headers={"Idempotency-Key": key})


def new_selection(client, **overrides):
    folder = client.post("/api/v1/folders", json={"name": "Candidates"}).json()["id"]
    placement = {"title": "Synthetic meeting", "folder_ids": [folder]}
    body = {"text": "Synthetic beginning middle end.", **placement, **overrides}
    response = create(client, body)
    assert response.status_code == 201, response.text
    return response.json(), body


def candidate(client, selection, body=None, key="candidate"):
    response = client.post(f"{BASE}/{selection['id']}/candidates", json=body or {},
                           headers={"Idempotency-Key": key})
    assert response.status_code == 202, response.text
    return response.json()


def ready(client, item):
    response = client.get(f"/api/v1/summary-candidates/{item['id']}")
    assert response.status_code == 200, response.text
    result = response.json()
    assert result["status"] == "ready", result
    return result


def accept(client, selection, item, **overrides):
    body = {"candidate_id": item["id"]}
    if selection["summary_version"]:
        body["expected_version"] = selection["summary_version"]
    return client.post(f"{BASE}/{selection['id']}/accept", json={**body, **overrides})


def test_initial_candidates_do_not_enter_history_and_a_b_a_reuses(client, database, generator):
    selection, body = new_selection(client)
    templates = client.get("/api/v1/summary-templates").json()["items"]
    a_options, b_options = ({"template_id": templates[i]["id"]} for i in (0, 1))
    a = ready(client, candidate(client, selection, a_options, "A"))
    b = ready(client, candidate(client, selection, b_options, "B"))
    again = candidate(client, selection, a_options, "A-again")
    assert again["id"] == a["id"] and generator.calls == 2
    assert client.get("/api/v1/summaries").json()["total"] == 0
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 0
        assert db.get(Transcript, UUID(selection["transcript_id"])).text == body["text"]
    result = accept(client, selection, b)
    assert result.status_code == 200, result.text
    saved = result.json()
    assert saved["content"] == b["content"] and saved["template_snapshot"] == b["template_snapshot"]
    assert saved["navigation"] == b["navigation"] and saved["navigation"]
    assert saved["folder_ids"] == body["folder_ids"] and saved["title"] == body["title"]
    assert saved["transcript_id"] == selection["transcript_id"]
    assert client.get("/api/v1/summaries").json()["total"] == 1
    assert client.get(f"/api/v1/summary-candidates/{a['id']}").status_code == 410
    assert accept(client, selection, b).json() == saved
    assert accept(client, selection, a).status_code == 409


def test_existing_summary_unchanged_until_accept_and_current_folders_kept(client, database, generator):
    tid, sid, placement = processed(client)
    before = client.get(f"/api/v1/summaries/{sid}").json()
    selection = create(client, {"summary_id": sid}).json()
    chosen = ready(client, candidate(client, selection, {"detail_level": "detailed"}))
    assert client.get(f"/api/v1/summaries/{sid}").json() == before
    second = client.post("/api/v1/folders", json={"name": "Moved"}).json()["id"]
    assert client.put(f"/api/v1/summaries/{sid}/folders", json={"folder_ids": [second]}).status_code == 200
    result = accept(client, selection, chosen)
    assert result.status_code == 200, result.text
    saved = result.json()
    assert saved["id"] == sid and saved["transcript_id"] == tid
    assert saved["title"] == placement["title"] and saved["folder_ids"] == [second]
    assert saved["content"] == chosen["content"]
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 1


def test_template_snapshot_and_options_survive_catalog_edit_delete(client, database, generator):
    selection, _ = new_selection(client)
    template = client.post("/api/v1/summary-templates", json=definition()).json()
    options = {"template_id": template["id"], "detail_level": "brief", "focus_areas": ["risks", "tasks"],
               "additional_instructions": "Keep numerical evidence"}
    chosen = ready(client, candidate(client, selection, options))
    changed = definition()
    changed["name"] = "Replacement"
    assert client.put(f"/api/v1/summary-templates/{template['id']}", json=changed).status_code == 200
    assert client.delete(f"/api/v1/summary-templates/{template['id']}").status_code == 204
    assert chosen["template_snapshot"]["name"] == template["name"]
    assert chosen["template_snapshot"]["sections"] == template["sections"]
    expected_options = {**options, "focus_areas": ["risks", "tasks"]}
    assert chosen["generation_options"] == expected_options
    saved = accept(client, selection, chosen).json()
    assert saved["template_snapshot"] == chosen["template_snapshot"]
    with database() as db:
        assert db.get(Summary, UUID(saved["id"])).generation_options == expected_options


def test_selection_and_candidate_keys_are_durable_and_alias_conflicts(client, database, generator):
    selection, body = new_selection(client)
    repeat = create(client, body)
    assert repeat.status_code == 200 and repeat.json()["id"] == selection["id"]
    assert create(client, {**body, "text": "different"}).status_code == 409
    first = ready(client, candidate(client, selection, {"focus_areas": ["tasks", "risks"]}, "first"))
    alias = candidate(client, selection, {"focus_areas": ["risks", "tasks"]}, "alias")
    assert alias["id"] == first["id"] and generator.calls == 1
    initialize_database(database)
    again = candidate(client, selection, {"focus_areas": ["risks", "tasks"]}, "alias")
    assert again["id"] == first["id"] and generator.calls == 1
    conflict = client.post(f"{BASE}/{selection['id']}/candidates", json={"detail_level": "brief"},
                           headers={"Idempotency-Key": "alias"})
    assert conflict.status_code == 409 and conflict.json()["error"]["code"] == "idempotency_conflict"
    with database() as db:
        assert db.get(CandidateRequest, (UUID(selection["id"]), "alias")).candidate_id == UUID(first["id"])


@pytest.mark.parametrize("edit", [{"content": "Manual concurrent edit"}, {"title": "Manual new title"}])
def test_accept_rejects_parallel_manual_edit_without_partial_write(client, generator, edit):
    _, sid, _ = processed(client)
    selection = create(client, {"summary_id": sid}).json()
    chosen = ready(client, candidate(client, selection))
    edited = client.patch(f"/api/v1/summaries/{sid}", json=edit).json()
    response = accept(client, selection, chosen)
    assert response.status_code == 409 and response.json()["error"]["code"] == "summary_version_conflict"
    assert client.get(f"/api/v1/summaries/{sid}").json() == edited
    assert client.get(f"{BASE}/{selection['id']}").json()["status"] == "open"


def test_existing_accept_requires_version_and_receipt_stays_frozen(client, database, generator):
    _, sid, _ = processed(client)
    selection = create(client, {"summary_id": sid}).json()
    chosen = ready(client, candidate(client, selection))
    assert accept(client, selection, chosen, expected_version=None).status_code == 409
    saved = accept(client, selection, chosen).json()
    assert client.patch(f"/api/v1/summaries/{sid}", json={"content": "Later manual edit"}).status_code == 200
    initialize_database(database)
    assert accept(client, selection, chosen).json() == saved
    assert client.get(f"/api/v1/summaries/{sid}").json()["content"] == "Later manual edit"


@pytest.mark.parametrize("same", [False, True])
def test_concurrent_accepts_choose_exactly_one_result(client, database, generator, same):
    selection, _ = new_selection(client)
    a = ready(client, candidate(client, selection))
    b = ready(client, candidate(client, selection, {"detail_level": "brief"}, "B"))
    barrier = threading.Barrier(2)
    def attempt(item):
        barrier.wait(timeout=10)
        return accept(client, selection, item)
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(attempt, [a, a if same else b]))
    assert sorted(r.status_code for r in responses) == ([200, 200] if same else [200, 409])
    if same:
        assert responses[0].json() == responses[1].json()
    winner = next(r.json() for r in responses if r.status_code == 200)
    assert winner["content"] in (a["content"], b["content"])
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 1


def test_required_keys_confirmation_and_invalid_source_contract(client, generator):
    selection, body = new_selection(client)
    assert client.post(BASE, json=body).status_code == 422
    assert client.post(f"{BASE}/{selection['id']}/candidates", json={}).status_code == 422
    for bad in ({}, {**body, "transcript_id": str(uuid4())}, {**body, "folder_ids": []},
                {**body, "text": " "}, {"summary_id": str(uuid4()), "title": "forbidden"}):
        assert create(client, bad, str(uuid4())).status_code == 422
    assert client.delete(f"{BASE}/{selection['id']}").status_code == 422
    assert client.get(f"{BASE}/{selection['id']}").json()["status"] == "open"
    assert generator.calls == 0


@pytest.mark.parametrize("existing", [False, True])
def test_cancel_cleans_candidates_and_only_own_new_source(client, database, generator, existing):
    if existing:
        tid, sid, _ = processed(client)
        before = client.get(f"/api/v1/summaries/{sid}").json()
        selection = create(client, {"summary_id": sid}).json()
    else:
        selection, _ = new_selection(client)
        tid = selection["transcript_id"]
    chosen = ready(client, candidate(client, selection))
    assert client.delete(f"{BASE}/{selection['id']}?confirm=true").status_code == 204
    assert client.delete(f"{BASE}/{selection['id']}?confirm=true").status_code == 204
    assert accept(client, selection, chosen).status_code == 410
    with database() as db:
        row = db.get(SummaryCandidate, UUID(chosen["id"]))
        assert row.status == "discarded" and row.content is None and row.options is None
        assert db.get(SummarySelection, UUID(selection["id"])).source_text is None
        assert (db.get(Transcript, UUID(tid)) is not None) == existing
    if existing:
        assert client.get(f"/api/v1/summaries/{sid}").json() == before


@pytest.mark.parametrize("close", ["cancel", "expire", "delete"])
def test_late_generation_cannot_resurrect_closed_or_deleted_selection(client, database, generator, close):
    if close == "delete":
        _, sid, _ = processed(client)
        selection = create(client, {"summary_id": sid}).json()
    else:
        selection, _ = new_selection(client)
    started, release = threading.Event(), threading.Event()
    blocked = RecordingGenerator(started=started, release=release)
    app.dependency_overrides[get_generator] = lambda: blocked
    with ThreadPoolExecutor(max_workers=1) as pool:
        job = pool.submit(candidate, client, selection)
        assert started.wait(10)
        try:
            if close == "cancel":
                assert client.delete(f"{BASE}/{selection['id']}?confirm=true").status_code == 204
            elif close == "expire":
                with database.begin() as db:
                    db.get(SummarySelection, UUID(selection["id"])).expires_at = now() - timedelta(seconds=1)
                assert client.get(f"{BASE}/{selection['id']}").json()["status"] == "expired"
            else:
                assert client.delete(f"/api/v1/summaries/{sid}").status_code == 204
        finally:
            release.set()
        response = job.result(timeout=15)
    assert blocked.calls == 1
    polled = client.get(f"/api/v1/summary-candidates/{response['id']}")
    assert polled.status_code == 410
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 0
        if close == "delete":
            receipt = db.get(SummarySelection, UUID(selection["id"]))
            assert receipt is not None and receipt.status == "cancelled"
            assert receipt.source_text is None and receipt.accepted_response is None
            assert receipt.transcript_id is None and receipt.summary_id is None
            discarded = db.get(SummaryCandidate, UUID(response["id"]))
            assert discarded is not None and discarded.status == "discarded"
            assert discarded.content is None and discarded.options is None
        else:
            assert db.get(SummaryCandidate, UUID(response["id"])).content is None


@pytest.mark.parametrize("status", ["queued", "generating"])
def test_restart_marks_inflight_error_without_reexecution_and_new_key_retries(client, database, generator, deferred, status):
    selection, _ = new_selection(client)
    first = candidate(client, selection)
    with database.begin() as db:
        db.get(SummaryCandidate, UUID(first["id"])).status = status
    initialize_database(database)
    polled = client.get(f"/api/v1/summary-candidates/{first['id']}").json()
    assert polled["status"] == "error" and polled["error"]["code"] == "processing_interrupted"
    assert candidate(client, selection)["id"] == first["id"]
    assert len(deferred) == 1 and generator.calls == 0
    fn, args, kwargs = deferred[0]
    fn(*args, **kwargs)  # A stale queued callback must remain fenced after recovery.
    assert generator.calls == 0
    retried = candidate(client, selection, key="explicit-retry")
    assert retried["id"] != first["id"] and len(deferred) == 2
    fn, args, kwargs = deferred[1]
    fn(*args, **kwargs)
    assert ready(client, retried)["content"] and generator.calls == 1


def test_llm_error_preserves_source_and_explicit_retry(client, generator):
    selection, body = new_selection(client)
    generator.error = "llm_timeout"
    first = candidate(client, selection)
    result = client.get(f"/api/v1/summary-candidates/{first['id']}").json()
    assert result["status"] == "error" and result["error"]["code"] == "llm_timeout"
    assert accept(client, selection, first).status_code == 409
    assert candidate(client, selection)["id"] == first["id"] and generator.calls == 1
    assert client.get(f"/api/v1/transcripts/{selection['transcript_id']}").json()["text"] == body["text"]
    generator.error = None
    assert ready(client, candidate(client, selection, key="retry"))["content"]
    assert generator.calls == 2 and client.get("/api/v1/summaries").json()["total"] == 0


def test_source_is_guarded_and_accept_detects_out_of_band_change(client, database, generator):
    tid, placement = prepare(client)
    selection = create(client, {"transcript_id": tid, **placement}).json()
    chosen = ready(client, candidate(client, selection))
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "Changed"}).status_code == 409
    assert client.post(f"/api/v1/transcripts/{tid}/process", json=placement).status_code == 409
    with database.begin() as db:
        db.get(Transcript, UUID(tid)).text = "Out of band synthetic update"
    result = accept(client, selection, chosen)
    assert result.status_code == 409 and result.json()["error"]["code"] == "source_conflict"
    assert client.get("/api/v1/summaries").json()["total"] == 0


def test_audio_selection_uses_reviewed_asr_source_without_retranscribing(client, database, generator):
    sid, placement = audio_session(client)
    assert upload(client, sid).status_code == 201
    generation = worker(database)
    do_job(database, generation, value="Synthetic reviewed ASR meeting.")
    assert client.post(f"/api/v1/audio-sessions/{sid}/complete", json={"expected_chunk_count": 1}).status_code == 202
    audio = client.get(f"/api/v1/audio-sessions/{sid}").json()
    tid = audio["transcript_id"]
    text = client.get(f"/api/v1/transcripts/{tid}").json()["text"]
    body = {"audio_session_id": sid, **placement}
    assert create(client, body).status_code == 422
    assert create(client, {**body, "confirm": True, "reviewed_text_sha256": "0" * 64}).status_code == 409
    assert create(client, {"transcript_id": tid, **placement}).status_code == 409
    selection = create(client, {**body, "confirm": True, "reviewed_text_sha256": hashlib.sha256(text.encode()).hexdigest()}).json()
    chosen = ready(client, candidate(client, selection))
    assert generator.inputs[0][0] == text
    assert accept(client, selection, chosen).json()["transcript_id"] == tid
    assert client.get(f"/api/v1/audio-sessions/{sid}").json()["status"] == "completed"
    with database() as db:
        chunk = db.scalar(select(AudioChunk))
        assert chunk.status == "done" and chunk.attempt == 1
        assert db.scalar(select(func.count()).select_from(Transcript)) == 1
        assert db.scalar(select(func.count()).select_from(AudioSession)) == 1


def test_foreign_selection_and_candidate_are_hidden(client, database, generator):
    selection, body = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    with database.begin() as db:
        other = User(email="variant-owner@example.test")
        db.add(other)
        db.flush()
        db.get(SummarySelection, UUID(selection["id"])).user_id = other.id
    assert client.get(f"{BASE}/{selection['id']}").status_code == 404
    assert client.get(f"/api/v1/summary-candidates/{chosen['id']}").status_code == 404
    assert accept(client, selection, chosen).status_code == 404
    assert client.delete(f"{BASE}/{selection['id']}?confirm=true").status_code == 404
    assert client.post(f"{BASE}/{selection['id']}/candidates", json={}, headers={"Idempotency-Key": "attack"}).status_code == 404


@pytest.mark.parametrize("closed", ["cancelled", "expired"])
def test_closed_selection_keys_never_recreate_source(client, database, generator, closed):
    selection, body = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    if closed == "cancelled":
        assert client.delete(f"{BASE}/{selection['id']}?confirm=true").status_code == 204
    else:
        with database.begin() as db:
            db.get(SummarySelection, UUID(selection["id"])).expires_at = now() - timedelta(seconds=1)
        assert client.get(f"{BASE}/{selection['id']}").json()["status"] == "expired"
    initialize_database(database)
    assert create(client, body).status_code == 410
    assert accept(client, selection, chosen).status_code == 410
    assert client.get(f"/api/v1/summary-candidates/{chosen['id']}").status_code == 410
    with database() as db:
        assert db.get(Transcript, UUID(selection["transcript_id"])) is None
        assert db.scalar(select(func.count()).select_from(SummarySelection)) == 1
    assert generator.calls == 1


def test_pending_source_duplicate_process_and_audio_confirm_are_guarded(client, database, generator):
    sid, placement = audio_session(client)
    assert upload(client, sid).status_code == 201
    assert client.post(f"/api/v1/audio-sessions/{sid}/complete", json={"expected_chunk_count": 1}).status_code == 202
    do_job(database, worker(database))
    audio = client.get(f"/api/v1/audio-sessions/{sid}").json()
    confirmation = {**placement, "confirm": True, "reviewed_text_sha256": audio["transcript_sha256"]}
    selection = create(client, {"audio_session_id": sid, **confirmation}).json()
    assert create(client, {"audio_session_id": sid, **confirmation}, "second-selection").status_code == 409
    assert client.post(f"/api/v1/audio-sessions/{sid}/confirm", json=confirmation).status_code == 409
    assert client.patch(f"/api/v1/transcripts/{audio['transcript_id']}", json={"text": "Changed review"}).status_code == 409
    assert client.delete(f"{BASE}/{selection['id']}?confirm=true").status_code == 204
    assert client.get(f"/api/v1/audio-sessions/{sid}").json()["status"] == "ready_for_review"
    assert client.get(f"/api/v1/transcripts/{audio['transcript_id']}").status_code == 200


def test_manual_a_b_a_edit_still_invalidates_existing_selection(client, generator):
    _, sid, _ = processed(client)
    original = client.get(f"/api/v1/summaries/{sid}").json()
    selection = create(client, {"summary_id": sid}).json()
    chosen = ready(client, candidate(client, selection))
    assert client.patch(f"/api/v1/summaries/{sid}", json={"content": "Temporary manual edit"}).status_code == 200
    reverted = client.patch(f"/api/v1/summaries/{sid}", json={"content": original["content"]})
    assert reverted.status_code == 200
    response = accept(client, selection, chosen)
    assert response.status_code == 409 and response.json()["error"]["code"] == "summary_version_conflict"
    assert client.get(f"/api/v1/summaries/{sid}").json() == reverted.json()


def test_ready_audio_candidate_cancel_unlocks_review_and_allows_audio_delete(client, database, generator):
    sid, placement = audio_session(client)
    assert upload(client, sid).status_code == 201
    assert client.post(f"/api/v1/audio-sessions/{sid}/complete", json={"expected_chunk_count": 1}).status_code == 202
    do_job(database, worker(database), value="Synthetic ASR source awaiting review.")
    audio = client.get(f"/api/v1/audio-sessions/{sid}").json()
    tid = audio["transcript_id"]
    selection_response = create(client, {"audio_session_id": sid, **placement, "confirm": True,
                                        "reviewed_text_sha256": audio["transcript_sha256"]})
    assert selection_response.status_code == 201, selection_response.text
    selection = selection_response.json()
    chosen = ready(client, candidate(client, selection))
    assert client.get(f"/api/v1/transcripts/{tid}").json()["is_locked"] is True
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "Premature review edit"}).status_code == 409
    with database() as db:
        assert db.get(Transcript, UUID(tid)).first_processed_at is None
    assert client.delete(f"{BASE}/{selection['id']}?confirm=true").status_code == 204
    assert client.get(f"/api/v1/summary-candidates/{chosen['id']}").status_code == 410
    assert client.get(f"/api/v1/transcripts/{tid}").json()["is_locked"] is False
    edited = client.patch(f"/api/v1/transcripts/{tid}", json={"text": "Corrected synthetic ASR text"})
    assert edited.status_code == 200 and edited.json()["text"] == "Corrected synthetic ASR text"
    assert client.delete(f"/api/v1/audio-sessions/{sid}?confirm=true").status_code == 204
    assert client.get(f"/api/v1/audio-sessions/{sid}").status_code == 404
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 404
    assert client.get("/api/v1/summaries").json()["total"] == 0
    assert generator.calls == 1


def test_cancel_existing_summary_selection_preserves_permanent_source_lock(client, database, generator):
    tid, sid, _ = processed(client)
    before = client.get(f"/api/v1/summaries/{sid}").json()
    with database() as db:
        first_processed = db.get(Transcript, UUID(tid)).first_processed_at
        assert first_processed is not None
    selection_response = create(client, {"summary_id": sid})
    assert selection_response.status_code == 201, selection_response.text
    selection = selection_response.json()
    ready(client, candidate(client, selection))
    assert client.delete(f"{BASE}/{selection['id']}?confirm=true").status_code == 204
    assert client.get(f"/api/v1/transcripts/{tid}").json()["is_locked"] is True
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "Forbidden saved-source edit"}).status_code == 409
    assert client.get(f"/api/v1/summaries/{sid}").json() == before
    with database() as db:
        assert db.get(Transcript, UUID(tid)).first_processed_at == first_processed


def test_deleted_accepted_initial_summary_keeps_key_tombstone_without_private_payloads(client, database, generator):
    selection, body = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    accepted = accept(client, selection, chosen)
    assert accepted.status_code == 200, accepted.text
    sid = accepted.json()["id"]
    assert client.delete(f"/api/v1/summaries/{sid}").status_code == 204
    assert create(client, body).status_code == 410
    assert accept(client, selection, chosen).status_code == 410
    assert client.get(f"/api/v1/summary-candidates/{chosen['id']}").status_code == 410
    assert client.get(f"/api/v1/summaries/{sid}").status_code == 404
    assert client.get(f"/api/v1/transcripts/{selection['transcript_id']}").status_code == 404
    with database() as db:
        receipt = db.get(SummarySelection, UUID(selection["id"]))
        assert receipt is not None and receipt.status == "cancelled"
        assert receipt.idempotency_key == "meeting:selection"
        assert receipt.request_hash and receipt.source_hash
        assert receipt.source_text is None and receipt.accepted_response is None
        assert receipt.title is None and receipt.folder_ids == []
        assert receipt.transcript_id is None and receipt.summary_id is None
        discarded = db.get(SummaryCandidate, UUID(chosen["id"]))
        assert discarded is not None and discarded.status == "discarded"
        assert discarded.content is None and discarded.options is None
        assert discarded.processing_metadata == {} and discarded.error_code is None
        assert db.get(CandidateRequest, (UUID(selection["id"]), "candidate")) is not None
        assert db.scalar(select(func.count()).select_from(Summary)) == 0
        assert db.scalar(select(func.count()).select_from(Transcript)) == 0
    assert generator.calls == 1
