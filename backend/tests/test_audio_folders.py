"""Placement is optional while recording, mandatory before Qwen."""
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy import func, select

from app.db.audio_models import AudioSession
from app.db.models import Folder, User
from app.integrations.ollama import get_generator
from app.main import app
from test_audio import BASE, do_job, upload, worker
from test_processing import FakeGenerator

pytestmark = pytest.mark.integration


@pytest.mark.parametrize("folders", [{}, {"folder_ids": []}])
def test_create_without_placement_returns_empty_list(client, folders):
    result = client.post(BASE, json={"title": "Запись 21.10.2026 18:00", **folders})
    assert result.status_code == 201, result.text
    state = result.json()
    assert state["parameters"]["folder_ids"] == []
    assert client.get(f"{BASE}/{state['id']}").json()["parameters"]["folder_ids"] == []
    assert client.get("/api/v1/folders").json()["items"] == []  # No hidden default folder.


@pytest.mark.parametrize("first, second", [({}, {"folder_ids": []}), ({"folder_ids": []}, {})])
def test_omitted_and_empty_placement_share_idempotency_key(client, database, first, second):
    headers = {"Idempotency-Key": "recording-key"}
    initial = client.post(BASE, json={"title": "Recording", **first}, headers=headers)
    repeated = client.post(BASE, json={"title": "Recording", **second}, headers=headers)
    assert initial.status_code == 201 and repeated.status_code == 200
    assert initial.json()["id"] == repeated.json()["id"]
    with database() as db:
        assert db.scalar(select(func.count()).select_from(AudioSession)) == 1
    fid = client.post("/api/v1/folders", json={"name": "Selected later"}).json()["id"]
    conflict = client.post(BASE, json={"title": "Recording", "folder_ids": [fid]}, headers=headers)
    assert conflict.status_code == 409 and conflict.json()["error"]["code"] == "idempotency_conflict"


def test_concurrent_omitted_and_empty_placement_create_one_session(client, database):
    bodies = [{"title": "Recording"}, {"title": "Recording", "folder_ids": []}]
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda body: client.post(BASE, json=body,
            headers={"Idempotency-Key": "concurrent-recording"}), bodies))
    assert sorted(r.status_code for r in results) == [200, 201]
    assert results[0].json()["id"] == results[1].json()["id"]
    with database() as db:
        assert db.scalar(select(func.count()).select_from(AudioSession)) == 1


def test_create_with_folders_retains_validation_and_compatibility(client, database):
    fid = client.post("/api/v1/folders", json={"name": "Existing"}).json()["id"]
    headers = {"Idempotency-Key": "existing-placed-session"}
    body = {"title": "Recording", "folder_ids": [fid]}
    initial = client.post(BASE, json=body, headers=headers)
    assert initial.status_code == 201
    repeated = client.post(BASE, json=body, headers=headers)
    assert repeated.status_code == 200 and repeated.json()["id"] == initial.json()["id"]
    assert client.get(f"{BASE}/{initial.json()['id']}").json()["parameters"]["folder_ids"] == [fid]
    assert client.post(BASE, json={"title": "Recording"}, headers=headers).status_code == 409
    for ids, status in [([str(uuid.uuid4())], 404), ([fid, fid], 422),
        ([str(uuid.uuid4()) for _ in range(101)], 422), (["invalid"], 422), (None, 422)]:
        assert client.post(BASE, json={"title": "Recording", "folder_ids": ids}).status_code == status
    with database.begin() as db:
        other = User(email="audio-folder-owner@example.com")
        db.add(other)
        db.flush()
        private = Folder(user_id=other.id, name="Private")
        db.add(private)
        db.flush()
        private_id = str(private.id)
    assert client.post(BASE, json={"title": "Recording", "folder_ids": [private_id]}).status_code == 404
    assert client.post(BASE, json={"folder_ids": []}).status_code == 422
    assert client.post(BASE, json={"title": " "}).status_code == 422


def test_record_without_folder_then_confirm_with_selected_folder(client, database):
    created = client.post(BASE, json={"title": "Recording"})
    assert created.status_code == 201, created.text
    sid = created.json()["id"]
    assert upload(client, sid).status_code == 201
    assert client.post(f"{BASE}/{sid}/complete", json={"expected_chunk_count": 1}).status_code == 202
    do_job(database, worker(database))
    state = client.get(f"{BASE}/{sid}").json()
    assert state["status"] == "ready_for_review" and state["parameters"]["folder_ids"] == []
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    confirmation = {"title": "Reviewed recording", "confirm": True,
        "reviewed_text_sha256": state["transcript_sha256"]}
    for placement in ({}, {"folder_ids": []}):
        assert client.post(f"{BASE}/{sid}/confirm", json={**confirmation, **placement}).status_code == 422
    assert fake.calls == 0
    fid = client.post("/api/v1/folders", json={"name": "Chosen after ASR"}).json()["id"]
    accepted = client.post(f"{BASE}/{sid}/confirm", json={**confirmation, "folder_ids": [fid]})
    assert accepted.status_code == 202, accepted.text
    assert fake.calls == 1
    state = client.get(f"{BASE}/{sid}").json()
    assert state["parameters"]["folder_ids"] == [fid] and state["processing"]["status"] == "ready"
    summary = client.get(f"/api/v1/summaries/{state['processing']['summary_id']}").json()
    assert summary["folder_ids"] == [fid]


def test_openapi_limits_remain_specific_to_audio_creation(client):
    schemas = client.get("/openapi.json").json()["components"]["schemas"]
    create = schemas["AudioSessionInput"]
    assert "folder_ids" not in create["required"] and "title" in create["required"]
    assert create["properties"]["folder_ids"]["maxItems"] == 100
    assert create["properties"]["folder_ids"].get("minItems", 0) == 0
    assert schemas["AudioSessionOut"]["properties"]["parameters"]["$ref"].endswith("/AudioSessionInput")
    for name in ("AudioConfirm", "ProcessInput", "CreateProcessInput", "FolderAssignment"):
        assert "folder_ids" in schemas[name]["required"]
        assert schemas[name]["properties"]["folder_ids"]["minItems"] == 1
