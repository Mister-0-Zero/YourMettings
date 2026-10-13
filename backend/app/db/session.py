from collections.abc import Iterator
from functools import lru_cache
from uuid import UUID

from sqlalchemy import create_engine, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import settings
from app.db.models import Transcript, User

TEST_USER_ID = UUID("00000000-0000-0000-0000-000000000001")


@lru_cache
def get_session_factory():
    if not settings.database_url:
        raise RuntimeError("DATABASE_URL is required; configure backend/.env")
    engine = create_engine(settings.database_url, pool_pre_ping=True, hide_parameters=True)
    return sessionmaker(engine, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    with get_session_factory()() as db:
        yield db


def initialize_database(factory):
    with factory.begin() as db:
        db.execute(insert(User).values(
            id=TEST_USER_ID, email="test@yourmettings.local", password_hash="!disabled"
        ).on_conflict_do_nothing(index_elements=[User.id]))
        # MVP supports exactly one server process. Its abandoned jobs are retryable.
        db.execute(update(Transcript).where(
            Transcript.processing_status == "summarizing"
        ).values(processing_status="error", error_code="processing_interrupted"))
