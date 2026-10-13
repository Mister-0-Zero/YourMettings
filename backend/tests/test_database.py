import uuid

import pytest
from sqlalchemy import inspect, select
from sqlalchemy.exc import IntegrityError

from app.db.models import Folder, Summary, Transcript, User
from app.db.session import TEST_USER_ID, initialize_database

pytestmark = pytest.mark.integration


def test_schema_and_idempotent_seed(database):
    initialize_database(database)
    with database() as db:
        assert len(db.scalars(select(User)).all()) == 1
        inspector = inspect(db.bind)
        assert {"users", "folders", "transcripts", "summaries", "summary_folders"} <= set(inspector.get_table_names())
        assert {"user_id", "transcript_id"} in [set(x["column_names"]) for x in inspector.get_unique_constraints("summaries")]


def test_unique_summary_and_foreign_keys(database):
    with database.begin() as db:
        transcript = Transcript(owner_user_id=TEST_USER_ID, text="text", source_hash="a" * 64)
        db.add(transcript)
        db.flush()
        transcript_id = transcript.id
        db.add(Summary(user_id=TEST_USER_ID, transcript_id=transcript_id, title="one", content="summary"))
    with pytest.raises(IntegrityError), database.begin() as db:
        db.add(Summary(user_id=TEST_USER_ID, transcript_id=transcript_id, title="two", content="duplicate"))
    with pytest.raises(IntegrityError), database.begin() as db:
        db.add(Folder(user_id=TEST_USER_ID, name="invalid", parent_id=uuid.uuid4()))
