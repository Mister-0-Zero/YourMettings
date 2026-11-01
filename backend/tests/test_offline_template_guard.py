from uuid import uuid4
import pytest
from fastapi import BackgroundTasks
from sqlalchemy import func, select
from app.db.models import Transcript
from app.integrations.ollama import get_generator
from app.main import app
from test_processing import FakeGenerator

pytestmark = pytest.mark.integration


def test_text_cached_template_version_is_checked_and_key_not_occupied(client, database):
    folder = client.post('/api/v1/folders', json={'name':'Text offline'}).json()['id']
    template = client.get('/api/v1/summary-templates').json()['items'][0]
    body = {'text':'Synthetic offline input', 'title':'Text cache check', 'folder_ids':[folder],
        'template_id':template['id'], 'expected_template_version':'0'*64}
    headers = {'Idempotency-Key':'text-offline-template'}
    app.dependency_overrides[get_generator] = lambda: FakeGenerator()
    failed = client.post('/api/v1/transcripts/process', json=body, headers=headers)
    assert failed.status_code == 409 and failed.json()['error']['code'] == 'template_version_conflict'
    with database() as db:
        assert db.scalar(select(func.count()).select_from(Transcript)) == 0
    body['expected_template_version'] = template['version']
    accepted = client.post('/api/v1/transcripts/process', json=body, headers=headers)
    assert accepted.status_code == 202
    conflict = client.post('/api/v1/transcripts/process', json={**body,'expected_template_version':'1'*64}, headers=headers)
    assert conflict.status_code == 409 and conflict.json()['error']['code'] == 'idempotency_conflict'


def test_template_version_ignores_metadata_but_tracks_prompt(client):
    from app.template_schemas import TemplateOut
    from app.services.template_catalog import SYSTEM_TEMPLATES
    from datetime import datetime, timezone, timedelta
    values = {**SYSTEM_TEMPLATES[0], 'created_at':datetime.now(timezone.utc), 'updated_at':datetime.now(timezone.utc)}
    before = TemplateOut(**values)
    after = TemplateOut(**{**values, 'owner_user_id':uuid4(), 'updated_at':values['updated_at']+timedelta(seconds=1)})
    assert before.version == after.version
    edited = TemplateOut(**{**values,'general_instructions':values['general_instructions']+' Extra instruction.'})
    assert edited.version != before.version

