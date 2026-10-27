"""Tenant boundaries exercised with real OTP sessions and PostgreSQL rows.

Inference and mail transport are replaced through their dependency seams only.
"""
import hashlib
from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import sessionmaker

from app.auth_models import AuthAccessToken
from app.db.audio_models import AudioSession
from app.db.models import Folder, Summary, Transcript, User
from app.db.session import current_user_id, initialize_database
from app.db.variant_models import SummaryCandidate, SummarySelection
from app.integrations.ollama import get_generator
from app.main import app
from app.services import auth
from app.services.audio import claim_chunk, finish_chunk, recover_worker
from app.services.variants import expire_all_selections
from test_auth import auth_client, login, sender  # noqa: F401 - shared pytest fixtures
from test_audio import wav_bytes
from test_processing import FakeGenerator
from test_templates import definition

pytestmark = pytest.mark.integration


@dataclass
class Actor:
    client: object
    tokens: dict

    @property
    def id(self):
        return UUID(self.tokens["user"]["id"])

    def call(self, method, path, **kwargs):
        headers = {"Authorization": "Bearer " + self.tokens["access_token"], **kwargs.pop("headers", {})}
        return self.client.request(method, "/api/v1" + path, headers=headers, **kwargs)

    def folder(self, name="Private"):
        result = self.call("POST", "/folders", json={"name": name})
        assert result.status_code == 201, result.text
        return result.json()["id"]

    def transcript(self, text="Private source", key=None):
        result = self.call("POST", "/transcripts", json={"text": text},
                           headers={"Idempotency-Key": key} if key else {})
        assert result.status_code in (200, 201), result.text
        return result.json()["id"]


@pytest.fixture
def tenants(auth_client, sender, database):
    # Shared legacy feature fixtures seed after migrations; reproduce the actual
    # 0009 reservation state explicitly before the first real corporate login.
    with database.begin() as db:
        db.get(User, auth.LEGACY_USER_ID).legacy_claim_pending = True
    fake = FakeGenerator()
    app.dependency_overrides[get_generator] = lambda: fake
    alice = Actor(auth_client, login(auth_client, sender, "alice@cbr.ru", remember=True))
    bob = Actor(auth_client, login(auth_client, sender, "bob@cbr.ru", remember=False))
    return alice, bob


def checked(result, status):
    assert result.status_code == status, result.text
    return result.json() if status != 204 else None


def meeting(actor):
    folder = actor.folder()
    transcript = actor.transcript()
    checked(actor.call("POST", f"/transcripts/{transcript}/process",
                       json={"title": "Private meeting", "folder_ids": [folder]}), 202)
    state = checked(actor.call("GET", f"/transcripts/{transcript}/processing"), 200)
    assert state["status"] == "ready"
    return folder, transcript, state["summary_id"]


def selection(actor, folder=None, key="selection-key"):
    return checked(actor.call("POST", "/summary-selections",
        json={"text": "Source for private candidate", "title": "Candidate meeting",
              "folder_ids": [folder or actor.folder()]}, headers={"Idempotency-Key": key}), 201)


def upload(actor, session_id, content=None):
    return actor.call("POST", f"/audio-sessions/{session_id}/chunks",
        params={"sequence_number": 0, "start_ms": 0},
        content=wav_bytes() if content is None else content,
        headers={"Content-Type": "application/octet-stream"})


def background_factory(database):
    # No identity defaults: this is how standalone workers construct sessions.
    return sessionmaker(database.kw["bind"], expire_on_commit=False)


