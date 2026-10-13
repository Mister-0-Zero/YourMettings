from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.api.dependencies import owned_folder, owned_summary, owned_transcript, validate_folders
from app.db.models import Summary, SummaryFolder
from app.db.session import TEST_USER_ID, get_db
from app.schemas import FolderAssignment, SummaryEdit, SummaryList, SummaryOut

router = APIRouter(prefix="/summaries", tags=["summaries"])


def summary_response(db, item):
    ids = list(db.scalars(select(SummaryFolder.folder_id).where(
        SummaryFolder.summary_id == item.id).order_by(SummaryFolder.folder_id)))
    return SummaryOut(id=item.id, transcript_id=item.transcript_id, title=item.title,
        content=item.content, folder_ids=ids, created_at=item.created_at, updated_at=item.updated_at)


@router.get("", response_model=SummaryList)
def list_summaries(folder_id: UUID | None = None, limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0), db: Session = Depends(get_db)):
    query = select(Summary).where(Summary.user_id == TEST_USER_ID)
    if folder_id is not None:
        owned_folder(db, folder_id)
        query = query.join(SummaryFolder, SummaryFolder.summary_id == Summary.id).where(SummaryFolder.folder_id == folder_id)
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = db.scalars(query.order_by(Summary.created_at.desc(), Summary.id).limit(limit).offset(offset)).all()
    return SummaryList(items=[summary_response(db, item) for item in rows], total=total, limit=limit, offset=offset)


@router.get("/{id}", response_model=SummaryOut)
def get_summary(id: UUID, db: Session = Depends(get_db)):
    return summary_response(db, owned_summary(db, id))


@router.patch("/{id}", response_model=SummaryOut)
def edit_summary(id: UUID, body: SummaryEdit, db: Session = Depends(get_db)):
    item = owned_summary(db, id, lock=True)
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(item, field, value)
    db.commit()
    return summary_response(db, item)


@router.put("/{id}/folders", response_model=SummaryOut)
def assign_folders(id: UUID, body: FolderAssignment, db: Session = Depends(get_db)):
    item = owned_summary(db, id, lock=True)
    validate_folders(db, body.folder_ids)
    db.execute(delete(SummaryFolder).where(SummaryFolder.summary_id == item.id))
    db.add_all(SummaryFolder(summary_id=item.id, folder_id=fid) for fid in body.folder_ids)
    item.updated_at = func.now()
    db.commit()
    return summary_response(db, item)


@router.delete("/{id}", status_code=204)
def delete_summary(id: UUID, db: Session = Depends(get_db)):
    initial = owned_summary(db, id)
    # Same lock order as generation: transcript first, summary second.
    transcript = owned_transcript(db, initial.transcript_id, lock=True)
    item = owned_summary(db, id, lock=True)
    db.delete(item)
    transcript.processing_status = "not_started"
    transcript.error_code = None
    db.commit()
    return Response(status_code=204)
