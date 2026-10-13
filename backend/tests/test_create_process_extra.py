import pytest
from sqlalchemy import func, select

from app.db.models import Transcript
from app.integrations.ollama import OllamaGenerator, get_generator
from app.main import app
from test_create_process import URL, request_body
from test_processing import FakeGenerator

pytestmark = pytest.mark.integration


def test_folder_order_does_not_change_idempotency(client):
    body = request_body(client)
    extra = client.post("/api/v1/folders", json={"name": "Extra"}).json()["id"]
    body["folder_ids"].append(extra)
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    headers = {"Idempotency-Key": "order"}
    first = client.post(URL, json=body, headers=headers)
    reverse = dict(body, folder_ids=list(reversed(body["folder_ids"])))
    repeat = client.post(URL, json=reverse, headers=headers)
    assert repeat.status_code == 202
    assert repeat.json()["transcript_id"] == first.json()["transcript_id"]
    assert fake.calls == 1


def test_missing_model_does_not_commit_transcript(client, database):
    body = request_body(client)
    app.dependency_overrides[get_generator] = lambda: OllamaGenerator("http://local", "", 1)
    response = client.post(URL, json=body, headers={"Idempotency-Key": "missing-model"})
    assert response.status_code == 503
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Transcript)) == 0
