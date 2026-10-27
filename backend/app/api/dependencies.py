from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.errors import fail
from app.db.models import Folder, Summary, Transcript
from app.db.session import current_user_id


def owned_transcript(db: Session, id: UUID, *, lock=False):
    query = select(Transcript).where(Transcript.id == id, Transcript.owner_user_id == current_user_id(db))
    if lock:
        query = query.with_for_update()
    item = db.scalar(query)
    if item is None:
        fail(404, "not_found", "Транскрипт не найден.")
    return item


def owned_summary(db: Session, id: UUID, *, lock=False):
    query = select(Summary).where(Summary.id == id, Summary.user_id == current_user_id(db))
    if lock:
        query = query.with_for_update()
    item = db.scalar(query)
    if item is None:
        fail(404, "not_found", "Summary не найден.")
    return item


def owned_folder(db: Session, id: UUID):
    item = db.scalar(select(Folder).where(Folder.id == id, Folder.user_id == current_user_id(db)))
    if item is None:
        fail(404, "not_found", "Папка не найдена.")
    return item


def validate_folders(db: Session, ids: list[UUID]):
    found = set(db.scalars(select(Folder.id).where(Folder.id.in_(ids), Folder.user_id == current_user_id(db))))
    if found != set(ids):
        fail(404, "not_found", "Одна или несколько папок не найдены.")
