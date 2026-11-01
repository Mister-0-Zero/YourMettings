from typing import Annotated, Literal
from uuid import UUID
from datetime import datetime

from pydantic import BaseModel, Field, StringConstraints, model_validator

from app.schemas import Input, ProcessInput


class AudioAutomaticParameters(ProcessInput):
    expected_template_version: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")] | None = None


class AudioPipelineRetry(Input):
    parameters: AudioAutomaticParameters | None = None


class AudioPipelineCancel(Input):
    confirm: bool = False


class AudioPipelineOut(BaseModel):
    mode: Literal["automatic"]
    phase: Literal["receiving", "asr", "queued_qwen", "generating_qwen", "completed", "needs_input", "review_required", "error", "cancelled"]
    error_code: str | None = None
    summary_id: UUID | None = None


class AudioSessionInput(ProcessInput):
    # Recording can start before placement; confirmation still uses ProcessInput.
    folder_ids: list[UUID] = Field(default_factory=list, max_length=100)
    processing_mode: Literal["review", "automatic"] = "review"
    expected_template_version: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")] | None = None

    @model_validator(mode="after")
    def automatic_placement(self):
        if self.processing_mode == "automatic" and not self.folder_ids:
            raise ValueError("Automatic processing requires at least one folder")
        return self


class AudioComplete(Input):
    expected_chunk_count: int = Field(ge=1, le=240)


class AudioRetry(Input):
    sequence_numbers: list[Annotated[int, Field(ge=0, le=239)]] | None = Field(None, min_length=1, max_length=240)


class AudioConfirm(ProcessInput):
    confirm: bool
    reviewed_text_sha256: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
    boundaries_reviewed: bool = False


class AudioChunkOut(BaseModel):
    id: UUID
    sequence_number: int
    start_ms: int
    overlap_ms: int
    duration_ms: int
    sha256: str
    byte_count: int
    audio_format: str
    status: Literal["queued", "transcribing", "done", "failed"]
    text: str | None
    segments: list[dict] | None
    attempt: int
    error_code: str | None


class AudioChunkAccepted(BaseModel):
    accepted: bool
    safe_to_delete_local: bool
    chunk: AudioChunkOut


class AudioSessionOut(BaseModel):
    id: UUID
    status: Literal["recording", "transcribing", "ready_for_review", "failed", "completed"]
    recording_closed: bool
    expected_chunk_count: int | None
    received_chunk_count: int
    transcribed_chunk_count: int
    missing_sequence_numbers: list[int]
    transcript_id: UUID | None
    transcript_sha256: str | None
    processing: dict | None
    pipeline: AudioPipelineOut | None = None
    parameters: AudioSessionInput
    error_code: str | None
    boundary_warnings: list[dict]
    chunks: list[AudioChunkOut]
    worker_status: str
    chunk_target_seconds: int
    max_chunk_seconds: int
    max_upload_bytes: int
    max_overlap_ms: int
    max_chunks: int
