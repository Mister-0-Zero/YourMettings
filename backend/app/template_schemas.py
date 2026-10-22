"""Validated template definitions shared by persistence and unsaved previews."""
from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
Instruction = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=4000)]


class TemplateSection(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID
    title: Name
    instruction: Instruction
    position: int = Field(ge=0, strict=True)
    required: bool = True
    type: Literal["section", "repeated"] = "section"
    children: list["TemplateSection"] = Field(default_factory=list, max_length=12)

    @model_validator(mode="after")
    def valid_children(self):
        if self.type == "section" and self.children:
            raise ValueError("Ordinary sections cannot contain children")
        if self.type == "repeated":
            if not self.children:
                raise ValueError("Repeated sections require ordinary children")
            if any(child.type != "section" for child in self.children):
                raise ValueError("Only ordinary sections may be nested; maximum depth is 2")
        return self


class TemplateInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: Name
    description: Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000)] = ""
    structure_mode: Literal["strict", "flexible"] = "strict"
    general_instructions: Annotated[str, StringConstraints(strip_whitespace=True, max_length=8000)] = ""
    sections: list[TemplateSection] = Field(min_length=1, max_length=20)

    @model_validator(mode="after")
    def valid_structure(self):
        seen = set()
        count = 0
        for group in [self.sections, *(section.children for section in self.sections)]:
            if [section.position for section in group] != list(range(len(group))):
                raise ValueError("Section positions must be consecutive from 0 in array order")
            for section in group:
                if section.id in seen:
                    raise ValueError("Section identifiers must be globally unique")
                seen.add(section.id)
                count += 1
        if count > 100:
            raise ValueError("At most 100 sections are allowed in total")
        return self


class TemplateCopyInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: Name | None = None


class TemplateOut(TemplateInput):
    model_config = ConfigDict(extra="forbid", from_attributes=True)
    id: UUID
    is_system: bool
    is_default: bool
    owner_user_id: UUID | None
    created_at: datetime
    updated_at: datetime


class TemplateList(BaseModel):
    items: list[TemplateOut]
