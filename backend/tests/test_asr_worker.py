import os
from pathlib import Path
import subprocess
import sys

import pytest


@pytest.mark.skipif(os.name != "nt", reason="Windows ASR parent watchdog")
def test_ml_child_exits_after_its_coordinator_is_killed():
    """No ML/GPU: exercise the actual watchdog with two disposable owned processes."""
    root = Path(__file__).resolve().parents[2]
    python = sys._base_executable  # Direct interpreter, no Windows venv redirector.
    parent = subprocess.Popen([python, "-c", "import time; time.sleep(30)"],
        creationflags=subprocess.CREATE_NO_WINDOW)
    child = None
    try:
        code = "import sys,time; sys.path.insert(0,sys.argv[1]); from serve import watch_parent; watch_parent(int(sys.argv[2])); print('ready',flush=True); time.sleep(30)"
        child = subprocess.Popen([python, "-u", "-c", code, str(root / "asr"), str(parent.pid)],
            stdout=subprocess.PIPE, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
        import queue
        import threading
        messages = queue.Queue()
        threading.Thread(target=lambda: messages.put(child.stdout.readline()), daemon=True).start()
        assert messages.get(timeout=5).strip() == "ready"
        parent.kill()
        parent.wait(timeout=5)
        assert child.wait(timeout=5) == 1
    finally:
        for process in (child, parent):
            if process and process.poll() is None:
                process.kill()
                process.wait(timeout=5)
