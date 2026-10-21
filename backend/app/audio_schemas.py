from typing import Annotated, Literal
from uuid import UUID
from datetime import datetime

from pydantic import BaseModel, Field, StringConstraints

from app.schemas import Input, ProcessInput


class AudioSessionInput(ProcessInput):
    pass


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
    parameters: ProcessInput
    error_code: str | None
    boundary_warnings: list[dict]
    chunks: list[AudioChunkOut]
    worker_status: str
    chunk_target_seconds: int
    max_chunk_seconds: int
    max_upload_bytes: int
    max_overlap_ms: int
    max_chunks: int
