"""Atomic edited accept, CAS races and populated receipt migration on PostgreSQL."""
import hashlib
from pathlib import Path
import threading
from concurrent.futures import ThreadPoolExecutor
from uuid import UUID

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import func, select, text

from app.core.config import settings
from app.db.audio_models import AudioSession
from app.db.models import Summary, Transcript, User
from app.db.variant_models import SummarySelection
from test_audio import do_job, session as audio_session, upload, worker
from test_summaries import processed
from test_summary_variants import BASE, accept, candidate, create, generator, new_selection, ready

pytestmark = pytest.mark.integration


def test_identical_concurrent_edited_accept_returns_one_receipt(client, database, generator):
    selection, _ = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    barrier = threading.Barrier(2)
    def save(_):
        barrier.wait(timeout=10)
        return accept(client, selection, chosen, title="Edited once", content="## Saved\nOne result")
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(save, range(2)))
    assert [response.status_code for response in responses] == [200, 200]
    assert responses[0].json() == responses[1].json()
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 1
        assert db.scalar(select(Summary.content_revision)) == 1
    assert generator.calls == 1


@pytest.mark.parametrize("source_kind", ["text", "existing", "audio"])
def test_accept_failure_rolls_back_edits_receipt_and_source_state(client, database, generator, monkeypatch, source_kind):
    audio_id = None
    if source_kind == "existing":
        _, summary_id, _ = processed(client)
        before = client.get(f"/api/v1/summaries/{summary_id}").json()
        selection = create(client, {"summary_id": summary_id}).json()
    elif source_kind == "audio":
        audio_id, placement = audio_session(client)
        assert upload(client, audio_id).status_code == 201
        do_job(database, worker(database), value="Synthetic reviewed source.")
        assert client.post(f"/api/v1/audio-sessions/{audio_id}/complete", json={"expected_chunk_count": 1}).status_code == 202
        audio = client.get(f"/api/v1/audio-sessions/{audio_id}").json()
        source = client.get(f"/api/v1/transcripts/{audio['transcript_id']}").json()["text"]
        response = create(client, {"audio_session_id": audio_id, **placement, "confirm": True,
            "reviewed_text_sha256": hashlib.sha256(source.encode()).hexdigest()})
        assert response.status_code == 201
        selection = response.json()
    else:
        selection, _ = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    with database() as db:
        original_source = db.get(Transcript, UUID(selection["transcript_id"]))
        source_state = (original_source.text, original_source.processing_status, original_source.first_processed_at)
    import app.api.summary_variants as api
    original_clear = api.clear_selection
    def abort_before_commit(*args, **kwargs):
        original_clear(*args, **kwargs)
        raise RuntimeError("Abort atomic accept before commit")
    with monkeypatch.context() as patch:
        patch.setattr(api, "clear_selection", abort_before_commit)
        with pytest.raises(RuntimeError, match="Abort atomic accept"):
            accept(client, selection, chosen, title="Not partially saved", content="## Atomic edit")
    with database() as db:
        row = db.get(SummarySelection, UUID(selection["id"]))
        assert row.status == "open" and row.accepted_request_hash is None and row.accepted_response is None
        source = db.get(Transcript, UUID(selection["transcript_id"]))
        assert (source.text, source.processing_status, source.first_processed_at) == source_state
        if audio_id:
            assert db.get(AudioSession, UUID(audio_id)).status == "ready_for_review"
    if source_kind == "existing":
        assert client.get(f"/api/v1/summaries/{summary_id}").json() == before
    else:
        assert client.get("/api/v1/summaries").json()["total"] == 0
    retried = accept(client, selection, chosen, title="Not partially saved", content="## Atomic edit")
    assert retried.status_code == 200
    assert retried.json()["content"] == "## Atomic edit"


def test_accept_and_cas_patch_cannot_overwrite_each_other(client, generator):
    _, summary_id, _ = processed(client)
    url = f"/api/v1/summaries/{summary_id}"
    before = client.get(url).json()
    selection = create(client, {"summary_id": summary_id}).json()
    chosen = ready(client, candidate(client, selection))
    barrier = threading.Barrier(2)
    def save(kind):
        barrier.wait(timeout=10)
        if kind == "accept":
            return kind, accept(client, selection, chosen, title="Accepted edit", content="Accepted content")
        return kind, client.patch(url, json={"title": "Manual edit", "content": "Manual content",
            "expected_version": before["version"]})
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(save, ["accept", "patch"]))
    assert sorted(response.status_code for _, response in responses) == [200, 409]
    kind, winner = next((kind, response) for kind, response in responses if response.status_code == 200)
    loser = next(response for _, response in responses if response.status_code == 409)
    assert loser.json()["error"]["code"] == "summary_version_conflict"
    assert client.get(url).json() == winner.json()
    if kind == "patch":
        assert client.get(f"{BASE}/{selection['id']}").json()["status"] == "open"


