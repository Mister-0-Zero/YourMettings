from uuid import UUID
from sqlalchemy import select
from app.core.config import settings
from app.db.models import Transcript
from app.db.audio_models import AudioChunk, AudioSession
from test_auth import auth_client, sender
from test_tenant_isolation import tenants, checked, selection, upload


def test_classic_and_candidate_capacity_is_shared_per_user(tenants,database):
    alice,bob=tenants
    chosen=selection(alice)
    with database.begin() as db:
        for _ in range(2):
            db.add(Transcript(owner_user_id=alice.id,text='busy',source_hash='0'*64,processing_status='summarizing'))
    denied=alice.call('POST',f"/summary-selections/{chosen['id']}/candidates",json={},headers={'Idempotency-Key':'busy'})
    assert denied.status_code==429
    body={'text':'new source','title':'test','folder_ids':[alice.folder()]}
    assert alice.call('POST','/transcripts/process',json=body).status_code==429
    body['folder_ids']=[bob.folder()]
    assert bob.call('POST','/transcripts/process',json=body).status_code==202


def test_audio_cap_does_not_block_idempotent_repeat_or_other_user(tenants,monkeypatch):
    alice,bob=tenants
    monkeypatch.setattr(settings,'audio_max_active_sessions_per_user',1)
    headers={'Idempotency-Key':'one'}
    first=checked(alice.call('POST','/audio-sessions',json={'title':'First'},headers=headers),201)
    assert alice.call('POST','/audio-sessions',json={'title':'Second'}).status_code==429
    repeated=checked(alice.call('POST','/audio-sessions',json={'title':'First'},headers=headers),200)
    assert first['id']==repeated['id']
    assert bob.call('POST','/audio-sessions',json={'title':'Own'}).status_code==201


def test_audio_storage_quota_preserves_unsent_chunk_and_allows_duplicate(tenants,monkeypatch,database):
    alice,bob=tenants
    monkeypatch.setattr(settings,'audio_max_pending_chunks_per_user',1)
    aid=checked(alice.call('POST','/audio-sessions',json={'title':'A'}),201)['id']
    bid=checked(bob.call('POST','/audio-sessions',json={'title':'B'}),201)['id']
    assert upload(alice,aid).status_code==201
    assert upload(alice,aid).status_code==200
    from test_audio import wav_bytes
    second=alice.call('POST',f'/audio-sessions/{aid}/chunks',params={'sequence_number':1,'start_ms':200},
        content=wav_bytes(),headers={'Content-Type':'application/octet-stream'})
    assert second.status_code==429
    assert upload(bob,bid).status_code==201
    with database() as db:
        assert len(db.scalars(select(AudioChunk).where(AudioChunk.session_id==UUID(aid))).all())==1
