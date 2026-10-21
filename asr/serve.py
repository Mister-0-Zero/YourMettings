"""Private JSON-lines child of the backend coordinator, using the ASR venv."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import wave
import threading

from transcribe import configure_ffmpeg, load_saved_token


def watch_parent(pid):
    """Release CUDA even if Windows kills the coordinator without running finally."""
    if os.name != "nt":
        return
    import ctypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_bool, ctypes.c_uint32]
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.OpenProcess(0x100000, False, pid)  # SYNCHRONIZE, no termination rights.
    if not handle:
        raise RuntimeError("asr_parent_unavailable")
    def watch():
        kernel.WaitForSingleObject(handle, 0xFFFFFFFF)
        kernel.CloseHandle(handle)
        os._exit(1)
    threading.Thread(target=watch, daemon=True).start()


def main():
    watch_parent(int(sys.argv[1]))
    # Keep protocol output separate even from native libraries printing to fd 1.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    def send(message):
        protocol.write(json.dumps(message, ensure_ascii=False) + "\n")
        protocol.flush()
    home = Path.cwd()
    for name in ("v3_e2e_rnnt.ckpt", "v3_e2e_rnnt_tokenizer.model"):
        if not (home / "models" / name).is_file():
            send({"error": "asr_model_missing"})
            return 1
    os.environ["HF_HOME"] = str(home / ".cache/huggingface")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
    load_saved_token()
    try:
        ffmpeg = configure_ffmpeg(home)
        import torch
        import gigaam
        from gigaam.vad_utils import get_pipeline
        if not torch.cuda.is_available():
            send({"error": "asr_cuda_unavailable"})
            return 1
        model = gigaam.load_model("v3_e2e_rnnt", device="cuda", download_root="models", use_flash=False)
        get_pipeline(torch.device("cuda"))
        torch.cuda.synchronize()
        send({"ready": True, "model": "v3_e2e_rnnt"})
    except Exception as exc:
        send({"error": "asr_gpu_memory" if "out of memory" in str(exc).lower() else "asr_load_failed"})
        return 1
    for line in sys.stdin:
        try:
            job = json.loads(line)
            started = time.monotonic()
            with tempfile.TemporaryDirectory(prefix="decode-", dir=Path(job["path"]).parent) as folder:
                wav = Path(folder) / "input.wav"
                decoded = subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe",
                    "-f", job["format"], "-i", job["path"], "-map", "0:a:0", "-ac", "1", "-ar", "16000",
                    "-c:a", "pcm_s16le", str(wav)], capture_output=True, timeout=30)
                if decoded.returncode:
                    raise ValueError("decode")
                with wave.open(str(wav), "rb") as audio:
                    duration = audio.getnframes() / audio.getframerate()
                torch.cuda.reset_peak_memory_stats()
                result = (model.transcribe_longform(str(wav), fr_batch_size=1)
                    if duration > 25 else model.transcribe(str(wav)))
                torch.cuda.synchronize()
                segments = ([{"start": s.start, "end": s.end, "text": s.text} for s in result]
                    if duration > 25 else [{"start": 0, "end": duration, "text": result.text}])
                message = {"text": result.text, "segments": segments, "seconds": round(time.monotonic()-started, 3),
                    "audio_seconds": duration, "peak_allocated_mib": round(torch.cuda.max_memory_allocated()/2**20, 1)}
            # A result is publishable only after decoder scratch has been removed.
            send(message)
        except Exception as exc:
            send({"error": "asr_gpu_memory" if "out of memory" in str(exc).lower() else "asr_transcription_failed"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
