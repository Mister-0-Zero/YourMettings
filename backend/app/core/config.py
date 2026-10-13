from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_ROOT / ".env", env_file_encoding="utf-8", extra="ignore"
    )
    database_url: str = ""
    test_database_url: str = ""
    ollama_base_url: str = "http://127.0.0.1:11434"
    ollama_model: str = ""
    llm_timeout_seconds: float = 300
    max_transcript_chars: int = 100_000


settings = Settings()
