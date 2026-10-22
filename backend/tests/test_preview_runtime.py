"""Preview deadline includes waiting for the shared GPU, not only HTTP time."""
import time
from uuid import uuid4

from sqlalchemy import text

from app.api import template_previews as previews
from app.core.config import settings
from app.services.gpu import GPU_LOCK


def test_preview_waiting_for_gpu_expires_without_calling_model(database, monkeypatch):
    monkeypatch.setattr(settings, "asr_gpu_serial", True)
    id = uuid4()
    class NeverCalled:
        def generate(self, *args, **kwargs):
            raise AssertionError("Preview must expire while waiting for the GPU")
    with previews._lock:
        previews._jobs[id] = {"status": "queued", "active": True, "deadline": time.monotonic() + 0.05}
    engine = database.kw["bind"]
    try:
        with engine.connect() as occupied:
            occupied.execute(text("SELECT pg_advisory_lock(:key)"), {"key": GPU_LOCK})
            occupied.commit()
            try:
                previews.run_preview(database, id, "Temporary test", {}, NeverCalled())
            finally:
                occupied.execute(text("SELECT pg_advisory_unlock(:key)"), {"key": GPU_LOCK})
                occupied.commit()
        assert previews._jobs[id]["status"] == "error"
        assert previews._jobs[id]["error"]["code"] == "llm_timeout"
        assert previews._jobs[id]["active"] is False
    finally:
        previews._jobs.pop(id, None)
