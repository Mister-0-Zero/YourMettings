from copy import deepcopy
from pathlib import Path
import runpy
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import select

from app.db.models import User
from app.db.template_models import SummaryTemplate
from app.services.template_catalog import (
    DEFAULT_TEMPLATE_ID, SYSTEM_TEMPLATES, resolve_template_snapshot, seed_system_templates,
)
from app.template_schemas import TemplateInput

PREFIX = "/api/v1/summary-templates"


def definition(mode="strict"):
    return {"name": "Мой шаблон", "description": "Описание", "structure_mode": mode,
        "general_instructions": "Сохрани существенные аргументы.", "sections": [
            {"id": str(uuid4()), "title": "Темы", "instruction": "Выдели смысловые темы.",
             "position": 0, "required": True, "type": "repeated", "children": [
                 {"id": str(uuid4()), "title": "Решения", "instruction": "Укажи принятые решения.",
                  "position": 0, "required": True, "type": "section", "children": []}]}]}


def test_system_definitions_validate_and_identifiers_are_stable():
    assert len(SYSTEM_TEMPLATES) == 7
    assert len({item["id"] for item in SYSTEM_TEMPLATES}) == 7
    assert [item["id"] for item in SYSTEM_TEMPLATES if item["is_default"]] == [str(DEFAULT_TEMPLATE_ID)]
    for item in SYSTEM_TEMPLATES:
        payload = {key: value for key, value in item.items() if key in TemplateInput.model_fields}
        parsed = TemplateInput.model_validate(payload)
        assert parsed.structure_mode == ("flexible" if item["name"] == "Мозговой штурм" else "strict")
    universal = SYSTEM_TEMPLATES[0]
    assert [row["title"] for row in universal["sections"]] == [
        "Общая информация", "Содержание", "Тематический разбор", "Общие итоги"]
    assert len(universal["sections"][2]["children"]) == 8


def test_migration_has_frozen_matching_seeds():
    migration = Path(__file__).resolve().parents[1] / "migrations/versions/0006_templates.py"
    assert runpy.run_path(str(migration))["FROZEN_SYSTEM_TEMPLATES"] == SYSTEM_TEMPLATES


@pytest.mark.parametrize("mode", ["strict", "flexible"])
def test_valid_repeated_structure(mode):
    assert TemplateInput.model_validate(definition(mode)).structure_mode == mode


@pytest.mark.parametrize("mutation", [
    lambda d: d.update(name=" "),
    lambda d: d.update(structure_mode="anything"),
    lambda d: d.update(is_system=True),
    lambda d: d.update(owner_user_id=str(uuid4())),
    lambda d: d.update(is_default=True),
    lambda d: d["sections"][0].update(instruction=" \n "),
    lambda d: d["sections"][0].update(position=2),
    lambda d: d["sections"][0].update(position=True),
    lambda d: d["sections"][0].update(type="unknown"),
    lambda d: d["sections"][0].update(children=[]),
    lambda d: d["sections"][0].update(type="section"),
    lambda d: d["sections"][0]["children"][0].update(id=d["sections"][0]["id"]),
    lambda d: d["sections"][0]["children"][0].update(position=1),
    lambda d: d["sections"][0]["children"][0].update(type="repeated", children=[
        {"id": str(uuid4()), "title": "Глубже", "instruction": "Нельзя", "position": 0}]),
])
def test_invalid_structure(mutation):
    payload = definition()
    mutation(payload)
    with pytest.raises(ValidationError):
        TemplateInput.model_validate(payload)


def test_structure_size_limits():
    for top, children in [(21, 0), (1, 13), (8, 12)]:
        payload = definition()
        payload["sections"] = []
        for position in range(top):
            row = {"id": str(uuid4()), "title": "Тема", "instruction": "Раскрой тему", "position": position,
                "type": "repeated" if children else "section", "children": []}
            for child in range(children):
                row["children"].append({"id": str(uuid4()), "title": "Подтема", "instruction": "Раскрой подтему", "position": child})
            payload["sections"].append(row)
        with pytest.raises(ValidationError):
            TemplateInput.model_validate(payload)


