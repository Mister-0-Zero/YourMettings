from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.dependencies import owned_folder
from app.db.models import Folder
from app.db.session import TEST_USER_ID, get_db
from app.schemas import FolderInput, FolderNode, FolderOut, FolderRename, FolderTree
from app.services.deletion import lock_user_data
from app.services.folders import delete_folder_tree
from typing import Literal

router = APIRouter(prefix="/folders", tags=["folders"])


@router.post("", response_model=FolderOut, status_code=201)
def create_folder(body: FolderInput, db: Session = Depends(get_db)):
    lock_user_data(db)
    if body.parent_id is not None:
        owned_folder(db, body.parent_id)
    item = Folder(user_id=TEST_USER_ID, name=body.name, parent_id=body.parent_id)
    db.add(item)
    db.commit()
    return item


@router.get("", response_model=FolderTree)
def folder_tree(db: Session = Depends(get_db)):
    rows = db.scalars(select(Folder).where(Folder.user_id == TEST_USER_ID).order_by(Folder.name, Folder.id)).all()
    nodes = {row.id: FolderNode.model_validate(row) for row in rows}
    roots = []
    for row in rows:
        node = nodes[row.id]
        if row.parent_id is None:
            roots.append(node)
        else:
            nodes[row.parent_id].children.append(node)
    return FolderTree(items=roots)


@router.patch("/{id}", response_model=FolderOut)
def rename_folder(id: UUID, body: FolderRename, db: Session = Depends(get_db)):
    lock_user_data(db)
    item = owned_folder(db, id)
    item.name = body.name
    db.commit()
    return item


@router.delete("/{id}", status_code=204,
    responses={404: {"description": "Folder not found"}, 409: {"description": "Folder is processing"},
        422: {"description": "Invalid mode or confirmation required"}})
def delete_folder(id: UUID, mode: Literal["with_contents"] = Query(...),
    confirm: bool = False, db: Session = Depends(get_db)):
    delete_folder_tree(db, id, confirm=confirm)
    db.commit()
    return Response(status_code=204)
