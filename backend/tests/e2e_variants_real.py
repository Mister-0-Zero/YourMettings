"""Opt-in: process each full built-in long meeting with local Qwen, no application records."""
import argparse
import hashlib
import json
import re
import sys
import time
from copy import deepcopy
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import httpx

from app.core.config import settings
from app.db.session import get_session_factory
from app.integrations.ollama import get_generator
from app.services.gpu import gpu_slot
from app.services.long_generation import generate_long
from app.services.template_catalog import SYSTEM_TEMPLATES
from app.services.template_rendering import navigation

CASES = {
    "team-standup": ["Приём заявок", "Наталь", "92000", "5 ноября", "11:30", "16:00"],
    "work-report": ["288000", "Сергей Белов", "6 ноября", "15:00", "95000"],
    "engagement-ideas": ["48000", "Тимур", "14 декабря", "12:00", "17 ноября", "18:30"],
    "team-standup-stress": ["Приём заявок", "Наталь", "92000", "5 ноября", "11:30", "16:00"],
}


def normalized(text):
    return re.sub(r"(?<=\d)[ \u00a0\u202f]+(?=\d)", "", text).lower()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mobile-examples", type=Path, help="Read-only directory with Flutter catalog.json and its synthetic .txt assets")
    args = parser.parse_args()
    results_dir = Path(__file__).resolve().parents[2] / "docs" / "examples" / "variants"
    results_dir.mkdir(exist_ok=True)
    cases = CASES
    if args.mobile_examples:
        results_dir = results_dir / "flutter"
        results_dir.mkdir(exist_ok=True)
        cases = {
            "weekly_planning": ["Павел", "Марина", "5 ноября", "30 октября"],
            "manager_report": ["Светлана", "Николай", ["90000", "девяносто тысяч"], "3 ноября"],
            "employee_engagement": ["Анна", "Роман", ["45000", "сорока пяти тысяч", "сорок пять тысяч"], "12 ноября", "3 декабря", "7 декабря"],
        }
        catalog = {item["id"]: item for item in json.loads((args.mobile_examples / "catalog.json").read_text(encoding="utf-8"))}
    results = []
    for slug, markers in cases.items():
        source_file = "team-standup" if slug.endswith("-stress") else slug
        source_path = args.mobile_examples / (slug+".txt") if args.mobile_examples else Path(__file__).resolve().parents[1] / "app/examples" / (source_file+".txt")
        source = source_path.read_text(encoding="utf-8")
        source_sha256 = hashlib.sha256(source.encode()).hexdigest()
        if args.mobile_examples:
            expected = catalog[slug]
            assert source_sha256 == expected["sha256"]
            # Catalog and backend count punctuation-only tokens differently;
            # byte identity is established by SHA-256, not by word-count equality.
            assert 5000 <= len(source.split()) <= 15000
            assert len(source) == expected["character_count"]
        if slug.endswith("-stress"):
            source = source * 2
        options = {"detail_level": "normal", "focus_areas": [], "additional_instructions": "",
            "template_snapshot": deepcopy(SYSTEM_TEMPLATES[0])}
        mapped_segments, final_sources, call_usage = [], [], []
        class Recorder(httpx.HTTPTransport):
            def handle_request(self, request):
                if request.url.path == "/api/chat":
                    body = json.loads(request.content)
                    data = json.loads(body["messages"][1]["content"])
                    if "source_segment" in data:
                        mapped_segments.append(data["source_segment"])
                    if "transcript" in data:
                        final_sources.append(data["transcript"])
                    output_limit = body["options"].get("num_predict")
                response = super().handle_request(request)
                response.read()
                if request.url.path == "/api/chat" and response.status_code == 200:
                    body = response.json()
                    call_usage.append({**{k: body.get(k) for k in ("prompt_eval_count", "eval_count", "done_reason")},
                        "output_limit_tokens": output_limit, "content_chars": len(body.get("message",{}).get("content", "")),
                        "thinking_chars": len(body.get("message",{}).get("thinking", ""))})
                return response
        transport = Recorder()
        generator = get_generator()
        generator.transport = transport
        started = time.monotonic()
        def progress(info):
            print(json.dumps({"case": slug, "stage": info["stage"], "map_calls": info["map_calls"],
                "reduce_calls": info["reduce_calls"], "seconds": round(time.monotonic()-started, 1)}), flush=True)
        try:
            with gpu_slot(get_session_factory(), enabled=settings.asr_gpu_serial):
                content, metadata = generate_long(generator, source, options=options, on_progress=progress)
        except Exception as exc:
            results.append({"case": slug, "error": getattr(exc, "code", type(exc).__name__),
                "source_words": len(source.split()), "seconds": round(time.monotonic()-started, 2), "calls": call_usage})
            (results_dir/"validation.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
            raise
        finally:
            transport.close()
        missing = [m for m in markers if not any(normalized(v) in normalized(content) for v in (m if isinstance(m, list) else [m]))]
        full_source_used = "".join(mapped_segments) == source if metadata["strategy"] == "hierarchical" else final_sources == [source]
        record = {"case": slug, "model": settings.ollama_model, "seconds": round(time.monotonic()-started, 2),
            "full_source_used": full_source_used, "source_sha256": source_sha256, "missing_markers": missing, "markers": markers,
            "metadata": metadata, "calls": call_usage,
            "runtime_budgets_fit": all(u["prompt_eval_count"] + u["output_limit_tokens"] <= metadata["context_length"] for u in call_usage),
            "topics": [h["title"] for h in navigation(content) if h["level"] == 3]}
        (results_dir/(slug+".md")).write_text(content+"\n", encoding="utf-8")
        results.append(record)
        (results_dir/"validation.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(record, ensure_ascii=False), flush=True)
        if not full_source_used or missing or not record["runtime_budgets_fit"]:
            raise SystemExit("Full-input/coverage check failed; inspect output before accepting")


if __name__ == "__main__":
    main()
