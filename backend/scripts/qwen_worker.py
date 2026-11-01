"""One durable dispatcher; crashes recover through leases, not startup error reset."""
import os
from pathlib import Path
import signal
import sys
from threading import Event
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sqlalchemy import text
from app.db.job_models import QwenWorkerState
from app.db.session import get_session_factory
from app.integrations.ollama import get_generator
from app.services.jobs import claim, execute, now

LOCK = 748139203


def run():
    factory = get_session_factory()
    stop = Event()
    for name in ('SIGINT', 'SIGTERM', 'SIGBREAK'):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), lambda *_: stop.set())
    generation = uuid.uuid4()
    # Losing this exact session is fatal; never silently reconnect and continue.
    with factory.kw['bind'].connect() as connection:
        if not connection.scalar(text('SELECT pg_try_advisory_lock(:key)'), {'key': LOCK}):
            connection.commit()
            return
        connection.commit()
        try:
            while not stop.is_set():
                if connection.invalidated or connection.closed:
                    raise RuntimeError('qwen_dispatch_lock_lost')
                connection.execute(text('SELECT 1'))
                connection.commit()
                with factory.begin() as db:
                    state = db.get(QwenWorkerState, 1)
                    if state is None:
                        state = QwenWorkerState(id=1)
                        db.add(state)
                    state.pid, state.generation, state.heartbeat_at = os.getpid(), generation, now()
                record = claim(factory)
                if record:
                    # Per-job heartbeat is independent throughout this blocking work.
                    execute(factory, record, get_generator())
                else:
                    stop.wait(1)
        finally:
            with factory.begin() as db:
                state = db.get(QwenWorkerState, 1)
                if state and state.generation == generation:
                    db.delete(state)
            if not connection.invalidated:
                connection.execute(text('SELECT pg_advisory_unlock(:key)'), {'key': LOCK})
                connection.commit()


if __name__ == '__main__':
    run()

