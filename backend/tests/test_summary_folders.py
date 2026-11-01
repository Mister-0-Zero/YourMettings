"""Set-CAS placement changes keep one document/source and serialize folder intent."""
import threading
from concurrent.futures import ThreadPoolExecutor
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, func, select

from app.db.models import Folder, Summary, SummaryFolder, Transcript, User
from test_summaries import processed
from test_summary_variants import BASE, accept, candidate, create, generator, ready

pytestmark = pytest.mark.integration


def setup_meeting(client):
    transcript_id, summary_id, placement = processed(client)
    a = placement["folder_ids"][0]
    folders = [client.post("/api/v1/folders", json={"name": name}).json()["id"] for name in ("B", "C", "D")]
    b, c, d = folders
    response = client.put(f"/api/v1/summaries/{summary_id}/folders", json={"folder_ids": [a, c]})
    assert response.status_code == 200
    return transcript_id, summary_id, a, b, c, d, response.json()


def assign(client, summary_id, target, expected):
    return client.put(f"/api/v1/summaries/{summary_id}/folders",
        json={"folder_ids": target, "expected_folder_ids": expected})


def unchanged_document(before, after):
    for field in ("id", "transcript_id", "title", "content", "created_at", "version", "navigation",
                  "template_snapshot", "generation_options"):
        assert after[field] == before[field]


def test_move_a_to_b_retains_c_and_shared_edit_is_visible_everywhere(client, database):
    transcript_id, summary_id, a, b, c, _, before = setup_meeting(client)
    response = assign(client, summary_id, [b, c], [a, c])
    assert response.status_code == 200
    moved = response.json()
    assert set(moved["folder_ids"]) == {b, c}
    unchanged_document(before, moved)
    assert client.get("/api/v1/summaries", params={"folder_id": a}).json()["total"] == 0
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 1
        assert db.scalar(select(func.count()).select_from(Transcript)) == 1
        source = db.get(Transcript, UUID(transcript_id)).text
    edited = client.patch(f"/api/v1/summaries/{summary_id}",
        json={"content": "## Shared\nOne edited document", "expected_version": moved["version"]})
    assert edited.status_code == 200
    for folder_id in (b, c):
        listing = client.get("/api/v1/summaries", params={"folder_id": folder_id}).json()
        assert listing["total"] == 1
        assert listing["items"][0]["id"] == summary_id
        assert listing["items"][0]["content"] == edited.json()["content"]
    with database() as db:
        assert db.get(Transcript, UUID(transcript_id)).text == source


def test_add_b_lost_reply_order_independent_and_same_folder_are_noop(client, database):
    _, summary_id, a, b, c, d, before = setup_meeting(client)
    added = assign(client, summary_id, [a, b, c], [c, a])
    assert added.status_code == 200
    saved = added.json()
    unchanged_document(before, saved)
    # The old expected set is stale, but target is already exactly current.
    assert assign(client, summary_id, [c, b, a], [a, c]).json() == saved
    # Move A to A / already placed target also does not advance updated_at.
    assert assign(client, summary_id, [a, b, c], [d]).json() == saved
    assert client.get(f"/api/v1/summaries/{summary_id}").json() == saved
    with database() as db:
        assert db.scalar(select(func.count()).select_from(SummaryFolder)) == 3


def test_stale_placement_rejects_other_target_and_legacy_put_stays_compatible(client):
    _, summary_id, a, b, c, d, _ = setup_meeting(client)
    saved = assign(client, summary_id, [a, b, c], [a, c]).json()
    for expected in ([a, c], [str(uuid4())], []):
        rejected = assign(client, summary_id, [c, d], expected)
        assert rejected.status_code == 409
        assert rejected.json()["error"]["code"] == "summary_folders_conflict"
        assert client.get(f"/api/v1/summaries/{summary_id}").json() == saved
    # Legacy consumers without a precondition retain full replacement behavior.
    legacy = client.put(f"/api/v1/summaries/{summary_id}/folders", json={"folder_ids": [d]})
    assert legacy.status_code == 200 and legacy.json()["folder_ids"] == [d]
    unchanged_document(saved, legacy.json())


@pytest.mark.parametrize("identical", [False, True])
def test_concurrent_folder_cas_keeps_one_intent_or_one_identical_result(client, identical):
    _, summary_id, a, b, c, d, before = setup_meeting(client)
    barrier = threading.Barrier(2)
    def update(target):
        barrier.wait(timeout=10)
        return assign(client, summary_id, target, [a, c])
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(update, [[a, b, c], [c, b, a] if identical else [a, c, d]]))
    assert sorted(r.status_code for r in responses) == ([200, 200] if identical else [200, 409])
    if identical:
        assert responses[0].json() == responses[1].json()
    winner = next(r.json() for r in responses if r.status_code == 200)
    assert client.get(f"/api/v1/summaries/{summary_id}").json() == winner
    unchanged_document(before, winner)


def test_assignment_failure_rolls_back_all_memberships(client, monkeypatch):
    _, summary_id, a, b, c, _, before = setup_meeting(client)
    import app.api.summaries as api
    def abort(*args):
        raise RuntimeError("Placement response failed before commit")
    with monkeypatch.context() as patch:
        patch.setattr(api, "summary_response", abort)
        with pytest.raises(RuntimeError, match="Placement response failed"):
            assign(client, summary_id, [b, c], [a, c])
    assert client.get(f"/api/v1/summaries/{summary_id}").json() == before


