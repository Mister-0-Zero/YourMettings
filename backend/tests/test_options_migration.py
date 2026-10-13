from pathlib import Path
import uuid

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text

from app.core.config import settings

pytestmark = pytest.mark.integration


def test_options_migration_preserves_existing_source(database):
    cfg = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    cfg.attributes["database_url"] = settings.test_database_url
    command.downgrade(cfg, "0002")
    tid = uuid.uuid4()
    try:
        with database.begin() as db:
            db.execute(text("INSERT INTO transcripts (id, owner_user_id, text, source_hash, processing_status, processing_attempt) VALUES (:id, '00000000-0000-0000-0000-000000000001', 'Preserved source', :hash, 'error', 1)"), {"id": tid, "hash": "a" * 64})
        command.upgrade(cfg, "head")
        with database() as db:
            row = db.execute(text("SELECT text, processing_options, processing_status FROM transcripts WHERE id=:id"), {"id": tid}).one()
            assert tuple(row) == ("Preserved source", {}, "error")
    finally:
        command.upgrade(cfg, "head")
