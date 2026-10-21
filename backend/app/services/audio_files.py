"""Only disposable, session-namespaced ASR copies; never models or global TEMP."""
from pathlib import Path
import shutil

from app.core.config import BACKEND_ROOT

ASR_SCRATCH = BACKEND_ROOT / ".runtime/asr"


def cleanup_session_files(session_id, *, root=None):
    root = ASR_SCRATCH if root is None else Path(root)
    expected = root.absolute()
    if root.resolve() != expected:
        raise OSError("Unsafe ASR scratch root")
    if not root.exists():
        return
    prefix = f"job-{session_id}-"
    # Only completed jobs of this session. Each candidate must stay inside root.
    for candidate in root.glob(prefix + "*"):
        if candidate.resolve() != candidate.absolute() or candidate.resolve().parent != expected or candidate.is_symlink():
            raise OSError("Unsafe ASR copy path")
        if not candidate.is_dir():
            raise OSError("Unexpected ASR copy type")
        shutil.rmtree(candidate)
