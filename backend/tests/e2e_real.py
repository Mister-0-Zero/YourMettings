"""Opt-in real HTTP + PostgreSQL + configured Ollama smoke test.

Usage: python tests/e2e_real.py http://192.168.1.100:8000
Creates a small labelled transcript and folder in the development DB;
deletes only its own test summary, transcript and folders at the end.
"""
import sys
import re
import time
import uuid

import httpx


def checked(response, status):
    if response.status_code != status:
        raise RuntimeError(f"HTTP {response.status_code}, expected {status}: {response.text[:300]}")
    return response.json() if status != 204 else None


def run(base):
    with httpx.Client(base_url=base, timeout=20, trust_env=False) as client:
        checked(client.get("/health"), 200)
        prefix = "/api/v1"
        folder = checked(client.post(f"{prefix}/folders", json={"name": "E2E smoke"}), 201)
        source = "Анна: Решили выпустить версию в пятницу. Сергей: Я подготовлю тесты до четверга. Анна: Вопрос бюджета пока не решён."
        key = f"e2e-{uuid.uuid4()}"
        body = {"text": source, "title": "E2E smoke", "folder_ids": [folder["id"]],
            "detail_level": "detailed", "focus_areas": ["tasks", "owners", "deadlines", "decisions", "risks", "disagreements"],
            "additional_instructions": "Сохрани явно названных ответственных и сроки."}
        accepted = checked(client.post(f"{prefix}/transcripts/process", json=body, headers={"Idempotency-Key": key}), 202)
        tid = accepted["transcript_id"]
        repeat = checked(client.post(f"{prefix}/transcripts/process", json=body, headers={"Idempotency-Key": key}), 202)
        assert repeat["transcript_id"] == tid
        deadline = time.monotonic() + 360
        while time.monotonic() < deadline:
            state = checked(client.get(f"{prefix}/transcripts/{tid}/processing"), 200)
            if state["status"] == "ready":
                break
            if state["status"] == "error":
                raise RuntimeError(f"Processing failed: {state['error']}")
            time.sleep(2)
        else:
            raise RuntimeError("Polling deadline exceeded")
        sid = state["summary_id"]
        result = checked(client.get(f"{prefix}/summaries/{sid}"), 200)
        assert result["content"].strip() and result["folder_ids"] == [folder["id"]]
        assert not any(re.match(r"^\s*\|?\s*:?-+\s*\|", line) for line in result["content"].splitlines()), "Model returned a Markdown table"
        print("Real model summary:", result["content"])
        checked(client.patch(f"{prefix}/summaries/{sid}", json={"title": "E2E edited", "content": "Проверенная ручная правка"}), 200)
        assert checked(client.get(f"{prefix}/summaries", params={"folder_id": folder["id"]}), 200)["total"] == 1
        checked(client.delete(f'{prefix}/folders/{folder["id"]}', params={"mode": "with_contents", "confirm": True}), 204)
        checked(client.get(f"{prefix}/summaries/{sid}"), 404)
        checked(client.get(f"{prefix}/transcripts/{tid}"), 404)
        empty = checked(client.post(f"{prefix}/folders", json={"name": "E2E empty"}), 201)
        checked(client.delete(f'{prefix}/folders/{empty["id"]}', params={"mode": "with_contents", "confirm": True}), 204)
        print("PASS: configured preferences -> mobile Markdown -> folder/content deletion -> transcript cleanup.")


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000")