def test_transcript_summary_and_folder_idor(tenants, database):
    alice, bob = tenants
    alice_folder = alice.folder("Alice")
    bob_folder, transcript, summary = meeting(bob)
    draft = bob.transcript("Bob private draft")
    for method, path, body in (
        ("GET", f"/transcripts/{draft}", None),
        ("PATCH", f"/transcripts/{draft}", {"text": "stolen"}),
        ("POST", f"/transcripts/{draft}/process", {"title": "stolen", "folder_ids": [alice_folder]}),
        ("GET", f"/transcripts/{transcript}/processing", None),
        ("GET", f"/summaries/{summary}", None),
        ("PATCH", f"/summaries/{summary}", {"title": "stolen"}),
        ("PUT", f"/summaries/{summary}/folders", {"folder_ids": [alice_folder]}),
        ("DELETE", f"/summaries/{summary}", None),
        ("PATCH", f"/folders/{bob_folder}", {"name": "stolen"}),
        ("DELETE", f"/folders/{bob_folder}?mode=with_contents&confirm=true", None),
    ):
        checked(alice.call(method, path, **({"json": body} if body is not None else {})), 404)
    assert checked(alice.call("GET", "/summaries"), 200)["items"] == []
    tree = checked(alice.call("GET", "/folders"), 200)
    assert [item["id"] for item in tree["items"]] == [alice_folder]
    checked(alice.call("GET", "/summaries", params={"folder_id": bob_folder}), 404)
    checked(alice.call("POST", "/folders", json={"name": "child", "parent_id": bob_folder}), 404)
    checked(bob.call("PUT", f"/summaries/{summary}/folders", json={"folder_ids": [alice_folder]}), 404)
    checked(bob.call("GET", f"/summaries/{summary}"), 200)
    with database() as db:
        assert db.get(Transcript, UUID(draft)).text == "Bob private draft"
        assert db.get(Summary, UUID(summary)).user_id == bob.id
        assert db.get(Folder, UUID(bob_folder)).name == "Private"


def test_foreign_folder_placement_and_body_identity_rejected(tenants):
    alice, bob = tenants
    foreign = bob.folder()
    own = alice.folder()
    checked(alice.call("POST", "/transcripts/process", json={
        "text": "private", "title": "Bad placement", "folder_ids": [foreign]}), 404)
    checked(alice.call("POST", "/audio-sessions", json={"title": "bad", "folder_ids": [foreign]}), 404)
    checked(alice.call("POST", "/summary-selections", json={
        "text": "private", "title": "bad", "folder_ids": [foreign]},
        headers={"Idempotency-Key": "foreign-placement"}), 404)
    for path, body in (
        ("/transcripts", {"text": "bad"}),
        ("/folders", {"name": "bad"}),
        ("/audio-sessions", {"title": "bad", "folder_ids": [own]}),
    ):
        checked(alice.call("POST", path, json={**body, "user_id": str(bob.id)}), 422)


def test_user_templates_and_system_templates_boundaries(tenants, database):
    alice, bob = tenants
    payload = definition()
    private = checked(bob.call("POST", "/summary-templates", json=payload), 201)
    private_id = private["id"]
    for method, suffix, body in (
        ("GET", "", None), ("PUT", "", payload), ("DELETE", "", None), ("POST", "/copy", {}),
    ):
        checked(alice.call(method, f"/summary-templates/{private_id}{suffix}",
            **({"json": body} if body is not None else {})), 404)
    rows = checked(alice.call("GET", "/summary-templates"), 200)["items"]
    assert private_id not in {item["id"] for item in rows}
    system = next(item for item in rows if item["is_system"])
    checked(alice.call("GET", f"/summary-templates/{system['id']}"), 200)
    checked(alice.call("PUT", f"/summary-templates/{system['id']}", json=payload), 403)
    checked(alice.call("DELETE", f"/summary-templates/{system['id']}"), 403)
    copy = checked(alice.call("POST", f"/summary-templates/{system['id']}/copy", json={}), 201)
    assert copy["owner_user_id"] == str(alice.id) and not copy["is_system"]
    checked(bob.call("GET", f"/summary-templates/{copy['id']}"), 404)
    checked(alice.call("PUT", f"/summary-templates/{copy['id']}", json=payload), 200)
    checked(alice.call("DELETE", f"/summary-templates/{copy['id']}"), 204)
    # A foreign template cannot be smuggled into generation parameters.
    folder = alice.folder()
    tid = alice.transcript()
    checked(alice.call("POST", f"/transcripts/{tid}/process", json={
        "title": "bad template", "folder_ids": [folder], "template_id": private_id}), 404)


