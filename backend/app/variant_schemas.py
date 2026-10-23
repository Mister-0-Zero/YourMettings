from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, Field, StringConstraints, model_validator

from app.schemas import Input, Name, GenerationOptionsInput, NavigationHeading, ProcessingError


class SelectionInput(Input):
    text: str | None = None
    transcript_id: UUID | None = None
    summary_id: UUID | None = None
    audio_session_id: UUID | None = None
    title: Name | None = None
    folder_ids: list[UUID] = Field(default_factory=list, max_length=100)
    confirm: bool = False
    reviewed_text_sha256: Annotated[str, StringConstraints(pattern="^[0-9a-f]{64}$")] | None = None
    boundaries_reviewed: bool = False

    @model_validator(mode="after")
    def source_and_placement(self):
        if sum(x is not None for x in (self.text, self.transcript_id, self.summary_id, self.audio_session_id)) != 1:
            raise ValueError("Supply exactly one source")
        if self.text is not None and not self.text.strip():
            raise ValueError("Text must not be blank")
        if len(set(self.folder_ids)) != len(self.folder_ids):
            raise ValueError("Folders must be distinct")
        if self.summary_id is None and (self.title is None or not self.folder_ids):
            raise ValueError("New summary requires title and folders")
        if self.summary_id is not None and (self.title is not None or self.folder_ids):
            raise ValueError("Existing summary retains title and folders")
        return self


class CandidateInput(GenerationOptionsInput):
    template_id: UUID | None = None


class CandidateOut(BaseModel):
    id: UUID
    selection_id: UUID
    status: Literal["queued", "generating", "ready", "error", "discarded", "expired"]
    content: str | None
    template_snapshot: dict | None
    generation_options: dict | None
    navigation: list[NavigationHeading]
    processing_metadata: dict
    error: ProcessingError | None
    created_at: datetime
    expires_at: datetime


class SelectionOut(BaseModel):
    id: UUID
    status: Literal["open", "accepted", "cancelled", "expired"]
    transcript_id: UUID | None
    summary_id: UUID | None
    summary_version: str | None
    accepted_candidate_id: UUID | None
    expires_at: datetime
    candidates: list[CandidateOut] = Field(default_factory=list)


class AcceptCandidate(Input):
    candidate_id: UUID
    expected_version: Annotated[str, StringConstraints(pattern="^[0-9a-f]{64}$")] | None = None
