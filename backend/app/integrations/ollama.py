from pathlib import Path
from typing import Protocol
import json

import httpx

from app.core.config import settings


class LLMError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class SummaryGenerator(Protocol):
    def generate(self, text: str, *, options: dict | None = None) -> str: ...


DETAIL_INSTRUCTIONS = {
    "brief": "Кратко: основные решения и задачи; минимум второстепенных подробностей.",
    "normal": "Стандартно: основные обсуждения, решения, задачи, ответственные и сроки.",
    "detailed": "Подробно: сохрани существенный контекст, аргументацию и детали обсуждения.",
}
FOCUS_INSTRUCTIONS = {
    "tasks": "задачи и поручения", "owners": "ответственные", "deadlines": "сроки",
    "decisions": "принятые решения", "risks": "риски и проблемы",
    "disagreements": "разногласия и открытые вопросы",
}


def build_prompt(options):
    prompt = (Path(__file__).resolve().parents[1] / "prompts" / "summary.txt").read_text(encoding="utf-8")
    prompt += "\nДетализация: " + DETAIL_INSTRUCTIONS[options.get("detail_level", "normal")]
    focuses = options.get("focus_areas", [])
    if focuses:
        prompt += "\nОсобое внимание: " + "; ".join(FOCUS_INSTRUCTIONS[x] for x in focuses) + "."
    return prompt


class OllamaGenerator:
    def __init__(self, base_url: str, model: str, timeout: float, transport=None):
        self.base_url = base_url
        self.model = model
        self.timeout = timeout
        self.transport = transport

    def generate(self, text: str, *, options: dict | None = None) -> str:
        options = options or {}
        prompt = build_prompt(options)
        data = json.dumps({"transcript": text,
            "additional_instructions": options.get("additional_instructions", "")}, ensure_ascii=False)
        try:
            with httpx.Client(base_url=self.base_url, timeout=self.timeout, transport=self.transport) as client:
                response = client.post("/api/chat", json={
                    "model": self.model, "stream": False,
                    "messages": [{"role": "system", "content": prompt}, {"role": "user", "content": data}],
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