def test_preview_selection_candidate_isolation_and_worker_owner(tenants, database):
    alice, bob = tenants
    preview = checked(bob.call("POST", "/template-previews", json={"text": "Bob preview", "template": definition()},
                              headers={"Idempotency-Key": "preview"}), 202)
    checked(alice.call("GET", f"/template-previews/{preview['id']}"), 404)
    checked(alice.call("DELETE", f"/template-previews/{preview['id']}?confirm=true"), 404)
    assert checked(bob.call("GET", f"/template-previews/{preview['id']}"), 200)["status"] == "ready"
    selected = selection(bob)
    candidate = checked(bob.call("POST", f"/summary-selections/{selected['id']}/candidates", json={},
                                 headers={"Idempotency-Key": "candidate"}), 202)
    for method, path, body in (
        ("GET", f"/summary-selections/{selected['id']}", None),
        ("DELETE", f"/summary-selections/{selected['id']}?confirm=true", None),
        ("POST", f"/summary-selections/{selected['id']}/candidates", {}),
        ("POST", f"/summary-selections/{selected['id']}/accept", {"candidate_id": candidate["id"]}),
        ("GET", f"/summary-candidates/{candidate['id']}", None),
    ):
        checked(alice.call(method, path, headers={"Idempotency-Key": "foreign-candidate"},
            **({"json": body} if body is not None else {})), 404)
    ready = checked(bob.call("GET", f"/summary-candidates/{candidate['id']}"), 200)
    assert ready["status"] == "ready"
    accepted = checked(bob.call("POST", f"/summary-selections/{selected['id']}/accept",
                                json={"candidate_id": candidate["id"]}), 200)
    with database() as db:
        assert db.get(Summary, UUID(accepted["id"])).user_id == bob.id
        assert db.get(Transcript, UUID(selected["transcript_id"])).owner_user_id == bob.id
        assert db.get(SummarySelection, UUID(selected["id"])).user_id == bob.id
    checked(alice.call("GET", f"/summaries/{accepted['id']}"), 404)


def test_same_idempotency_keys_are_scoped_to_each_user(tenants, database):
    alice, bob = tenants
    tids = [actor.transcript("same body", key="same-key") for actor in tenants]
    assert tids[0] != tids[1]
    sids, selections = [], []
    for actor in tenants:
        folder = actor.folder()
        audio = checked(actor.call("POST", "/audio-sessions", json={"title": "same", "folder_ids": [folder]},
                                    headers={"Idempotency-Key": "same-key"}), 201)
        sids.append(audio["id"])
        selections.append(selection(actor, folder=folder, key="same-key")["id"])
    assert len(set(sids)) == len(set(selections)) == 2
    with database() as db:
        assert {db.get(Transcript, UUID(tid)).owner_user_id for tid in tids} == {alice.id, bob.id}


def test_administrator_does_not_gain_cross_tenant_access(tenants, auth_client, sender):
    alice, _ = tenants
    admin = Actor(auth_client, login(auth_client, sender, "owner@example.org"))
    assert admin.tokens["user"]["role"] == "admin"
    folder, tid, summary = meeting(alice)
    checked(admin.call("GET", f"/transcripts/{tid}"), 404)
    checked(admin.call("GET", f"/summaries/{summary}"), 404)
    checked(admin.call("PATCH", f"/folders/{folder}", json={"name": "stolen"}), 404)
    assert checked(admin.call("GET", "/summaries"), 200)["total"] == 0
    own = admin.folder()
    assert [row["id"] for row in checked(admin.call("GET", "/folders"), 200)["items"]] == [own]


