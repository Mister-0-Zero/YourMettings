import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy import select, text

from app.db.models import Summary, Transcript, User
from test_summaries import processed

pytestmark = pytest.mark.integration


def test_shared_source_preserved_until_last_summary(client, database):
    tid, sid, _ = processed(client)
    with database.begin() as db:
        user = User(email="shared@example.com")
        db.add(user)
        db.flush()
        db.add(Summary(user_id=user.id, transcript_id=uuid.UUID(tid), title="Shared", content="Other user's result"))
    assert client.delete(f"/api/v1/summaries/{sid}").status_code == 204
    assert client.get(f"/api/v1/transcripts/{tid}").json()["is_locked"] is True
    assert client.get(f"/api/v1/transcripts/{tid}/processing").json()["status"] == "not_started"
    with database() as db:
        assert db.scalar(select(Summary)).content == "Other user's result"


def test_active_generation_keeps_source(client, database):
    tid, sid, _ = processed(client)
    with database.begin() as db:
        row = db.get(Transcript, uuid.UUID(tid))
        row.processing_status = "summarizing"
    assert client.delete(f"/api/v1/summaries/{sid}").status_code == 204
    assert client.get(f"/api/v1/transcripts/{tid}/processing").json()["status"] == "summarizing"


def test_future_external_fk_even_cascade_preserves_source(client, database):
    tid, sid, _ = processed(client)
    with database.begin() as db:
        db.execute(text("CREATE TABLE test_access_dependency (id uuid PRIMARY KEY, transcript_id uuid REFERENCES transcripts(id) ON DELETE CASCADE)"))
        db.execute(text("INSERT INTO test_access_dependency VALUES (:id, :tid)"), {"id": uuid.uuid4(), "tid": uuid.UUID(tid)})
    try:
        assert client.delete(f"/api/v1/summaries/{sid}").status_code == 204
        assert client.get(f"/api/v1/transcripts/{tid}").status_code == 200
        with database() as db:
            assert db.scalar(text("SELECT count(*) FROM test_access_dependency")) == 1
    finally:
        with database.begin() as db:
            db.execute(text("DROP TABLE test_access_dependency"))


def test_deletion_rolls_back_if_cleanup_fails(client, monkeypatch):
    tid, sid, _ = processed(client)
    import app.api.summaries as summaries
    def fail(*args):
        raise RuntimeError("Injected deletion failure")
    monkeypatch.setattr(summaries, "cleanup_transcript", fail)
    with pytest.raises(RuntimeError, match="Injected deletion failure"):
        client.delete(f"/api/v1/summaries/{sid}")
    assert client.get(f"/api/v1/summaries/{sid}").status_code == 200
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 200


def test_concurrent_summary_deletes_are_atomic(client):
    tid, sid, _ = processed(client)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: client.delete(f"/api/v1/summaries/{sid}").status_code, range(2)))
    assert sorted(results) == [204, 404]
    assert client.get(f"/api/v1/transcripts/{tid}").status_code == 404
