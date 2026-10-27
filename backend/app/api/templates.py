from uuid import UUID

from fastapi import APIRouter, Depends, Response
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.db.session import current_user_id, get_db
from app.db.template_models import SummaryTemplate
from app.services.template_catalog import accessible_template, owned_template
from app.template_schemas import TemplateCopyInput, TemplateInput, TemplateList, TemplateOut

router = APIRouter(prefix="/summary-templates", tags=["summary-templates"])


@router.get("", response_model=TemplateList)
def list_templates(db: Session = Depends(get_db)):
    rows = db.scalars(select(SummaryTemplate).where(or_(
        SummaryTemplate.is_system.is_(True), SummaryTemplate.owner_user_id == current_user_id(db)
    )).order_by(SummaryTemplate.is_default.desc(), SummaryTemplate.is_system.desc(),
        SummaryTemplate.name, SummaryTemplate.id)).all()
    return TemplateList(items=[TemplateOut.model_validate(row) for row in rows])


@router.post("", response_model=TemplateOut, status_code=201)
def create_template(body: TemplateInput, db: Session = Depends(get_db)):
    item = SummaryTemplate(**body.model_dump(mode="json"), owner_user_id=current_user_id(db))
    db.add(item)
    db.commit()
    return item


@router.get("/{id}", response_model=TemplateOut)
def get_template(id: UUID, db: Session = Depends(get_db)):
    return accessible_template(db, id)


@router.put("/{id}", response_model=TemplateOut)
def replace_template(id: UUID, body: TemplateInput, db: Session = Depends(get_db)):
    item = owned_template(db, id, lock=True)
    for key, value in body.model_dump(mode="json").items():
        setattr(item, key, value)
    db.commit()
    return item


@router.delete("/{id}", status_code=204)
def delete_template(id: UUID, db: Session = Depends(get_db)):
    item = owned_template(db, id, lock=True)
    db.delete(item)
    db.commit()
    return Response(status_code=204)


@router.post("/{id}/copy", response_model=TemplateOut, status_code=201)
def copy_template(id: UUID, body: TemplateCopyInput = TemplateCopyInput(), db: Session = Depends(get_db)):
    source = accessible_template(db, id, lock=True)
    data = TemplateOut.model_validate(source).model_dump(mode="json", include=set(TemplateInput.model_fields))
    data["name"] = body.name or (source.name[:191] + " (копия)")
    item = SummaryTemplate(**data, owner_user_id=current_user_id(db))
    db.add(item)
    db.commit()
    return item
