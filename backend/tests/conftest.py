from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

from app.core.config import settings
from app.db.session import initialize_database


@pytest.fixture
def database():
    url = settings.test_database_url
    if not url:
        pytest.skip("TEST_DATABASE_URL is required for PostgreSQL integration tests")
    target = make_url(url)
    if target.get_backend_name() != "postgresql" or not target.database.endswith("_test"):
        raise RuntimeError("Tests require PostgreSQL and a database ending in _test")
    if settings.database_url and target.database == make_url(settings.database_url).database:
        raise RuntimeError("Test database must differ from development database")
    cfg = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    cfg.attributes["database_url"] = url
    command.upgrade(cfg, "head")
    engine = create_engine(url, hide_parameters=True)
    with engine.begin() as conn:
        conn.execute(text("TRUNCATE summary_folders, summaries, transcripts, folders, users CASCADE"))
    factory = sessionmaker(engine, expire_on_commit=False)
    initialize_database(factory)
    yield factory
    engine.dispose()
