"""Upgrade populated PostgreSQL from 0008; UUIDs, ownership and source data survive."""
from pathlib import Path
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from app.core.config import settings
from app.db.session import TEST_USER_ID
from app.db.models import Folder, Summary, SummaryFolder, Transcript


def test_populated_legacy_upgrade_keeps_ids_and_relations(database):
    with database.begin() as db:
        folder = Folder(user_id=TEST_USER_ID, name='Private old folder')
        transcript = Transcript(owner_user_id=TEST_USER_ID,text='Private existing transcript',source_hash='a'*64)
        db.add_all([folder,transcript])
        db.flush()
        summary = Summary(user_id=TEST_USER_ID,transcript_id=transcript.id,title='Old meeting',content='Old result')
        db.add(summary)
        db.flush()
        db.add(SummaryFolder(summary_id=summary.id,folder_id=folder.id))
    cfg = Config(str(Path(__file__).resolve().parents[1]/'alembic.ini'))
    cfg.attributes['database_url'] = settings.test_database_url
    command.downgrade(cfg,'0008')
    def snapshot():
        with database() as db:
            return {name:db.execute(text('SELECT row_to_json(t)::text FROM '+name+' t ORDER BY row_to_json(t)::text')).scalars().all()
                for name in ('users','folders','transcripts','summaries','summary_folders','summary_templates')}
    before = snapshot()
    try:
        command.upgrade(cfg,'head')
        after = snapshot()
        for name in before:
            if name != 'users':
                assert after[name] == before[name]
        with database() as db:
            user = db.execute(text('SELECT id,email,password_hash,legacy_claim_pending,email_verified_at FROM users')).one()
            assert user.id == TEST_USER_ID
            assert user.email == 'test@yourmettings.local' and user.password_hash == '!disabled'
            assert user.legacy_claim_pending and user.email_verified_at is None
            assert db.execute(text('SELECT count(*) FROM auth_sessions')).scalar() == 0
    finally:
        command.upgrade(cfg,'head')
