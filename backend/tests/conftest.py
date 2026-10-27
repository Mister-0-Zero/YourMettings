from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

from app.core.config import settings
from app.db.session import initialize_database, TEST_USER_ID


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
        conn.execute(text("TRUNCATE email_challenges, candidate_requests, summary_candidates, summary_selections, summary_templates, asr_worker_state, audio_chunks, audio_sessions, audio_session_deletions, summary_folders, summaries, transcripts, folders, users CASCADE"))
    factory = sessionmaker(engine, expire_on_commit=False, info={"user_id":TEST_USER_ID})
    initialize_database(factory)
    from app.db.models import User
    with factory.begin() as db:
        db.add(User(id=TEST_USER_ID,email="test@yourmettings.local"))
    yield factory
    engine.dispose()


@pytest.fixture
def client(database):
    from fastapi.testclient import TestClient
    from app.main import app
    from app.db.session import get_db, get_session_factory
    def db_dependency():
        with database() as db:
            yield db
    app.dependency_overrides[get_db] = db_dependency
    # Test-only identity injection keeps existing feature regressions independent
    # of OTP delivery. Auth/isolation tests remove this override and use real tokens.
    from app.api.auth import get_current_user
    from app.db.models import User
    from fastapi import Depends
    def legacy_identity(db=Depends(get_db)):
        db.info["user_id"] = TEST_USER_ID
        return db.get(User, TEST_USER_ID)
    app.dependency_overrides[get_current_user] = legacy_identity
    # Lifespan must use the test database, including restart recovery.
    import app.main as main
    original_factory = main.get_session_factory
    main.get_session_factory = lambda: database
    try:
        with TestClient(app,headers={"Authorization":"Bearer test-fixture-only"}) as test_client:
            yield test_client
    finally:
        main.get_session_factory = original_factory
        app.dependency_overrides.clear()
