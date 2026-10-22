import uuid
from datetime import datetime

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Index, String, Text, func, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.models import Base


class SummaryTemplate(Base):
    __tablename__ = "summary_templates"
    __table_args__ = (
        CheckConstraint("structure_mode IN ('strict', 'flexible')", name="ck_template_structure_mode"),
        CheckConstraint("(is_system AND owner_user_id IS NULL) OR (NOT is_system AND owner_user_id IS NOT NULL)", name="ck_template_ownership"),
        CheckConstraint("NOT is_default OR is_system", name="ck_template_default_system"),
        Index("uq_template_default", "is_default", unique=True, postgresql_where=text("is_default")),
    )
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    owner_user_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(Text, default="", server_default="")
    structure_mode: Mapped[str] = mapped_column(String(16), default="strict")
    general_instructions: Mapped[str] = mapped_column(Text, default="", server_default="")
    sections: Mapped[list[dict]] = mapped_column(JSONB)
    is_system: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    is_default: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
