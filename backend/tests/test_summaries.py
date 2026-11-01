import uuid
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy import select

from app.db.models import Folder, Summary, Transcript, User
from app.integrations.ollama import get_generator
from app.main import app
from test_processing import FakeGenerator, prepare

pytestmark = pytest.mark.integration


def processed(client):
    tid, body = prepare(client)
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    client.post(f"/api/v1/transcripts/{tid}/process", json=body)
    sid = client.get(f"/api/v1/transcripts/{tid}/processing").json()["summary_id"]
    return tid, sid, body


def test_conditional_patch_conflict_lost_reply_and_folders(client):
    _, sid, placement = processed(client)
    url = f"/api/v1/summaries/{sid}"
    original = client.get(url).json()
    body = {"title": "Edited title", "content": "## Edited\n**Bold**", "expected_version": original["version"]}
    saved = client.patch(url, json=body)
    assert saved.status_code == 200
    assert saved.json()["folder_ids"] == placement["folder_ids"]
    assert saved.json()["navigation"][0]["title"] == "Edited"
    assert saved.json()["version"] != original["version"]
    # PATCH has CAS, not an acceptance receipt: after lost reply GET reconciles.
    repeated = client.patch(url, json=body)
    assert repeated.status_code == 409
    assert repeated.json()["error"]["code"] == "summary_version_conflict"
    assert client.get(url).json() == saved.json()
    for bad in ({"expected_version": original["version"]}, {"title": "X", "expected_version": None},
                {"content": " "}, {"content": "x" * 200_001}):
        assert client.patch(url, json=bad).status_code == 422


def test_concurrent_conditional_patch_has_one_winner(client):
    _, sid, _ = processed(client)
    url = f"/api/v1/summaries/{sid}"
    version = client.get(url).json()["version"]
    barrier = threading.Barrier(2)
    def edit(content):
        barrier.wait(timeout=10)
        return client.patch(url, json={"content": content, "expected_version": version})
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(edit, ["First", "Second"]))
    assert sorted(r.status_code for r in responses) == [200, 409]
    winner = next(r.json() for r in responses if r.status_code == 200)
    assert client.get(url).json() == winner


def test_summary_edit_list_assign_and_delete(client):
    tid, sid, body = processed(client)
    item = client.get(f"/api/v1/summaries/{sid}").json()
    assert item["title"] == body["title"] and item["folder_ids"] == body["folder_ids"]
    edited = client.patch(f"/api/v1/summaries/{sid}", json={"title": "New", "content": "Manual edit"})
    assert edited.status_code == 200 and edited.json()["content"] == "Manual edit"
    client.post(f"/api/v1/transcripts/{tid}/process", json=body)
    assert client.get(f"/api/v1/summaries/{sid}").json()["content"] == "Manual edit"
    second = client.post("/api/v1/folders", json={"name": "second"}).json()["id"]
    assigned = client.put(f"/api/v1/summaries/{sid}/folders", json={"folder_ids": body["folder_ids"] + [second]})
    assert assigned.status_code == 200 and len(assigned.json()["folder_ids"]) == 2
    assert client.get("/api/v1/summaries", params={"folder_id": second}).json()["total"] == 1
    client.put(f"/api/v1/summaries/{sid}/folders", json={"folder_ids": [second]})
    assert client.get("/api/v1/summaries", params={"folder_id": body["folder_ids"][0]}).json()["total"] == 0
    assert client.get("/api/v1/summaries", params={"limit": 1, "offset": 1}).json()["items"] == []
    assert client.delete(f"/api/v1/summaries/{sid}").status_code == 204
    assert client.get(f"/api/v1/summaries/{sid}").status_code == 404
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 404
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "edit"}).status_code == 404
    assert client.get(f"/api/v1/transcripts/{tid}/processing").status_code == 404


def test_summary_validation_and_foreign_folders(client, database):
    tid, sid, _ = processed(client)
    for body in ({}, {"title": None}, {"content": None}, {"title": " "}, {"content": ""}):
        assert client.patch(f"/api/v1/summaries/{sid}", json=body).status_code == 422
    assert client.put(f"/api/v1/summaries/{sid}/folders", json={"folder_ids": []}).status_code == 422
    with database.begin() as db:
        other = User(email="other@example.com")
        db.add(other)
        db.flush()
        folder = Folder(user_id=other.id, name="private")
        transcript = Transcript(owner_user_id=other.id, text="private", source_hash="c" * 64)
        db.add_all([folder, transcript])
        db.flush()
        summary = Summary(user_id=other.id, transcript_id=transcript.id, title="private", content="private")
        db.add(summary)
        db.flush()
        fid, private_id = str(folder.id), str(summary.id)
    assert client.put(f"/api/v1/summaries/{sid}/folders", json={"folder_ids": [fid]}).status_code == 404
    for method in ("get", "delete"):
        assert getattr(client, method)(f"/api/v1/summaries/{private_id}").status_code == 404
    assert client.patch(f"/api/v1/summaries/{private_id}", json={"title": "attack"}).status_code == 404
    assert client.get("/api/v1/summaries").json()["total"] == 1


def test_api_contract_endpoint_inventory(client):
    paths = client.get("/openapi.json").json()["paths"]
    expected = {
        "/api/v1/auth/request-code": {"post"},
        "/api/v1/auth/verify-code": {"post"},
        "/api/v1/auth/refresh": {"post"},
        "/api/v1/auth/logout": {"post"},
        "/api/v1/auth/me": {"get"},
        "/api/v1/audio-sessions": {"post"},
        "/api/v1/audio-sessions/{id}": {"get", "delete"},
        "/api/v1/audio-sessions/{id}/chunks": {"post"},
        "/api/v1/audio-sessions/{id}/complete": {"post"},
        "/api/v1/audio-sessions/{id}/retry": {"post"},
        "/api/v1/audio-sessions/{id}/confirm": {"post"},
        "/api/v1/audio-sessions/{id}/pipeline/retry": {"post"},
        "/api/v1/audio-sessions/{id}/pipeline/cancel": {"post"},
        "/api/v1/audio-sessions/{id}/pipeline/parameters": {"put"},
        "/api/v1/transcripts": {"post"},
        "/api/v1/transcripts/process": {"post"},
        "/api/v1/transcripts/{id}": {"get", "patch"},
        "/api/v1/transcripts/{id}/process": {"post"},
        "/api/v1/transcripts/{id}/processing": {"get"},
        "/api/v1/summaries": {"get"},
        "/api/v1/summaries/{id}": {"get", "patch", "delete"},
        "/api/v1/summaries/{id}/folders": {"put"},
        "/api/v1/summary-selections": {"post"},
        "/api/v1/summary-selections/{id}": {"get", "delete"},
        "/api/v1/summary-selections/{id}/candidates": {"post"},
        "/api/v1/summary-selections/{id}/accept": {"post"},
        "/api/v1/summary-candidates/{id}": {"get"},
        "/api/v1/template-preview-examples": {"get"},
        "/api/v1/template-preview-examples/{id}": {"get"},
        "/api/v1/summary-templates": {"get", "post"},
        "/api/v1/summary-templates/{id}": {"get", "put", "delete"},
        "/api/v1/summary-templates/{id}/copy": {"post"},
        "/api/v1/template-previews": {"post"},
        "/api/v1/template-previews/{id}": {"get", "delete"},
        "/api/v1/folders": {"get", "post"},
        "/api/v1/folders/{id}": {"patch", "delete"},
    }
    assert {path for path in paths if path.startswith("/api/v1")} == set(expected)
    for path, methods in expected.items():
        assert set(paths[path]) == methods
