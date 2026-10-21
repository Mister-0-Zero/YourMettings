"""Single persistent ASR coordinator. Database transactions never span inference."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sqlalchemy import text, update
from app.core.config import settings
from app.db.audio_models import ASRWorkerState
from app.db.session import get_session_factory
from app.services.audio import claim_chunk, finish_chunk, recover_worker
from app.services.gpu import gpu_slot
from dev_launcher import StartupMutex

ROOT = Path(__file__).resolve().parents[2]
LOCK = 748139202
SCRATCH = ROOT / "backend/.runtime/asr"


class Coordinator:
    def __init__(self, factory):
        self.factory, self.generation = factory, uuid.uuid4()
        self.child, self.lock_connection = None, None
        self.status, self.last_pulse = "starting", 0
        self.messages = queue.Queue()

    def pulse(self):
        if time.monotonic() - self.last_pulse < 2:
            return
        # SQLAlchemy must not transparently reconnect a lost advisory-lock session.
        if self.lock_connection.invalidated or self.lock_connection.closed:
            raise RuntimeError("asr_database_lock_lost")
        self.lock_connection.execute(text("SELECT 1"))
        self.lock_connection.commit()
        with self.factory.begin() as db:
            changed = db.execute(update(ASRWorkerState).where(ASRWorkerState.id == 1,
                ASRWorkerState.generation == self.generation).values(status=self.status,
                    heartbeat_at=datetime.now(timezone.utc)))
            if changed.rowcount != 1:
                raise RuntimeError("asr_worker_replaced")
        self.last_pulse = time.monotonic()

    def receive(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pulse()
            try:
                item = self.messages.get(timeout=.5)
                if item is None:
                    raise RuntimeError("asr_child_stopped")
                return item
            except queue.Empty:
                if self.child.poll() is not None:
                    raise RuntimeError("asr_child_stopped")
        raise TimeoutError("asr_timeout")

    def start_child(self):
        home = settings.asr_home.resolve()
        python = home / ".venv/Scripts/python.exe"
        if not python.is_file():
            raise RuntimeError("asr_environment_missing")
        env = os.environ.copy()
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        env["YM_ASR_TEMP"] = str(SCRATCH)
        self.child = subprocess.Popen([str(python), str(ROOT / "asr/serve.py"), str(os.getpid())], cwd=home,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, text=True,
            encoding="utf-8", env=env, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        def read():
            try:
                for line in self.child.stdout:
                    try:
                        self.messages.put(json.loads(line))
                    except ValueError:
                        self.messages.put({"error": "asr_protocol_error"})
            finally:
                self.messages.put(None)
        threading.Thread(target=read, daemon=True).start()
        ready = self.receive(settings.asr_startup_timeout_seconds)
        if not ready.get("ready"):
            raise RuntimeError(ready.get("error", "asr_load_failed"))

    def run(self):
        with StartupMutex(ROOT / "asr-worker"):
            self.lock_connection = self.factory.kw["bind"].connect()
            try:
                locked = self.lock_connection.scalar(text("SELECT pg_try_advisory_lock(:key)"), {"key": LOCK})
                self.lock_connection.commit()
                if not locked:
                    raise RuntimeError("asr_worker_already_running")
                with self.factory.begin() as db:
                    recover_worker(db, self.generation, os.getpid())
                # These are disposable copies; the authoritative bytes are in PG.
                # Only our dedicated directory, only while owning singleton locks.
                if SCRATCH.resolve() != ROOT.resolve() / "backend/.runtime/asr":
                    raise RuntimeError("asr_unsafe_scratch_path")
                if SCRATCH.is_dir():
                    shutil.rmtree(SCRATCH)
                SCRATCH.mkdir(parents=True)
                with gpu_slot(self.factory, settings.asr_gpu_serial, on_wait=self.pulse):
                    self.start_child()
                self.status, self.last_pulse = "ready", 0
                self.pulse()
                print("ASR ready: v3_e2e_rnnt, CUDA, cached VAD; queue is PostgreSQL", flush=True)
                while True:
                    self.pulse()
                    with self.factory.begin() as db:
                        job = claim_chunk(db, self.generation)
                    if job is None:
                        time.sleep(.5)
                        continue
                    self.status, self.last_pulse = "busy", 0
                    try:
                        with tempfile.TemporaryDirectory(prefix=f"job-{job['session_id']}-", dir=SCRATCH) as folder:
                            source = Path(folder) / "audio.bin"
                            source.write_bytes(job.pop("payload"))
                            with gpu_slot(self.factory, settings.asr_gpu_serial, on_wait=self.pulse):
                                self.child.stdin.write(json.dumps({"path": str(source), "format": job["format"]}) + "\n")
                                self.child.stdin.flush()
                                result = self.receive(settings.asr_job_timeout_seconds)
                        with self.factory.begin() as db:
                            finish_chunk(db, job, self.generation, text=result.get("text"),
                                segments=result.get("segments"), error=result.get("error"))
                        print(json.dumps({"chunk_id": str(job["id"]), "error": result.get("error"),
                            "seconds": result.get("seconds"), "audio_seconds": result.get("audio_seconds"),
                            "peak_allocated_mib": result.get("peak_allocated_mib")}), flush=True)
                    except Exception:
                        # Leave the durable payload/claim intact for the next owner's recovery.
                        raise
                    self.status, self.last_pulse = "ready", 0
            except BaseException as exc:
                code = str(exc) if str(exc).startswith("asr_") else "asr_worker_stopped"
                try:
                    with self.factory.begin() as db:
                        db.execute(update(ASRWorkerState).where(ASRWorkerState.generation == self.generation)
                            .values(status="error", error_code=code, heartbeat_at=datetime.now(timezone.utc)))
                except Exception:
                    pass
                print("ASR stopped: " + code, flush=True)
                raise
            finally:
                # Only terminate the child created by this coordinator, never other GPU users.
                if self.child is not None:
                    self.child.stdin.close()
                    try:
                        self.child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        if os.name == "nt":
                            # venv python.exe is a redirector; terminate only our child tree.
                            subprocess.run(["taskkill.exe", "/PID", str(self.child.pid), "/T", "/F"],
                                capture_output=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
                        else:
                            self.child.kill()
                        self.child.wait(timeout=15)
                if self.lock_connection is not None:
                    try:
                        self.lock_connection.execute(text("SELECT pg_advisory_unlock(:key)"), {"key": LOCK})
                        self.lock_connection.commit()
                    except Exception:
                        pass
                    self.lock_connection.close()


if __name__ == "__main__":
    try:
        Coordinator(get_session_factory()).run()
    except BaseException as exc:
        # Driver exceptions may contain credentials. Report only a class/code.
        print("ASR worker exit: " + type(exc).__name__, flush=True)
        raise SystemExit(1)