def test_target_ownership_unknown_ids_and_hidden_summary_are_preserved(client, database):
    transcript_id, summary_id, a, _, c, _, before = setup_meeting(client)
    with database.begin() as db:
        other = User(email="placement-owner@example.test")
        db.add(other)
        db.flush()
        folder = Folder(user_id=other.id, name="Private")
        source = Transcript(owner_user_id=other.id, text="Private test source", source_hash="b"*64)
        db.add_all([folder, source])
        db.flush()
        hidden = Summary(user_id=other.id, transcript_id=source.id, title="Private", content="Private")
        db.add(hidden)
        db.flush()
        foreign_folder, foreign_summary = str(folder.id), str(hidden.id)
    for target in ([foreign_folder], [str(uuid4())]):
        assert assign(client, summary_id, target, [a, c]).status_code == 404
        assert client.get(f"/api/v1/summaries/{summary_id}").json() == before
    for hidden_id in (foreign_summary, str(uuid4())):
        assert assign(client, hidden_id, [a], [a, c]).status_code == 404


@pytest.mark.parametrize("which", ["expected-null", "expected-duplicate", "expected-too-many", "expected-invalid",
    "target-empty", "target-duplicate", "target-too-many", "target-invalid"])
def test_placement_validation_cannot_mutate_existing_links(client, which):
    _, summary_id, a, b, c, _, before = setup_meeting(client)
    body = {"folder_ids": [b, c], "expected_folder_ids": [a, c]}
    values = {"null": None, "duplicate": [a, a], "too-many": [str(uuid4()) for _ in range(101)],
        "invalid": ["not-a-uuid"], "empty": []}
    field, condition = which.split("-", 1)
    body["expected_folder_ids" if field == "expected" else "folder_ids"] = values[condition]
    response = client.put(f"/api/v1/summaries/{summary_id}/folders", json=body)
    assert response.status_code == 422
    assert client.get(f"/api/v1/summaries/{summary_id}").json() == before


def test_empty_expected_can_repair_legacy_unplaced_document_but_not_place_at_root(client, database):
    _, summary_id, a, b, _, _, before = setup_meeting(client)
    with database.begin() as db:
        db.execute(delete(SummaryFolder).where(SummaryFolder.summary_id == UUID(summary_id)))
    response = assign(client, summary_id, [b], [])
    assert response.status_code == 200 and response.json()["folder_ids"] == [b]
    unchanged_document(before, response.json())
    assert assign(client, summary_id, [], [b]).status_code == 422


def test_generic_creation_input_does_not_inherit_summary_placement_precondition(client):
    folder = client.post("/api/v1/folders", json={"name": "Input isolation"}).json()["id"]
    response = client.post("/api/v1/transcripts/process", json={"title": "Synthetic", "text": "Source",
        "folder_ids": [folder], "expected_folder_ids": [folder]})
    assert response.status_code == 422
    schemas = client.get("/openapi.json").json()["components"]["schemas"]
    for name in ("ProcessInput", "CreateProcessInput", "AudioSessionInput", "AudioConfirm"):
        assert "expected_folder_ids" not in schemas[name]["properties"]
    expected = schemas["SummaryFolderAssignment"]["properties"]["expected_folder_ids"]
    assert expected["type"] == "array" and expected["maxItems"] == 100
    assert "expected_folder_ids" not in schemas["SummaryFolderAssignment"].get("required", [])


@pytest.mark.parametrize("concurrent", [False, True])
def test_deleted_source_folder_preserves_other_placement_and_cas_handles_staleness(client, concurrent):
    _, summary_id, a, b, c, _, before = setup_meeting(client)
    delete_url = f"/api/v1/folders/{a}"
    if concurrent:
        barrier = threading.Barrier(2)
        def action(kind):
            barrier.wait(timeout=10)
            if kind == "delete":
                return client.delete(delete_url, params={"mode": "with_contents", "confirm": True})
            return assign(client, summary_id, [b, c], [a, c])
        with ThreadPoolExecutor(max_workers=2) as pool:
            deleted, placed = list(pool.map(action, ["delete", "move"]))
    else:
        deleted = client.delete(delete_url, params={"mode": "with_contents", "confirm": True})
        placed = assign(client, summary_id, [b, c], [a, c])
        assert placed.status_code == 409
    assert deleted.status_code == 204 and placed.status_code in (200, 409)
    final = client.get(f"/api/v1/summaries/{summary_id}").json()
    unchanged_document(before, final)
    assert set(final["folder_ids"]) == ({b, c} if placed.status_code == 200 else {c})
    if placed.status_code == 409:
        assert placed.json()["error"]["code"] == "summary_folders_conflict"
        refreshed = assign(client, summary_id, [b, c], final["folder_ids"])
        assert refreshed.status_code == 200 and set(refreshed.json()["folder_ids"]) == {b, c}


def test_variant_accept_and_move_keep_new_placement_and_one_document(client, database, generator):
    transcript_id, summary_id, a, b, c, _, _ = setup_meeting(client)
    selection = create(client, {"summary_id": summary_id}).json()
    chosen = ready(client, candidate(client, selection))
    barrier = threading.Barrier(2)
    def update(kind):
        barrier.wait(timeout=10)
        return assign(client, summary_id, [b, c], [a, c]) if kind == "move" else accept(client, selection, chosen)
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(update, ["move", "accept"]))
    assert [response.status_code for response in responses] == [200, 200]
    final = client.get(f"/api/v1/summaries/{summary_id}").json()
    assert set(final["folder_ids"]) == {b, c} and final["content"] == chosen["content"]
    assert final["id"] == summary_id and final["transcript_id"] == transcript_id
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Summary)) == 1
        assert db.scalar(select(func.count()).select_from(Transcript)) == 1