def test_audio_refresh_retry_and_background_ownership(tenants, database):
    alice, bob = tenants
    folder = bob.folder()
    audio = checked(bob.call("POST", "/audio-sessions", json={"title": "Bob recording", "folder_ids": [folder]}), 201)
    sid = audio["id"]
    for method, path, body in (
        ("GET", f"/audio-sessions/{sid}", None),
        ("DELETE", f"/audio-sessions/{sid}?confirm=true", None),
        ("POST", f"/audio-sessions/{sid}/complete", {"expected_chunk_count": 1}),
        ("POST", f"/audio-sessions/{sid}/retry", {}),
        ("POST", f"/audio-sessions/{sid}/confirm", {"confirm": True,
            "reviewed_text_sha256": "0" * 64, "title": "stolen", "folder_ids": [folder]}),
    ):
        checked(alice.call(method, path, **({"json": body} if body is not None else {})), 404)
    checked(upload(alice, sid, content=b"not audio"), 404)  # Ownership before decoder.
    checked(upload(bob, sid), 201)
    with database.begin() as db:
        db.get(AuthAccessToken, auth.digest(bob.tokens["access_token"])).expires_at = auth.utcnow() - timedelta(seconds=1)
    checked(upload(bob, sid), 401)
    bob.tokens = checked(bob.call("POST", "/auth/refresh", json={"session_token": bob.tokens["session_token"]},
                                  headers={"Idempotency-Key": "audio-refresh"}), 200)
    checked(upload(bob, sid), 200)
    checked(bob.call("POST", f"/audio-sessions/{sid}/complete", json={"expected_chunk_count": 1}), 202)
    generation = uuid4()
    background = background_factory(database)
    with background.begin() as db:
        assert "user_id" not in db.info
        recover_worker(db, generation, 999)
        job = claim_chunk(db, generation)
        assert job is not None
    with background.begin() as db:
        assert "user_id" not in db.info
        assert finish_chunk(db, job, generation, text="Bob audio transcription")
    ready = checked(bob.call("GET", f"/audio-sessions/{sid}"), 200)
    assert ready["status"] == "ready_for_review"
    tid = ready["transcript_id"]
    checked(alice.call("GET", f"/transcripts/{tid}"), 404)
    checked(bob.call("POST", f"/audio-sessions/{sid}/confirm", json={
        "confirm": True, "reviewed_text_sha256": hashlib.sha256(b"Bob audio transcription").hexdigest(),
        "title": "Bob recording", "folder_ids": [folder]}), 202)
    result = checked(bob.call("GET", f"/transcripts/{tid}/processing"), 200)
    assert result["status"] == "ready"
    with database() as db:
        assert db.get(AudioSession, UUID(sid)).user_id == bob.id
        assert db.get(Transcript, UUID(tid)).owner_user_id == bob.id
        assert db.get(Summary, UUID(result["summary_id"])).user_id == bob.id
    checked(alice.call("GET", f"/summaries/{result['summary_id']}"), 404)


def test_shared_summary_does_not_grant_raw_source_and_survives_owner_delete(tenants, database):
    alice, bob = tenants
    _, tid, alice_summary = meeting(alice)
    # Existing schema permits separate summaries over the same source. Seed that
    # supported legacy relationship, not a public sharing endpoint.
    with database.begin() as db:
        shared = Summary(user_id=bob.id, transcript_id=UUID(tid), title="Bob retained copy", content="Private copy")
        db.add(shared)
        db.flush()
        shared_id = str(shared.id)
    checked(bob.call("GET", f"/summaries/{shared_id}"), 200)
    checked(bob.call("GET", f"/transcripts/{tid}"), 404)
    checked(bob.call("GET", f"/transcripts/{tid}/processing"), 404)
    checked(alice.call("DELETE", f"/summaries/{alice_summary}"), 204)
    checked(bob.call("GET", f"/summaries/{shared_id}"), 200)
    with database() as db:
        assert db.get(Transcript, UUID(tid)) is not None
    checked(bob.call("DELETE", f"/summaries/{shared_id}"), 204)
    with database() as db:
        # Removing a derived copy cannot delete Alice's source, even when that
        # copy happened to be the final remaining summary.
        assert db.get(Transcript, UUID(tid)).owner_user_id == alice.id
    checked(alice.call("GET", f"/transcripts/{tid}"), 200)