def test_normalization_presence_and_omitted_version_retry_contract(client, generator):
    selection, _ = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    saved = accept(client, selection, chosen, title="  Normalized title  ", content=chosen["content"])
    assert saved.status_code == 200 and saved.json()["title"] == "Normalized title"
    assert accept(client, selection, chosen, title="Normalized title", content=chosen["content"], expected_version=None).json() == saved.json()
    # Explicit unchanged content and omitted content are distinct acceptance requests.
    changed = accept(client, selection, chosen, title="Normalized title")
    assert changed.status_code == 409 and changed.json()["error"]["code"] == "idempotency_conflict"


def test_edited_accept_never_grants_access_to_another_owner(client, database, generator):
    selection, _ = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    with database.begin() as db:
        other = User(email="other-save-owner@example.test")
        db.add(other)
        db.flush()
        db.get(SummarySelection, UUID(selection["id"])).user_id = other.id
    response = accept(client, selection, chosen, title="Forbidden", content="Forbidden edit")
    assert response.status_code == 404
    assert client.get("/api/v1/summaries").json()["total"] == 0


def test_cas_patch_detects_legacy_a_b_a_edit(client):
    _, summary_id, _ = processed(client)
    url = f"/api/v1/summaries/{summary_id}"
    before = client.get(url).json()
    assert client.patch(url, json={"content": "Intermediate edit"}).status_code == 200
    restored = client.patch(url, json={"content": before["content"]})
    assert restored.status_code == 200 and restored.json()["version"] != before["version"]
    stale = client.patch(url, json={"title": "Stale title", "expected_version": before["version"]})
    assert stale.status_code == 409 and stale.json()["error"]["code"] == "summary_version_conflict"
    assert client.get(url).json() == restored.json()


def test_accept_supports_exact_edit_size_limits(client, generator):
    selection, _ = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    content = "## Saved heading\n" + "x" * (200_000 - len("## Saved heading\n"))
    accepted = accept(client, selection, chosen, title="T" * 200, content=content)
    assert accepted.status_code == 200
    result = accepted.json()
    assert result["title"] == "T" * 200 and result["content"] == content
    assert result["navigation"][0]["title"] == "Saved heading"
    assert accept(client, selection, chosen, title="T" * 200, content=content).json() == result


def test_populated_0009_upgrade_preserves_historical_receipts_and_downgrade(client, database, generator):
    selection, _ = new_selection(client)
    chosen = ready(client, candidate(client, selection))
    saved = accept(client, selection, chosen).json()
    cfg = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    cfg.attributes["database_url"] = settings.test_database_url
    def snapshot():
        with database() as db:
            return {table:db.execute(text(
                "SELECT (to_jsonb(t)-'accepted_request_hash')::text FROM " + table + " t ORDER BY 1"
            )).scalars().all() for table in ("summary_selections", "summary_candidates", "candidate_requests",
                "summaries", "transcripts", "summary_folders")}
    try:
        command.downgrade(cfg, "0009")
        before = snapshot()
        command.upgrade(cfg, "head")
        assert snapshot() == before
        with database() as db:
            assert db.execute(text("SELECT is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='summary_selections' AND column_name='accepted_request_hash'")).scalar_one() == "YES"
            assert db.get(SummarySelection, UUID(selection["id"])).accepted_request_hash is None
        assert accept(client, selection, chosen).json() == saved
        assert accept(client, selection, chosen, content="A new edit on an old receipt").status_code == 409
        current = create(client, {"summary_id": saved["id"]}, key="after-migration").json()
        next_candidate = ready(client, candidate(client, current))
        assert accept(client, current, next_candidate, content="Edited after migration").status_code == 200
        with database() as db:
            value = db.get(SummarySelection, UUID(current["id"])).accepted_request_hash
            assert value is not None and len(value) == 64
        populated = snapshot()
        command.check(cfg)
        command.downgrade(cfg, "0009")
        assert snapshot() == populated
        command.upgrade(cfg, "head")
        assert snapshot() == populated
    finally:
        command.upgrade(cfg, "head")
