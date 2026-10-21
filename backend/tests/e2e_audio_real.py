"""Opt-in real ASR + PostgreSQL + Qwen test. Never collected by pytest.

Run from backend: python tests/e2e_audio_real.py --audio <local-recording> [--chunk-seconds 300]
Creates two M4A/AAC chunks and only removes its own diagnostic meeting on success.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

import httpx
from sqlalchemy import select
from app.core.config import settings
from app.db.audio_models import AudioChunk, AudioSession, ASRWorkerState
from app.db.models import Summary, Transcript
from app.db.session import get_session_factory
from app.services.audio_validation import ffmpeg_path, validate_audio


def checked(response, code):
    if response.status_code != code:
        raise RuntimeError(f"HTTP {response.status_code}, expected {code}: {response.text[:500]}")
    return response.json() if code != 204 else None


def snapshot(db, model, field):
    return {row.id: hashlib.sha256(getattr(row, field).encode()).hexdigest() for row in db.scalars(select(model))}


def run(args):
    factory = get_session_factory()
    with factory() as db:
        before_transcripts = snapshot(db, Transcript, "text")
        before_summaries = snapshot(db, Summary, "content")
        worker_generation = db.get(ASRWorkerState, 1).generation
    with tempfile.TemporaryDirectory(prefix="ym-audio-e2e-") as directory, httpx.Client(base_url=args.base, timeout=40, trust_env=False) as client:
        prefix = "/api/v1"
        folder = checked(client.post(prefix + "/folders", json={"name": "ASR E2E " + str(uuid.uuid4())[:8]}), 201)
        params = {"title": "ASR E2E аудиозапись", "folder_ids": [folder["id"]], "detail_level": "brief",
            "focus_areas": [], "additional_instructions": "Это фрагмент аудиокниги: кратко перескажи содержание без выдуманных поручений."}
        session = checked(client.post(prefix + "/audio-sessions", json=params, headers={"Idempotency-Key": str(uuid.uuid4())}), 201)
        sid = session["id"]
        path = prefix + "/audio-sessions/" + sid
        print(json.dumps({"audio_session_id": sid, "folder_id": folder["id"]}), flush=True)
        payloads, durations = [], []
        for sequence in range(2):
            target = Path(directory) / f"{sequence}.m4a"
            converted = subprocess.run([str(ffmpeg_path()), "-nostdin", "-v", "error", "-ss", str(sequence * args.chunk_seconds),
                "-i", str(args.audio.resolve()), "-t", str(args.chunk_seconds), "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "64k", str(target)],
                capture_output=True, timeout=60)
            assert converted.returncode == 0, "E2E fixture conversion failed"
            data = target.read_bytes()
            _, duration = validate_audio(data)
            assert duration > 0
            payloads.append(data)
            durations.append(duration)
        started = time.monotonic()
        for sequence in (1, 0):
            metadata = {"sequence_number": sequence, "start_ms": 0 if sequence == 0 else durations[0],
                "duration_ms": durations[sequence], "content_sha256": hashlib.sha256(payloads[sequence]).hexdigest()}
            accepted = checked(client.post(path + "/chunks", params=metadata, content=payloads[sequence],
                headers={"Content-Type": "application/octet-stream"}), 201)
            assert accepted["safe_to_delete_local"] is True
            assert checked(client.post(path + "/chunks", params=metadata, content=payloads[sequence]), 200)["chunk"]["id"] == accepted["chunk"]["id"]
        checked(client.post(path + "/complete", json={"expected_chunk_count": 2}), 202)
        deadline = time.monotonic() + settings.asr_job_timeout_seconds * 2
        while time.monotonic() < deadline:
            session = checked(client.get(path), 200)
            if session["status"] == "ready_for_review":
                break
            assert session["status"] != "failed", session["error_code"]
            time.sleep(1)
        else:
            raise RuntimeError("ASR deadline exceeded")
        tid = session["transcript_id"]
        transcript = checked(client.get(prefix + "/transcripts/" + tid), 200)
        assert transcript["text"].strip() and not transcript["is_locked"]
        assert session["processing"]["status"] == "not_started"
        with factory() as db:
            chunks = db.scalars(select(AudioChunk).where(AudioChunk.session_id == uuid.UUID(sid))).all()
            assert len(chunks) == 2 and all(c.payload is None and c.text and c.segments for c in chunks)
            assert db.get(ASRWorkerState, 1).generation == worker_generation, "Model worker restarted during test"
            assert not db.scalar(select(Summary).where(Summary.transcript_id == uuid.UUID(tid)))
        asr_seconds = round(time.monotonic() - started, 3)
        # Exercise the review PATCH; the original is intentionally left unchanged.
        checked(client.patch(prefix + "/transcripts/" + tid, json={"text": transcript["text"]}), 200)
        session = checked(client.get(path), 200)
        confirmation = {**params, "confirm": True, "reviewed_text_sha256": session["transcript_sha256"], "boundaries_reviewed": True}
        checked(client.post(path + "/confirm", json=confirmation), 202)
        checked(client.post(path + "/confirm", json=confirmation), 200)
        deadline = time.monotonic() + settings.llm_timeout_seconds + 60
        while time.monotonic() < deadline:
            state = checked(client.get(prefix + "/transcripts/" + tid + "/processing"), 200)
            if state["status"] == "ready":
                break
            assert state["status"] != "error", state["error"]
            time.sleep(2)
        else:
            raise RuntimeError("Qwen deadline exceeded")
        summary = checked(client.get(prefix + "/summaries/" + state["summary_id"]), 200)
        assert summary["content"].strip()
        with factory() as db:
            assert db.get(Transcript, uuid.UUID(tid)).processing_attempt == 1
        metrics = {"audio_seconds": sum(durations)/1000, "asr_elapsed_seconds": asr_seconds,
            "transcript_characters": len(transcript["text"]), "summary_characters": len(summary["content"]),
            "total_seconds": round(time.monotonic()-started, 3), "chunks": 2, "container": "M4A/AAC",
            "asr_model": "v3_e2e_rnnt", "llm_model": settings.ollama_model,
            "worker_generation_unchanged": True, "qwen_attempts": 1}
        checked(client.delete(prefix + "/folders/" + folder["id"], params={"mode": "with_contents", "confirm": True}), 204)
        assert client.get(path).status_code == 404
        with factory() as db:
            after_transcripts = snapshot(db, Transcript, "text")
            after_summaries = snapshot(db, Summary, "content")
            assert all(after_transcripts.get(k) == v for k, v in before_transcripts.items())
            assert all(after_summaries.get(k) == v for k, v in before_summaries.items())
        metrics["existing_records_unchanged"] = True
        print(json.dumps(metrics, ensure_ascii=False, indent=2), flush=True)
        if args.report:
            args.report.write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8000")
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--chunk-seconds", type=int, default=300)
    parser.add_argument("--report", type=Path)
    run(parser.parse_args())
