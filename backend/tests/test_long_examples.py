"""Offline integrity checks for the full synthetic template-preview inputs.

These checks validate the shipped corpus, not LLM summarization. In particular,
the later corrections are oracle facts for separate live full-input checks.
"""

from hashlib import sha256
from pathlib import Path

import pytest


EXAMPLES_DIR = Path(__file__).resolve().parents[1] / "app" / "examples"
CASES = (
    (
        "team-standup.txt",
        "Планёрка команды",
        "Исходный общий резерв на небольшие закупки составляет 100 000 рублей",
        "владельцем переезда справочника становится Наталья",
        "демонстрация 5 ноября в 11:30, склад проверяем 30 октября в 16:00, "
        "справочник ведёт Наталья, общий закупочный резерв 92 000 рублей",
    ),
    (
        "work-report.txt",
        "Отчёт руководителю о проделанной работе",
        "подтверждённые платежи на утро — 312 000 рублей",
        "Фактические платежи за период составляют 288 000 рублей, а не 312 000",
        "переносим подписание с 30 октября на 6 ноября к 15:00. "
        "Подписант со стороны направления — Сергей Белов",
    ),
    (
        "engagement-ideas.txt",
        "Идеи для повышения вовлечённости сотрудников",
        "шестинедельный пилот с общим пределом расходов 60 000 рублей",
        "уменьшаем общий предел пилота с 60 000 до 48 000 рублей",
        "обзор обсуждаем 14 декабря в 12:00. Владельцем обзора назначаем Тимура",
    ),
)


def test_exactly_three_distinct_long_example_files():
    expected = {case[0] for case in CASES}
    assert {path.name for path in EXAMPLES_DIR.glob("*.txt")} == expected
    digests = {sha256((EXAMPLES_DIR / name).read_bytes()).digest() for name in expected}
    assert len(digests) == 3, "Each meeting must have its own complete corpus"


@pytest.mark.parametrize("filename,title,start,middle,tail", CASES)
def test_full_example_word_and_transport_bounds(filename, title, start, middle, tail):
    source = (EXAMPLES_DIR / filename).read_bytes()
    text = source.decode("utf-8")

    # The product requirement is words, using whitespace splitting, not chars
    # or tokenizer-specific pieces. Transport limits must fit the actual source.
    assert 5000 <= len(text.split()) <= 15000
    assert len(source) <= 400_000
    assert len(text) <= 200_000
    assert text.splitlines()[0] == title
    assert not text.startswith("\ufeff")
    assert "\x00" not in text


@pytest.mark.parametrize("filename,title,start,middle,tail", CASES)
def test_oracle_facts_cover_beginning_middle_and_final_corrections(
    filename, title, start, middle, tail
):
    text = (EXAMPLES_DIR / filename).read_text(encoding="utf-8")
    # Location matters: an accidentally clipped source must fail even if its
    # introductory facts and total title still look plausible.
    for marker, lower, upper in (
        (start, 0.0, 0.20),
        (middle, 0.30, 0.65),
        (tail, 0.80, 1.0),
    ):
        assert text.count(marker) == 1, (filename, marker)
        position = text.index(marker) / len(text)
        assert lower <= position <= upper, (filename, marker, position)


@pytest.mark.parametrize("filename,title,start,middle,tail", CASES)
def test_examples_are_dialogues_with_seven_substantive_topics(
    filename, title, start, middle, tail
):
    text = (EXAMPLES_DIR / filename).read_text(encoding="utf-8")
    turns = [paragraph for paragraph in text.split("\n\n") if ": " in paragraph]
    speakers = {turn.split(": ", 1)[0].strip() for turn in turns}
    assert len(turns) >= 70
    assert len(speakers) >= 4
    assert text.count("Обсудим вопрос «") == 7
