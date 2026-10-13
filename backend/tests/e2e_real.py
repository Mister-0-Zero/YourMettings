"""Opt-in real HTTP + PostgreSQL + configured Ollama smoke test.

Usage: python tests/e2e_real.py http://192.168.1.100:8000
Creates a small labelled transcript and folder in the development DB;
deletes its summary at the end. Transcript and folder intentionally remain.
"""
import sys
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
        transcript = checked(client.post(f"{prefix}/transcripts", json={"text": source}, headers={"Idempotency-Key": key}), 201)
        tid = transcript["id"]
        repeat = checked(client.post(f"{prefix}/transcripts", json={"text": source}, headers={"Idempotency-Key": key}), 200)
        assert repeat["id"] == tid
        checked(client.post(f"{prefix}/transcripts/{tid}/process", json={"title": "E2E smoke", "folder_ids": [folder["id"]]}), 202)
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
        print("Real model summary:", result["content"])
        checked(client.patch(f"{prefix}/summaries/{sid}", json={"title": "E2E edited", "content": "Проверенная ручная правка"}), 200)
        assert checked(client.get(f"{prefix}/summaries", params={"folder_id": folder["id"]}), 200)["total"] == 1
        checked(client.delete(f"{prefix}/summaries/{sid}"), 204)
        remaining = checked(client.get(f"{prefix}/transcripts/{tid}"), 200)
        assert remaining["text"] == source and remaining["is_locked"] is True
        checked(client.patch(f"{prefix}/transcripts/{tid}", json={"text": "edit"}), 409)
        print("PASS: real HTTP -> PostgreSQL -> Ollama -> summary -> edit -> delete; transcript remains locked.")


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000")
