"""Session advisory lock: serialize GPU work without an open DB transaction."""
from contextlib import contextmanager
from sqlalchemy import text
import time

GPU_LOCK = 748139201


@contextmanager
def gpu_slot(factory, enabled=True, on_wait=None):
    if not enabled:
        yield
        return
    engine = factory.kw["bind"]
    with engine.connect() as connection:
        while True:
            acquired = connection.scalar(text("SELECT pg_try_advisory_lock(:key)"), {"key": GPU_LOCK})
            connection.commit()
            if acquired:
                break
            if on_wait:
                on_wait()
            time.sleep(0.5)
        try:
            yield
        finally:
            connection.execute(text("SELECT pg_advisory_unlock(:key)"), {"key": GPU_LOCK})
            connection.commit()
