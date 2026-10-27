from alembic import context
from sqlalchemy import create_engine

from app.core.config import settings
from app.db.models import Base
from app import auth_models
from app.db import variant_models
from app.db import template_models
from app.db import audio_models  # Register audio metadata for Alembic checks.

target_metadata = Base.metadata
url = context.config.attributes.get("database_url") or settings.database_url
if not url:
    raise RuntimeError("DATABASE_URL is required for migrations")

if context.is_offline_mode():
    context.configure(url=url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = create_engine(url, hide_parameters=True)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()
