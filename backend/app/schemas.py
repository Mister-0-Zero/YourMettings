from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
NonemptyText = Annotated[str, StringConstraints(min_length=1)]


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class TranscriptInput(Input):
    text: NonemptyText

    @model_validator(mode="after")
    def nonblank(self):
        if not self.text.strip():
            raise ValueError("Text must not be blank")
        return self


class TranscriptOut(BaseModel):
    id: UUID
    text: str
    is_locked: bool
    created_at: datetime


class FolderInput(Input):
    name: Name
    parent_id: UUID | None = None


class FolderRename(Input):
    name: Name


class FolderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: UUID
    name: str
    parent_id: UUID | None


class FolderNode(FolderOut):
    children: list["FolderNode"] = Field(default_factory=list)


class FolderTree(BaseModel):
    items: list[FolderNode]


class FolderAssignment(Input):
    folder_ids: list[UUID] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def unique_ids(self):
        if len(set(self.folder_ids)) != len(self.folder_ids):
            raise ValueError("folder_ids must be unique")
        return self


class ProcessInput(FolderAssignment):
    title: Name


class CreateProcessInput(ProcessInput, TranscriptInput):
    pass


class ProcessingError(BaseModel):
    code: str
    message: str


class ProcessingOut(BaseModel):
    transcript_id: UUID
    status: Literal["not_started", "summarizing", "ready", "error"]
    summary_id: UUID | None
    error: ProcessingError | None


class SummaryEdit(Input):
    title: Name | None = None
    content: NonemptyText | None = None

    @model_validator(mode="after")
    def supplied_nonnull(self):
        if not self.model_fields_set:
            raise ValueError("Supply title or content")
        if any(getattr(self, field) is None for field in self.model_fields_set):
            raise ValueError("Explicit null is not allowed")
        return self


class SummaryOut(BaseModel):
    id: UUID
    transcript_id: UUID
    title: str
    content: str
    folder_ids: list[UUID]
    created_at: datetime
    updated_at: datetime


class SummaryList(BaseModel):
    items: list[SummaryOut]
    total: int
    limit: int
    offset: int
