from pathlib import Path
from typing import Protocol

import httpx

from app.core.config import settings


class LLMError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class SummaryGenerator(Protocol):
    def generate(self, text: str) -> str: ...


class OllamaGenerator:
    def __init__(self, base_url: str, model: str, timeout: float, transport=None):
        self.base_url = base_url
        self.model = model
        self.timeout = timeout
        self.transport = transport

    def generate(self, text: str) -> str:
        prompt = (Path(__file__).resolve().parents[1] / "prompts" / "summary.txt").read_text(encoding="utf-8")
        try:
            with httpx.Client(base_url=self.base_url, timeout=self.timeout, transport=self.transport) as client:
                response = client.post("/api/chat", json={
                    "model": self.model, "stream": False,
                    "messages": [{"role": "system", "content": prompt}, {"role": "user", "content": text}],
                    "options": {"temperature": 0.2},
                })
                response.raise_for_status()
        except httpx.TimeoutException as exc:
            raise LLMError("llm_timeout") from exc
        except httpx.HTTPError as exc:
            raise LLMError("llm_unavailable") from exc
        try:
            body = response.json()
            result = body["message"]["content"]
            if body.get("done") is not True or not isinstance(result, str) or not result.strip():
                raise ValueError("Missing completed content")
        except (ValueError, KeyError, TypeError) as exc:
            raise LLMError("llm_invalid_response") from exc
        return result.strip()


def get_generator() -> SummaryGenerator:
    return OllamaGenerator(settings.ollama_base_url, settings.ollama_model, settings.llm_timeout_seconds)
