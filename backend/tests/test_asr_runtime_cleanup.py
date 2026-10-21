"""Exercise the real JSON protocol and filesystem, using a fake ML model."""
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

import pytest

from app.core.config import settings
from test_audio import wav_bytes


@pytest.mark.parametrize("cleanup_fails", [False, True])
def test_result_is_not_published_before_decoder_cleanup(tmp_path, cleanup_fails):
    ffmpeg = settings.asr_home / "tools/ffmpeg-shared/bin/ffmpeg.exe"
    if not ffmpeg.is_file():
        pytest.skip("Local FFmpeg required for runtime cleanup protocol test")
    home = tmp_path / "home"
    (home / "models").mkdir(parents=True)
    for name in ("v3_e2e_rnnt.ckpt", "v3_e2e_rnnt_tokenizer.model"):
        (home / "models" / name).touch()
    job = tmp_path / "job"
    job.mkdir()
    (job / "audio.wav").write_bytes(wav_bytes())
    asr = Path(__file__).resolve().parents[2] / "asr"
    bootstrap = r'''
import os, sys, time, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import serve
home, job, ffmpeg, fails = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5] == 'true'
os.chdir(home)
os.environ['YM_ASR_TEMP'] = str(job)
serve.watch_parent = lambda pid: None
serve.load_saved_token = lambda: None
serve.configure_ffmpeg = lambda home: ffmpeg
noop = lambda: None
torch = types.ModuleType('torch')
torch.device = lambda device: device
torch.cuda = types.SimpleNamespace(is_available=lambda: True, synchronize=noop,
    reset_peak_memory_stats=noop, max_memory_allocated=lambda: 0)
gigaam = types.ModuleType('gigaam')
gigaam.load_model = lambda *a, **k: types.SimpleNamespace(transcribe=lambda wav: types.SimpleNamespace(text='Test text'))
vad = types.ModuleType('gigaam.vad_utils')
vad.get_pipeline = lambda device: None
sys.modules.update({'torch': torch, 'gigaam': gigaam, 'gigaam.vad_utils': vad})
original_temp = serve.tempfile.TemporaryDirectory
class HeldCleanup:
    def __init__(self, *a, **k):
        self.original = original_temp(*a, **k)
    def __enter__(self):
        return self.original.__enter__()
    def __exit__(self, *args):
        (job / 'cleanup_entered').touch()
        deadline = time.monotonic() + 10
        while not (job / 'allow_cleanup').exists():
            if time.monotonic() > deadline:
                raise RuntimeError('test cleanup barrier timeout')
            time.sleep(.01)
        if fails:
            raise PermissionError('injected decoder cleanup failure')
        return self.original.__exit__(*args)
serve.tempfile.TemporaryDirectory = HeldCleanup
sys.argv = [sys.argv[0], str(os.getpid())]
raise SystemExit(serve.main())
'''
    process = subprocess.Popen([sys._base_executable, "-u", "-c", bootstrap, str(asr), str(home), str(job),
        str(ffmpeg), str(cleanup_fails).lower()], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, encoding="utf-8", creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    lines = queue.Queue()
    def read():
        for line in process.stdout:
            lines.put(json.loads(line))
    threading.Thread(target=read, daemon=True).start()
    try:
        assert lines.get(timeout=10)["ready"] is True
        process.stdin.write(json.dumps({"path": str(job / "audio.wav"), "format": "wav"}) + "\n")
        process.stdin.flush()
        deadline = time.monotonic() + 10
        while not (job / "cleanup_entered").exists():
            assert process.poll() is None
            assert time.monotonic() < deadline
            time.sleep(.01)
        with pytest.raises(queue.Empty):
            lines.get(timeout=.2)  # No success can escape while cleanup is blocked.
        (job / "allow_cleanup").touch()
        result = lines.get(timeout=10)
        if cleanup_fails:
            assert result == {"error": "asr_transcription_failed"}
        else:
            assert result["text"] == "Test text"
            assert list(job.glob("decode-*")) == []
        process.stdin.close()
        assert process.wait(timeout=10) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