def test_maintenance_recovers_all_tenants_without_http_context(tenants, database):
    background = background_factory(database)
    selection_ids = []
    source_ids = []
    for actor in tenants:
        selected = selection(actor)
        selection_ids.append(UUID(selected["id"]))
        source_ids.append(UUID(selected["transcript_id"]))
    with background.begin() as db:
        assert "user_id" not in db.info
        with pytest.raises(HTTPException) as missing:
            current_user_id(db)
        assert missing.value.status_code == 401
        for selection_id in selection_ids:
            db.get(SummarySelection, selection_id).expires_at = auth.utcnow() - timedelta(seconds=1)
        expire_all_selections(db)
        assert "user_id" not in db.info
    with background() as db:
        for selection_id, source_id in zip(selection_ids, source_ids):
            assert db.get(SummarySelection, selection_id).status == "expired"
            assert db.get(Transcript, source_id) is None
    # Startup recovery also visits jobs for both tenants without a global owner.
    interrupted = []
    with background.begin() as db:
        for actor in tenants:
            row = Transcript(owner_user_id=actor.id, text="restart", source_hash="0" * 64,
                             processing_status="summarizing")
            db.add(row)
            db.flush()
            interrupted.append(row.id)
    initialize_database(background)
    with background() as db:
        assert "user_id" not in db.info
        for tid in interrupted:
            row = db.get(Transcript, tid)
            assert row.processing_status == "error" and row.error_code == "processing_interrupted"


def test_legacy_data_is_not_claimed_by_first_corporate_login(tenants, database):
    alice, bob = tenants
    with database() as db:
        legacy = db.get(User, auth.LEGACY_USER_ID)
        assert legacy is not None and legacy.legacy_claim_pending
        assert alice.id != legacy.id and bob.id != legacy.id
        assert legacy.email == "test@yourmettings.local"


def test_asr_restart_fences_old_jobs_and_preserves_both_owners(tenants, database):
    audio_ids = {}
    for actor in tenants:
        sid = checked(actor.call("POST", "/audio-sessions", json={
            "title": "Restart recording", "folder_ids": [actor.folder()]}), 201)["id"]
        audio_ids[sid] = actor.id
        checked(upload(actor, sid), 201)
        checked(actor.call("POST", f"/audio-sessions/{sid}/complete", json={"expected_chunk_count": 1}), 202)
    background = background_factory(database)
    old_generation, generation = uuid4(), uuid4()
    with background.begin() as db:
        recover_worker(db, old_generation, 999)
        abandoned = [claim_chunk(db, old_generation), claim_chunk(db, old_generation)]
        assert all(abandoned)
    with background.begin() as db:
        recover_worker(db, generation, 999)
        for job in abandoned:
            assert not finish_chunk(db, job, old_generation, text="stale result")
    for _ in range(2):
        with background.begin() as db:
            assert "user_id" not in db.info
            job = claim_chunk(db, generation)
            assert job is not None
        with background.begin() as db:
            assert finish_chunk(db, job, generation, text="Recovered owner transcription")
    with background() as db:
        assert "user_id" not in db.info
        for sid, owner_id in audio_ids.items():
            audio = db.get(AudioSession, UUID(sid))
            source = db.get(Transcript, audio.transcript_id)
            assert audio.status == "ready_for_review"
            assert source.owner_user_id == audio.user_id == owner_id
            assert source.text == "Recovered owner transcription"
