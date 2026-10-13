import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from app.db.models import Folder, Transcript, User

pytestmark = pytest.mark.integration


def test_transcript_crud_and_validation(client):
    response = client.post("/api/v1/transcripts", json={"text": "Исходный текст"})
    assert response.status_code == 201
    id = response.json()["id"]
    assert client.get(f"/api/v1/transcripts/{id}").json()["text"] == "Исходный текст"
    assert client.patch(f"/api/v1/transcripts/{id}", json={"text": "Правка"}).json()["text"] == "Правка"
    assert client.post("/api/v1/transcripts", json={"text": "  "}).status_code == 422
    assert client.post("/api/v1/transcripts", json={"text": "x", "user_id": str(uuid.uuid4())}).status_code == 422
    assert client.post("/api/v1/transcripts", json={"text": "x" * 100001}).status_code == 413


def test_idempotency_survives_edit_and_concurrent_requests(client):
    def create():
        return client.post("/api/v1/transcripts", json={"text": "original"}, headers={"Idempotency-Key": "same"})
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda _: create(), range(4)))
    assert sorted(r.status_code for r in responses) == [200, 200, 200, 201]
    assert len({r.json()["id"] for r in responses}) == 1
    id = responses[0].json()["id"]
    client.patch(f"/api/v1/transcripts/{id}", json={"text": "edited"})
    assert create().json()["text"] == "edited"
    assert client.post("/api/v1/transcripts", json={"text": "different"}, headers={"Idempotency-Key": "same"}).status_code == 409


def test_folders_and_isolation(client, database):
    root = client.post("/api/v1/folders", json={"name": "Root"}).json()
    child = client.post("/api/v1/folders", json={"name": "Child", "parent_id": root["id"]}).json()
    assert client.get("/api/v1/folders").json()["items"][0]["children"][0]["id"] == child["id"]
    assert client.patch(f'/api/v1/folders/{child["id"]}', json={"name": "Renamed"}).json()["name"] == "Renamed"
    with database.begin() as db:
        user = User(email="other@example.com")
        db.add(user)
        db.flush()
        folder = Folder(user_id=user.id, name="private")
        transcript = Transcript(owner_user_id=user.id, text="private", source_hash="b" * 64)
        db.add_all([folder, transcript])
        db.flush()
        fid, tid = folder.id, transcript.id
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 404
    assert client.patch(f"/api/v1/transcripts/{tid}", json={"text": "attack"}).status_code == 404
    assert client.post("/api/v1/folders", json={"name": "Bad", "parent_id": str(fid)}).status_code == 404
    assert client.patch(f"/api/v1/folders/{fid}", json={"name": "attack"}).status_code == 404
