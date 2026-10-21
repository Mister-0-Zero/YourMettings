from typing import Annotated, Literal
from uuid import UUID
from datetime import datetime

from pydantic import Field, StringConstraints

from app.schemas import Input, ProcessInput


class AudioSessionInput(ProcessInput):
    pass


class AudioComplete(Input):
    expected_chunk_count: int = Field(ge=1, le=240)


class AudioRetry(Input):
    sequence_numbers: list[int] | None = None


class AudioConfirm(ProcessInput):
    confirm: bool
    reviewed_text_sha256: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
    boundaries_reviewed: bool = False
