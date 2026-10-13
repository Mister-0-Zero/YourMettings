import uuid
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest

from app.db.models import Folder, Summary, SummaryFolder, Transcript, User
from app.db.session import TEST_USER_ID
from app.integrations.ollama import get_generator
from app.main import app
from test_processing import FakeGenerator

pytestmark = pytest.mark.integration


def folder(client, name, parent=None):
    return client.post("/api/v1/folders", json={"name": name, "parent_id": parent}).json()["id"]


def summary(client, folder_ids):
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    tid = client.post("/api/v1/transcripts/process", json={"text": "Meeting", "title": "Title", "folder_ids": folder_ids}).json()["transcript_id"]
    sid = client.get(f"/api/v1/transcripts/{tid}/processing").json()["summary_id"]
    return tid, sid


def remove(client, id, mode="with_contents", confirm=True):
    return client.delete(f"/api/v1/folders/{id}", params={"mode": mode, "confirm": confirm})


def test_delete_empty_folder_and_explicit_confirmation(client):
    id = folder(client, "Empty")
    assert remove(client, id, confirm=False).status_code == 422
    assert client.delete(f"/api/v1/folders/{id}").status_code == 422
    assert remove(client, id).status_code == 204
    assert client.get("/api/v1/folders").json()["items"] == []


def test_delete_tree_preserves_summary_in_external_folder(client):
    root = folder(client, "Root")
    child = folder(client, "Child", root)
    external = folder(client, "External")
    tid, sid = summary(client, [child, external])
    deleted_tid, deleted_sid = summary(client, [root, child])
    assert remove(client, root).status_code == 204
    assert client.get(f"/api/v1/summaries/{sid}").json()["folder_ids"] == [external]
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 200
    assert client.get(f"/api/v1/summaries/{deleted_sid}").status_code == 404
    assert client.get(f"/api/v1/transcripts/{deleted_tid}").status_code == 404
    assert [x["id"] for x in client.get("/api/v1/folders").json()["items"]] == [external]


def test_shared_transcript_survives_tree_deletion(client, database):
    root = folder(client, "Root")
    tid, sid = summary(client, [root])
    with database.begin() as db:
        other = User(email="other@folders.test")
        db.add(other)
        db.flush()
        db.add(Summary(user_id=other.id, transcript_id=uuid.UUID(tid), title="Other", content="Preserve"))
    assert remove(client, root).status_code == 204
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 200
    assert client.get(f"/api/v1/summaries/{sid}").status_code == 404


def test_folder_deletion_is_atomic_when_cleanup_fails(client, monkeypatch):
    root = folder(client, "Root")
    child = folder(client, "Child", root)
    tid, sid = summary(client, [child])
    import app.services.folders as folders
    def fail(*args):
        raise RuntimeError("Injected cleanup failure")
    monkeypatch.setattr(folders, "cleanup_transcript", fail)
    with pytest.raises(RuntimeError, match="Injected cleanup failure"):
        remove(client, root)
    assert client.get(f"/api/v1/summaries/{sid}").json()["folder_ids"] == [child]
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 200
    assert client.get("/api/v1/folders").json()["items"][0]["children"][0]["id"] == child


def test_active_generation_prevents_tree_deletion_until_finished(client):
    root = folder(client, "Root")
    started, release = threading.Event(), threading.Event()
    fake = FakeGenerator(started=started, release=release)
    app.dependency_overrides[get_generator] = lambda: fake
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(client.post, "/api/v1/transcripts/process", json={"text": "Meeting", "title": "Title", "folder_ids": [root]})
        assert started.wait(5)
        try:
            assert remove(client, root).status_code == 409
        finally:
            release.set()
        tid = first.result().json()["transcript_id"]
    assert remove(client, root).status_code == 204
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 404


def test_concurrent_tree_and_summary_deletes(client):
    root = folder(client, "Root")
    tid, sid = summary(client, [root])
    with ThreadPoolExecutor(max_workers=2) as pool:
        tree = pool.submit(remove, client, root)
        one = pool.submit(client.delete, f"/api/v1/summaries/{sid}")
        assert tree.result().status_code == 204
        assert one.result().status_code in (204, 404)
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 404


def test_cannot_delete_foreign_folder(client, database):
    with database.begin() as db:
        other = User(email="foreign@folders.test")
        db.add(other)
        db.flush()
        row = Folder(user_id=other.id, name="Private")
        db.add(row)
        db.flush()
        id = row.id
    assert remove(client, str(id)).status_code == 404

