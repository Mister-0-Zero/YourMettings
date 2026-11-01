from concurrent.futures import ThreadPoolExecutor
from uuid import UUID, uuid4
import pytest
from sqlalchemy import func, select

from app.db.audio_models import AudioSession
from app.db.job_models import ProcessingJob
from app.db.models import Summary
from app.services.jobs import run_job
from test_audio import upload, do_job, worker
from test_durable_pipeline import automatic, only_job
from test_processing import FakeGenerator

pytestmark = pytest.mark.integration
BASE = '/api/v1/audio-sessions'


def test_lost_create_ack_then_edited_parameters_save_new_intent_same_session(client, database):
    old_folder = client.post('/api/v1/folders', json={'name':'Old intent'}).json()['id']
    new_folder = client.post('/api/v1/folders', json={'name':'New intent'}).json()['id']
    initial = {'title':'Old frozen creation', 'folder_ids':[old_folder], 'processing_mode':'automatic'}
    create_key = {'Idempotency-Key':'frozen-create'}
    accepted = client.post(BASE, json=initial, headers=create_key)
    sid = accepted.json()['id']
    with database() as db:
        initial_hash = db.get(AudioSession, UUID(sid)).request_hash
    # Unknown create outcome is reconciled exactly; only then send a new explicit intent.
    assert client.post(BASE, json=initial, headers=create_key).json()['id'] == sid
    updated = {'title':'Edited offline title', 'folder_ids':[new_folder], 'detail_level':'brief'}
    params_url = f'{BASE}/{sid}/pipeline/parameters'
    params_key = {'Idempotency-Key':'edited-parameters'}
    saved = client.put(params_url, json=updated, headers=params_key)
    assert saved.status_code == 200
    assert saved.json()['parameters']['title'] == updated['title']
    assert client.put(params_url, json=updated, headers=params_key).json() == saved.json()
    assert client.put(params_url, json={**updated,'title':'Other'}, headers=params_key).status_code == 409
    assert client.post(BASE, json=initial, headers=create_key).json()['id'] == sid
    upload(client, sid)
    client.post(f'{BASE}/{sid}/complete', json={'expected_chunk_count':1})
    do_job(database, worker(database))
    run_job(database, only_job(database), FakeGenerator())
    final = client.get(f'{BASE}/{sid}').json()
    result = client.get('/api/v1/summaries/'+final['pipeline']['summary_id']).json()
    assert result['title'] == updated['title'] and result['folder_ids'] == [new_folder]
    assert result['generation_options']['detail_level'] == 'brief'
    # Receipt replays after complete never write back the old receiving state.
    assert client.put(params_url, json=updated, headers=params_key).json() == saved.json()
    assert client.get(f'{BASE}/{sid}').json()['pipeline']['phase'] == 'completed'
    with database() as db:
        assert db.get(AudioSession, UUID(sid)).request_hash == initial_hash
        assert db.scalar(select(func.count()).select_from(AudioSession)) == 1
        assert db.scalar(select(func.count()).select_from(Summary)) == 1


def test_parameters_race_complete_is_serialized_and_never_changes_accepted_job(client, database):
    session, body = automatic(client)
    sid = session['id']
    upload(client, sid)
    do_job(database, worker(database))  # ASR chunk done, source not assembled until complete.
    update = {'title':'New pre-complete settings','folder_ids':body['folder_ids'],'detail_level':'brief'}
    with ThreadPoolExecutor(2) as pool:
        pending = pool.submit(client.put, f'{BASE}/{sid}/pipeline/parameters', json=update,
            headers={'Idempotency-Key':'race-parameters'})
        completed = client.post(f'{BASE}/{sid}/complete', json={'expected_chunk_count':1})
        changed = pending.result(timeout=10)
    assert completed.status_code == 202
    assert changed.status_code in (200,409)
    if changed.status_code == 409:
        assert changed.json()['error']['code'] == 'pipeline_parameters_locked'
    late = client.put(f'{BASE}/{sid}/pipeline/parameters', json=update, headers={'Idempotency-Key':'too-late'})
    assert late.status_code == 409 and late.json()['error']['code'] == 'pipeline_parameters_locked'
    run_job(database, only_job(database), FakeGenerator())
    final = client.get(f'{BASE}/{sid}').json()
    result = client.get('/api/v1/summaries/'+final['pipeline']['summary_id']).json()
    assert result['title'] == (update['title'] if changed.status_code == 200 else body['title'])


def test_parameter_update_validates_template_folder_and_operation_key_scope(client, database):
    session, body = automatic(client)
    sid = session['id']
    url = f'{BASE}/{sid}/pipeline/parameters'
    params = {'title':body['title'],'folder_ids':[str(uuid4())]}
    key = {'Idempotency-Key':'params-validated'}
    assert client.put(url, json=params, headers=key).status_code == 404
    params['folder_ids'] = body['folder_ids']
    assert client.put(url, json={**params,'expected_template_version':'0'*64}, headers=key).status_code == 409
    # Rejected validation does not occupy the key.
    assert client.put(url, json=params, headers=key).status_code == 200
    repeated_other_operation = client.post(f'{BASE}/{sid}/pipeline/retry', json={}, headers=key)
    assert repeated_other_operation.status_code == 409
    assert repeated_other_operation.json()['error']['code'] == 'idempotency_conflict'
    assert client.put(url, json=params).status_code == 422
    assert client.put(url, json={**params,'folder_ids':[]}, headers={'Idempotency-Key':'empty'}).status_code == 422
    assert client.put(f'{BASE}/{uuid4()}/pipeline/parameters', json=params, headers=key).status_code == 404


def test_concurrent_identical_parameter_updates_have_one_receipt_and_snapshot(client, database):
    session, body = automatic(client)
    url = f"{BASE}/{session['id']}/pipeline/parameters"
    params = {'title':'Same new intent','folder_ids':body['folder_ids']}
    headers = {'Idempotency-Key':'same-parameters'}
    with ThreadPoolExecutor(2) as pool:
        responses = list(pool.map(lambda _:client.put(url,json=params,headers=headers), range(2)))
    assert [r.status_code for r in responses] == [200,200]
    assert responses[0].json() == responses[1].json()
    assert client.get(f"{BASE}/{session['id']}").json()['parameters']['title'] == params['title']

