from pathlib import Path

from fastapi import APIRouter
from pydantic import BaseModel

from app.api.errors import fail

router = APIRouter(prefix="/template-preview-examples", tags=["summary-templates"])
EXAMPLES = {
    "team-standup": "Планёрка команды",
    "work-report": "Отчёт руководителю о проделанной работе",
    "engagement-ideas": "Идеи для повышения вовлечённости сотрудников",
}


class ExampleInfo(BaseModel):
    id: str
    title: str
    word_count: int
    char_count: int
    byte_count: int


class ExampleOut(ExampleInfo):
    text: str


class ExampleList(BaseModel):
    items: list[ExampleInfo]


def example(id):
    if id not in EXAMPLES:
        fail(404, "not_found", "Встроенный пример не найден.")
    text = (Path(__file__).resolve().parents[1] / "examples" / (id + ".txt")).read_text(encoding="utf-8")
    return ExampleOut(id=id, title=EXAMPLES[id], text=text, word_count=len(text.split()),
        char_count=len(text), byte_count=len(text.encode("utf-8")))


@router.get("", response_model=ExampleList)
def list_examples():
    return ExampleList(items=[ExampleInfo.model_validate(example(id).model_dump()) for id in EXAMPLES])


@router.get("/{id}", response_model=ExampleOut)
def get_example(id: str):
    return example(id)
