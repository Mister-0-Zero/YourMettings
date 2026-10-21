from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field

BACKEND_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_ROOT / ".env", env_file_encoding="utf-8", extra="ignore"
    )
    database_url: str = ""
    test_database_url: str = ""
    ollama_base_url: str = "http://127.0.0.1:11434"
    ollama_model: str = ""
    llm_timeout_seconds: float = Field(300, gt=0)
    max_transcript_chars: int = Field(100_000, gt=0)
    asr_home: Path = BACKEND_ROOT.parent / "asr"
    asr_enabled: bool = True
    asr_gpu_serial: bool = True
    asr_startup_timeout_seconds: int = Field(180, ge=10)
    asr_job_timeout_seconds: int = Field(600, ge=10)
    audio_chunk_target_seconds: int = Field(300, ge=1)
    audio_chunk_max_seconds: int = Field(360, ge=1)
    audio_max_upload_bytes: int = Field(32 * 1024 * 1024, ge=1024)
    audio_max_chunks: int = Field(240, ge=1, le=240)
    audio_max_overlap_ms: int = Field(3000, ge=0, le=10000)
    audio_validation_timeout_seconds: int = Field(30, ge=1)


settings = Settings()
