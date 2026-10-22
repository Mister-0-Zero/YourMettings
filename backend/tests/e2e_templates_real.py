"""Opt-in local Qwen check using synthetic text; never creates application records.

Run from backend: .venv/Scripts/python tests/e2e_templates_real.py
"""
import json
import sys
import time
import httpx
from copy import deepcopy
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.config import settings
from app.db.session import get_session_factory
from app.integrations.ollama import get_generator
from app.services.gpu import gpu_slot
from app.services.template_catalog import SYSTEM_TEMPLATES
from app.services.template_rendering import navigation

SOURCE = """23 октября 2026 года. Совещание проекта Север. Участвуют Анна, Борис и Ирина.
Анна: сначала обсудим выпуск API. Наша цель — подготовить версию 2.4 без потери совместимости.
Борис: миграция индекса PostgreSQL готова, но тест отката ещё не выполнен. Предлагаю выпустить всё сегодня.
Анна: сегодня выпускать не будем. Решили выпускать 30 октября, только после успешного теста отката.
Борис: беру на себя тест отката к 28 октября. Зафиксируем это как мою задачу.
Ирина: вторая тема — обучение операторов. Нужно проверить инструкцию на новичках. Я подготовлю инструкцию к 29 октября.
Анна: согласовано. Для обучения согласовали две группы по 8 человек. Платный курс пока только предложение, его не покупаем.
Борис: вернусь к API: лимит запросов оставляем 120 в минуту. 200 — только вариант для будущего, решения по нему нет.
Анна: верно, приняли лимит 120 в минуту. Вопрос нагрузки 200 оставляем открытым.
Ирина: третья тема — архив. Есть риск потери файлов при переносе. Предлагаю удалять старые файлы через неделю.
Анна: предложение об удалении не принято. Сначала делаем резервную копию. Борис, подготовь план резервирования к 31 октября.
Борис: согласен, план подготовлю. Срок самого переноса ещё не определён.
Анна: завершающая отдельная тема — доступ подрядчика. Решено выдать только чтение для стенда Ладога-7.
Ирина: я оформлю доступ к 2 ноября. Производственный доступ не согласовали, он остаётся закрыт.
"""


def long_source():
    # Repeated substantive reviews simulate an extended meeting; late decisions revise early proposals.
    rounds = []
    for i in range(1, 19):
        rounds.append(f"""Раунд проверки {i}.
Борис: по API обсуждаем воспроизводимость теста отката. Проверяем схему до и после миграции,
сравниваем количество записей и доступность индекса. Вариант немедленного выпуска был предложением,
но принятым условием остаётся успешная проверка отката. Значение 120 запросов в минуту сохраняется;
повышение до 200 нужно отдельно проверить, согласования повышения пока нет.
Ирина: для инструкции операторов нужны примеры штатной работы и ошибки соединения. Покажем порядок
повторного запроса и проверки результата. Группы остаются по 8 человек. Платный курс — альтернатива,
закупку не подтверждали. Содержание инструкции проверим на новичках, не меняя согласованный срок.
Анна: по архиву основной риск — потеря файлов при переносе. План должен описать проверку копии
и возможность восстановления. Пока проверка не завершена, исходные файлы сохраняем. Предложение
автоматически удалять их через неделю не утверждали. Сам перенос ещё не назначен.
Борис: замечания к плану понятны. Обсуждения одной темы в разных раундах нужно свести вместе,
а не создавать новый проект или новую задачу на каждый повтор. Новых сроков в этом раунде не назначаем.
""")
    return SOURCE + "\n".join(rounds) + """
Окончательное уточнение после всех раундов, отдельная новая тема — сервер Вектор-93.
Анна: приняли бюджет сервера 475000 рублей. До этого сумму не обсуждали.
Ирина: беру на себя заявку на Вектор-93 к 12 ноября. Это окончательное решение встречи.
Борис: ещё исправление по API: выпуск переносим с 30 октября на 3 ноября. Тест отката остаётся 28 октября.
Анна: перенос выпуска на 3 ноября согласован. Остальные сроки сохраняем. Встреча завершена.
"""


def run():
    target = Path(__file__).resolve().parents[2] / "docs" / "examples"
    target.mkdir(exist_ok=True)
    results = []
    for label, text, markers in [
        ("universal", SOURCE, ["120", "28", "29", "Ладога", "2 ноября"]),
        ("long", long_source(), ["Вектор-93", "475000", "12 ноября", "3 ноября", "120"]),
    ]:
        options = {"detail_level": "normal", "template_snapshot": deepcopy(SYSTEM_TEMPLATES[0])}
        usage = {}
        class RecordingTransport(httpx.HTTPTransport):
            def handle_request(self, request):
                response = super().handle_request(request)
                response.read()
                if response.status_code == 200:
                    body = response.json()
                    usage.update({k: body.get(k) for k in ("prompt_eval_count", "eval_count", "done_reason")})
                return response
        generator = get_generator()
        transport = RecordingTransport()
        generator.transport = transport
        start = time.monotonic()
        with gpu_slot(get_session_factory(), enabled=settings.asr_gpu_serial):
            result = generator.generate(text, options=options)
        transport.close()
        missing = [m for m in markers if m not in result.replace("475 000", "475000")]
        record = {"case": label, "source_chars": len(text), "result_chars": len(result),
            "seconds": round(time.monotonic() - start, 2), "missing_markers": missing, "model": settings.ollama_model, "usage": usage,
            "top_level_headings": [h["title"] for h in navigation(result) if h["level"] == 2],
            "topics": [h["title"] for h in navigation(result) if h["level"] == 3]}
        (target / f"template_{label}_source.txt").write_text(text, encoding="utf-8")
        (target / f"template_{label}_result.md").write_text(result + "\n", encoding="utf-8")
        results.append(record)
        print(json.dumps(record, ensure_ascii=False), flush=True)
    (target / "template_validation.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    if any(r["missing_markers"] for r in results):
        raise SystemExit("Coverage markers missing; inspect generated example before accepting")


if __name__ == "__main__":
    run()
