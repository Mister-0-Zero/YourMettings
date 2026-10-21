"""Validate actual decoder output with bounded time, bytes and duration."""
from pathlib import Path
import subprocess
import tempfile
import wave

from app.api.errors import fail
from app.core.config import settings


def ffmpeg_path():
    path = settings.asr_home / "tools/ffmpeg-shared/bin/ffmpeg.exe"
    if not path.is_file():
        path = settings.asr_home / "tools/ffmpeg.exe"
    if not path.is_file():
        fail(503, "asr_not_configured", "Не найден локальный FFmpeg в ASR_HOME/tools.")
    return path


def identify(data):
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE": return "wav"
    if data[4:8] == b"ftyp": return "mov"
    if data[:4] == b"fLaC": return "flac"
    if data[:4] == b"OggS": return "ogg"
    if len(data) > 2 and data[0] == 255 and data[1] & 0xF6 == 0xF0: return "aac"
    if data[:3] == b"ID3" or len(data) > 2 and data[0] == 255 and data[1] & 0xE0 == 0xE0: return "mp3"
    fail(422, "invalid_audio", "Неизвестный контейнер аудио. Используйте M4A/AAC, WAV, MP3, FLAC или Ogg.")


def validate_audio(data):
    fmt = identify(data)
    with tempfile.TemporaryDirectory(prefix="yourmettings-validate-") as directory:
        source, output = Path(directory) / "input.bin", Path(directory) / "decoded.wav"
        source.write_bytes(data)
        command = [str(ffmpeg_path()), "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-f", fmt]
        if fmt == "mov":
            command += ["-enable_drefs", "0", "-use_absolute_path", "0"]
        command += ["-i", str(source), "-map", "0:a:0", "-t", str(settings.audio_chunk_max_seconds + 1),
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(output)]
        try:
            result = subprocess.run(command, capture_output=True, timeout=settings.audio_validation_timeout_seconds,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if result.returncode:
                fail(422, "invalid_audio", "Аудио повреждено или не содержит поддерживаемой дорожки.")
            with wave.open(str(output), "rb") as audio:
                duration = round(audio.getnframes() * 1000 / audio.getframerate())
        except subprocess.TimeoutExpired:
            fail(422, "audio_validation_timeout", "Не удалось проверить аудио за отведённое время.")
        except (wave.Error, EOFError, OSError):
            fail(422, "invalid_audio", "Не удалось декодировать аудио.")
    if duration <= 0:
        fail(422, "invalid_audio", "Аудиофрагмент пуст.")
    if duration > settings.audio_chunk_max_seconds * 1000:
        fail(413, "audio_too_long", "Длительность фрагмента превышает лимит.")
    return fmt, duration
