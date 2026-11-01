"""Only disposable, session-namespaced ASR copies; never models or global TEMP."""
from contextlib import contextmanager
import hashlib
from pathlib import Path
from sqlalchemy import text
import shutil

from app.core.config import BACKEND_ROOT

ASR_SCRATCH = BACKEND_ROOT / ".runtime/asr"


def asr_file_lock_key(session_id):
    return int.from_bytes(hashlib.sha256(f"ym-asr-files:{session_id}".encode()).digest()[:8], "big", signed=True)


@contextmanager
def guard_asr_files(factory, session_id):
    """Session lock, not a transaction: ASR can block without pinning a snapshot."""
    connection = factory.kw["bind"].connect()
    key = asr_file_lock_key(session_id)
    try:
        connection.execute(text("SELECT pg_advisory_lock_shared(:key)"), {"key": key})
        connection.commit()
        yield
    finally:
        try:
            connection.execute(text("SELECT pg_advisory_unlock_shared(:key)"), {"key": key})
            connection.commit()
        except Exception:
            connection.invalidate()
            raise
        finally:
            connection.close()


def cleanup_session_files(session_id, *, root=None):
    root = ASR_SCRATCH if root is None else Path(root)
    expected = root.absolute()
    if root.resolve() != expected:
        raise OSError("Unsafe ASR scratch root")
    if not root.exists():
        return
    prefix = f"job-{session_id}-"
    # Caller holds the exclusive file guard. Each candidate must stay inside root.
    for candidate in root.glob(prefix + "*"):
        if candidate.resolve() != candidate.absolute() or candidate.resolve().parent != expected or candidate.is_symlink():
            raise OSError("Unsafe ASR copy path")
        if not candidate.is_dir():
            raise OSError("Unexpected ASR copy type")
        shutil.rmtree(candidate)
