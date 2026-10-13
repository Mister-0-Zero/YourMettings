import hashlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Response
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.api.dependencies import owned_transcript
from app.api.errors import fail
from app.core.config import settings
from app.db.models import Transcript
from app.db.session import TEST_USER_ID, get_db
from app.schemas import TranscriptInput, TranscriptOut

router = APIRouter(prefix="/transcripts", tags=["transcripts"])


def transcript_response(item):
    return TranscriptOut(id=item.id, text=item.text, created_at=item.created_at,
        is_locked=item.first_processed_at is not None or item.processing_status == "summarizing")


def check_size(text):
    if len(text) > settings.max_transcript_chars:
        fail(413, "text_too_large", "Текст превышает установленный лимит.")


@router.post("", response_model=TranscriptOut, status_code=201)
def create_transcript(body: TranscriptInput, response: Response,
    idempotency_key: Annotated[str | None, Header(min_length=1, max_length=128)] = None,
    db: Session = Depends(get_db)):
    check_size(body.text)
    digest = hashlib.sha256(body.text.encode("utf-8")).hexdigest()
    if idempotency_key is not None:
        stmt = insert(Transcript).values(owner_user_id=TEST_USER_ID, text=body.text,
            idempotency_key=idempotency_key, source_hash=digest,
            processing_status="not_started", processing_attempt=0).on_conflict_do_nothing(
                index_elements=[Transcript.owner_user_id, Transcript.idempotency_key]).returning(Transcript)
        item = db.scalar(stmt)
        if item is None:
            item = db.scalar(select(Transcript).where(
                Transcript.owner_user_id == TEST_USER_ID, Transcript.idempotency_key == idempotency_key))
            if item.source_hash != digest:
                fail(409, "idempotency_conflict", "Ключ уже использован для другого текста.")
            response.status_code = 200
    else:
        item = Transcript(owner_user_id=TEST_USER_ID, text=body.text, source_hash=digest)
        db.add(item)
    db.commit()
    return transcript_response(item)


@router.get("/{id}", response_model=TranscriptOut)
def get_transcript(id: UUID, db: Session = Depends(get_db)):
    return transcript_response(owned_transcript(db, id))


@router.patch("/{id}", response_model=TranscriptOut)
def edit_transcript(id: UUID, body: TranscriptInput, db: Session = Depends(get_db)):
    check_size(body.text)
    item = owned_transcript(db, id, lock=True)
    if item.first_processed_at is not None or item.processing_status == "summarizing":
        fail(409, "transcript_locked", "Транскрипт недоступен для редактирования.")
    item.text = body.text
    db.commit()
    return transcript_response(item)
