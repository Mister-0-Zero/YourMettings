from sqlalchemy import delete, select, func

from app.api.dependencies import owned_folder
from app.api.errors import fail
from app.db.models import Folder, Summary, SummaryFolder, Transcript
from app.db.session import current_user_id
from app.services.deletion import cleanup_transcript, lock_user_data


def delete_folder_tree(db, folder_id, *, confirm):
    if not confirm:
        fail(422, "confirmation_required", "Подтвердите удаление папки с содержимым.")
    lock_user_data(db)
    owned_folder(db, folder_id)
    tree = select(Folder.id).where(Folder.id == folder_id, Folder.user_id == current_user_id(db)).cte("subtree", recursive=True)
    tree = tree.union_all(select(Folder.id).join(tree, Folder.parent_id == tree.c.id).where(Folder.user_id == current_user_id(db)))
    ids = list(db.scalars(select(tree.c.id)))
    active = db.scalar(select(Transcript.id).where(
        Transcript.owner_user_id == current_user_id(db), Transcript.processing_status == "summarizing",
        Transcript.processing_folder_ids.overlap(ids)).limit(1))
    if active is not None:
        fail(409, "folder_processing", "Дождитесь завершения обработки в удаляемой папке.")
    from app.db.variant_models import SummarySelection
    from app.services.variants import now
    if db.scalar(select(SummarySelection.id).where(SummarySelection.user_id == current_user_id(db),
        SummarySelection.kind == "meeting", SummarySelection.status == "open", SummarySelection.summary_id.is_(None),
        SummarySelection.expires_at > now(), SummarySelection.folder_ids.overlap(ids)).limit(1)) is not None:
        fail(409, "folder_processing", "Завершите или отмените выбор варианта в этой папке.")
    candidates = list(db.scalars(select(Summary.id).join(SummaryFolder,
        SummaryFolder.summary_id == Summary.id).where(SummaryFolder.folder_id.in_(ids),
        Summary.user_id == current_user_id(db)).distinct()))
    transcript_ids = list(db.scalars(select(Summary.transcript_id).where(Summary.id.in_(candidates)).distinct()))
    transcripts = list(db.scalars(select(Transcript).where(Transcript.id.in_(transcript_ids)).order_by(Transcript.id).with_for_update()))
    summaries = list(db.scalars(select(Summary).where(Summary.id.in_(candidates)).order_by(Summary.id).with_for_update()))
    db.execute(delete(SummaryFolder).where(SummaryFolder.folder_id.in_(ids)))
    deleted_transcripts = set()
    for summary in summaries:
        summary.updated_at = func.now()
        remaining = db.scalar(select(SummaryFolder.folder_id).where(SummaryFolder.summary_id == summary.id).limit(1))
        if remaining is None:
            deleted_transcripts.add(summary.transcript_id)
            db.delete(summary)
    db.flush()
    for transcript in transcripts:
        if transcript.id in deleted_transcripts:
            cleanup_transcript(db, transcript)
    db.execute(delete(Folder).where(Folder.id.in_(ids)))