@pytest.mark.integration
def test_catalog_crud_and_copy(client):
    listed = client.get(PREFIX)
    assert listed.status_code == 200
    assert len(listed.json()["items"]) == 7
    original = client.get(f"{PREFIX}/{DEFAULT_TEMPLATE_ID}").json()
    for method in ["put", "delete"]:
        kwargs = {"json": definition()} if method == "put" else {}
        response = getattr(client, method)(f"{PREFIX}/{DEFAULT_TEMPLATE_ID}", **kwargs)
        assert response.status_code == 403
        assert response.json()["error"]["code"] == "template_read_only"
    copied = client.post(f"{PREFIX}/{DEFAULT_TEMPLATE_ID}/copy", json={})
    assert copied.status_code == 201
    copy = copied.json()
    assert not copy["is_system"] and not copy["is_default"]
    assert copy["sections"] == original["sections"]
    assert copy["id"] != original["id"] and copy["owner_user_id"] is not None
    payload = definition("flexible")
    created = client.post(PREFIX, json=payload)
    assert created.status_code == 201
    identifier = created.json()["id"]
    assert client.get(f"{PREFIX}/{identifier}").json()["sections"] == payload["sections"]
    payload["name"] = "После редактирования"
    payload["structure_mode"] = "strict"
    replaced = client.put(f"{PREFIX}/{identifier}", json=payload)
    assert replaced.status_code == 200
    assert replaced.json()["name"] == payload["name"]
    assert replaced.json()["structure_mode"] == "strict"
    second_copy = client.post(f"{PREFIX}/{identifier}/copy", json={"name": "Другая копия"})
    assert second_copy.status_code == 201 and second_copy.json()["name"] == "Другая копия"
    assert client.delete(f"{PREFIX}/{identifier}").status_code == 204
    assert client.get(f"{PREFIX}/{identifier}").status_code == 404
    assert client.delete(f"{PREFIX}/{identifier}").status_code == 404


@pytest.mark.integration
def test_foreign_template_hidden(client, database):
    with database.begin() as db:
        user = User(email="other-template-owner@example.test")
        db.add(user)
        db.flush()
        row = SummaryTemplate(**definition(), owner_user_id=user.id)
        db.add(row)
        db.flush()
        identifier = row.id
    assert str(identifier) not in {item["id"] for item in client.get(PREFIX).json()["items"]}
    for method, suffix in [("get", ""), ("put", ""), ("delete", ""), ("post", "/copy")]:
        kwargs = {"json": definition()} if method == "put" else {}
        response = getattr(client, method)(f"{PREFIX}/{identifier}{suffix}", **kwargs)
        assert response.status_code == 404


@pytest.mark.integration
def test_snapshot_survives_replacement_and_deletion(client, database):
    created = client.post(PREFIX, json=definition()).json()
    identifier = UUID(created["id"])
    with database.begin() as db:
        snapshot = resolve_template_snapshot(db, identifier)
    before = deepcopy(snapshot)
    payload = definition()
    payload["name"] = "Новое имя"
    assert client.put(f"{PREFIX}/{identifier}", json=payload).status_code == 200
    assert client.delete(f"{PREFIX}/{identifier}").status_code == 204
    assert snapshot == before and snapshot["name"] == created["name"]


@pytest.mark.integration
def test_seeding_is_idempotent_and_default_resolves(database):
    with database.begin() as db:
        seed_system_templates(db)
        seed_system_templates(db)
        assert len(db.scalars(select(SummaryTemplate).where(SummaryTemplate.is_system)).all()) == 7
        assert resolve_template_snapshot(db)["id"] == str(DEFAULT_TEMPLATE_ID)


@pytest.mark.integration
def test_forbidden_fields_and_invalid_update_are_rejected(client):
    payload = definition()
    payload["is_default"] = True
    assert client.post(PREFIX, json=payload).status_code == 422
    identifier = client.post(PREFIX, json=definition()).json()["id"]
    payload = definition()
    payload["sections"][0]["instruction"] = " "
    assert client.put(f"{PREFIX}/{identifier}", json=payload).status_code == 422
    assert client.get(f"{PREFIX}/{identifier}").json()["name"] == "Мой шаблон"
