from pathlib import Path
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest

from scripts.dev_launcher import Config, Issue, LaunchError, Launcher, StartupMutex, System


class FakeSystem:
    def __init__(self, *, running=True):
        self.db_issue = None if running else Issue("connection", "Нет подключения", "Проверьте службу")
        self.services = [{"name": "postgresql-x64-18", "running": running}]
        self.models = ["qwen3.8:27b"] if running else None
        self.backend = running
        self.foreign = False
        self.service_denied = False
        self.model_failed = False
        self.actions = []

    def check_lan(self):
        pass

    def listeners(self, port):
        if port == 8000 and (self.backend or self.foreign):
            return [{"pid": 123, "owned": not self.foreign, "address": address}
                for address in ("127.0.0.1", "192.168.1.100")]
        return []

    def database(self):
        return self.db_issue

    def postgres_services(self):
        return self.services

    def start_service(self, name):
        self.actions.append(("postgres", name))
        if self.service_denied:
            raise PermissionError("service permissions")
        self.services[0]["running"] = True
        self.db_issue = None

    def tags(self):
        return self.models

    def start_ollama(self):
        self.actions.append("ollama")
        self.models = ["qwen3.8:27b"]

    def load_model(self):
        self.actions.append("load_model")
        if self.model_failed:
            raise LaunchError("Ollama", "Недостаточно VRAM", "Освободите видеопамять")

    def start_backend(self):
        self.actions.append("backend")
        self.backend = True

    def backend_ready(self):
        return self.backend

    def wait(self, predicate, seconds):
        return bool(predicate())


@pytest.fixture
def config(tmp_path):
    return Config(tmp_path, "postgresql+psycopg://app:not-a-real-password@127.0.0.1/db", model="qwen3.8:27b")


def test_all_stopped_starts_in_order(config):
    system = FakeSystem(running=False)
    Launcher(config, system).run()
    assert system.actions == [("postgres", "postgresql-x64-18"), "ollama", "load_model", "backend"]


def test_repeat_start_does_not_duplicate_processes(config):
    system = FakeSystem(running=False)
    Launcher(config, system).run()
    Launcher(config, system).run()
    assert system.actions.count("ollama") == 1
    assert system.actions.count("backend") == 1
    assert system.actions.count(("postgres", "postgresql-x64-18")) == 1


def test_running_services_are_reused(config):
    system = FakeSystem()
    Launcher(config, system).run()
    assert system.actions == ["load_model"]


def test_postgres_auth_failure_does_not_restart_service_or_leak_credentials(config, capsys):
    system = FakeSystem()
    system.db_issue = Issue("auth", "Неверные учётные данные", "Проверьте .env локально")
    with pytest.raises(LaunchError) as error:
        Launcher(config, system).run()
    assert error.value.component == "PostgreSQL"
    assert system.actions == []
    assert "not-a-real-password" not in str(error.value) + capsys.readouterr().out + repr(config)


def test_running_postgres_but_unavailable_database_is_not_restarted(config):
    system = FakeSystem()
    system.db_issue = Issue("connection", "Нет подключения", "Проверьте порт")
    with pytest.raises(LaunchError, match="Служба уже работает"):
        Launcher(config, system).run()
    assert system.actions == []


def test_postgres_service_access_denied_has_actionable_error(config):
    system = FakeSystem(running=False)
    system.service_denied = True
    with pytest.raises(LaunchError, match="services.msc"):
        Launcher(config, system).run()
    assert "ollama" not in system.actions


def test_multiple_postgres_services_require_explicit_choice(config):
    system = FakeSystem(running=False)
    system.services.append({"name": "postgresql-x64-17", "running": False})
    with pytest.raises(LaunchError, match="PostgresService"):
        Launcher(config, system).run()
    assert system.actions == []


def test_ollama_stopped_is_started_once(config):
    system = FakeSystem()
    system.models = None
    Launcher(config, system).run()
    assert system.actions == ["ollama", "load_model"]


def test_missing_model_never_downloads_or_starts_backend(config):
    system = FakeSystem()
    system.backend = False
    system.models = ["another:tag"]
    with pytest.raises(LaunchError, match="не установлена"):
        Launcher(config, system).run()
    assert system.actions == []


def test_installed_model_that_cannot_load_is_not_reported_ready(config):
    system = FakeSystem()
    system.backend = False
    system.model_failed = True
    with pytest.raises(LaunchError, match="VRAM"):
        Launcher(config, system).run()
    assert "backend" not in system.actions


def test_foreign_port_is_never_killed_and_nothing_is_started(config):
    system = FakeSystem(running=False)
    system.foreign = True
    with pytest.raises(LaunchError, match="8000"):
        Launcher(config, system).run()
    assert system.actions == []


def test_our_unhealthy_backend_is_not_duplicated(config):
    system = FakeSystem()
    system.backend_ready = lambda: False
    with pytest.raises(LaunchError, match="не прошёл"):
        Launcher(config, system).run()
    assert "backend" not in system.actions


def test_check_only_does_not_start_or_load_anything(config):
    system = FakeSystem()
    Launcher(config, system, check_only=True).run()
    assert system.actions == []


def test_concurrent_launch_is_blocked_by_windows_mutex(tmp_path):
    started, release = threading.Event(), threading.Event()
    def hold():
        with StartupMutex(tmp_path):
            started.set()
            assert release.wait(5)
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(hold)
        assert started.wait(3)
        try:
            with pytest.raises(LaunchError, match="Другой запуск"):
                with StartupMutex(tmp_path):
                    pass
        finally:
            release.set()
        future.result()


def test_real_foreign_listener_is_identified_without_stopping_it(config):
    import socket
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        records = System(config).listeners(listener.getsockname()[1])
        assert records and all(not item["owned"] for item in records)


def test_real_unavailable_database_does_not_expose_password(config):
    import socket
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        # Bound but not listening: cannot accidentally address another service.
        config.database_url = f"postgresql+psycopg://app:not-a-real-password@127.0.0.1:{port}/missing"
        issue = System(config).database()
    assert issue.code == "connection"
    assert "not-a-real-password" not in repr(issue)


def test_changed_env_is_not_silently_ignored(config):
    directory = config.root / "backend"
    directory.mkdir()
    (directory / ".env").write_text("# no secrets", encoding="utf-8")
    system = FakeSystem()
    original = system.listeners
    system.listeners = lambda port: [{**item, "started": "2000-01-01T00:00:00+00:00"} for item in original(port)]
    with pytest.raises(LaunchError, match="изменён после запуска"):
        Launcher(config, system).run()
