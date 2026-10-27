"""Local Windows startup checks. No migrations, DB writes or public endpoints."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from urllib.parse import urlsplit

import httpx


@dataclass
class Config:
    root: Path
    database_url: str = field(repr=False)
    ollama_url: str = "http://127.0.0.1:11435"
    model: str = ""
    lan_host: str = "192.168.1.100"
    service: str = ""
    asr_enabled: bool = True
    asr_home: Path | None = None
    asr_timeout: int = 180
    auth_issues: tuple[str, ...] = ()
    bind_lan: bool = True
    demo_enabled: bool = False
    demo_secret: str = field(default="", repr=False)

    @property
    def python(self):
        return self.root / "backend" / ".venv" / "Scripts" / "python.exe"


class LaunchError(Exception):
    def __init__(self, component, reason, action):
        self.component, self.reason, self.action = component, reason, action
        super().__init__(f"{component}: {reason}\nЧто сделать: {action}")


@dataclass
class Issue:
    code: str
    reason: str
    action: str


class System:
    def __init__(self, config):
        self.config = config
        self.children = []
        self.log_dir = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "YourMettings" / "logs"

    def powershell(self, script, **variables):
        env = os.environ.copy()
        env.update({"YM_DEV_" + k.upper(): str(v) for k, v in variables.items()})
        result = subprocess.run([
            str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"),
            "-NoProfile", "-NonInteractive", "-Command", script,
        ], env=env, capture_output=True, encoding="utf-8", errors="replace", timeout=20)
        if result.returncode:
            raise RuntimeError("Windows diagnostic command failed")
        return json.loads(result.stdout.lstrip("\ufeff").strip() or "null")

    def check_lan(self):
        if not self.config.bind_lan:
            return
        try:
            address = ipaddress.IPv4Address(self.config.lan_host)
        except ValueError as exc:
            raise LaunchError("Сеть", "Некорректный IPv4-адрес.", "Укажите -LanHost с IPv4 локального интерфейса ПК.") from exc
        if not address.is_private or address.is_loopback or address.is_unspecified or address.is_multicast:
            raise LaunchError("Сеть", "Нужен конкретный локальный IPv4 ПК.", "Укажите -LanHost с адресом LAN; не используйте 0.0.0.0.")
        found = self.powershell("""
            [bool](Get-NetIPAddress -IPAddress $env:YM_DEV_ADDRESS -ErrorAction SilentlyContinue) | ConvertTo-Json
        """, address=address)
        if not found:
            raise LaunchError("Сеть", "Прежний LAN-адрес отсутствует на ПК.", "Проверьте ipconfig и запустите start-dev.ps1 -LanHost <IPv4 ПК>.")

    def listeners(self, port):
        return self.powershell(r"""
            $ErrorActionPreference='Stop'
            $items=@(Get-NetTCPConnection -State Listen -LocalPort ([int]$env:YM_DEV_PORT) -ErrorAction SilentlyContinue)
            $result=@(foreach ($item in $items) {
                $current=[int]$item.OwningProcess; $rootSeen=$false; $moduleSeen=$false
                $owner=Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
                for ($i=0; $i -lt 4 -and $current -gt 0; $i++) {
                    $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
                    if (-not $proc) { break }
                    $cmd=[string]$proc.CommandLine
                    if ($cmd.IndexOf($env:YM_DEV_ROOT,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $rootSeen=$true }
                    if ($cmd -match '-m\s+(app\.run|uvicorn\s+app\.main:app)(\s|$)') { $moduleSeen=$true }
                    $current=[int]$proc.ParentProcessId
                }
                [pscustomobject]@{pid=[int]$item.OwningProcess; address=$item.LocalAddress; owned=($rootSeen -and $moduleSeen); started=$owner.CreationDate.ToUniversalTime().ToString('o')}
            })
            ConvertTo-Json -InputObject $result -Compress
        """, port=port, root=str(self.config.root / "backend") + os.sep) or []

    def database(self):
        from sqlalchemy import create_engine, text
        from sqlalchemy.exc import SQLAlchemyError
        from sqlalchemy.pool import NullPool
        from alembic.config import Config as AlembicConfig
        from alembic.script import ScriptDirectory
        engine = None
        try:
            engine = create_engine(self.config.database_url, hide_parameters=True,
                poolclass=NullPool, connect_args={"connect_timeout": 3})
            with engine.connect() as connection:
                connection.execute(text("SELECT 1"))
                actual = set(connection.execute(text("SELECT version_num FROM alembic_version")).scalars())
                cfg = AlembicConfig(str(self.config.root / "backend/alembic.ini"))
                expected = set(ScriptDirectory.from_config(cfg).get_heads())
                if actual != expected:
                    return Issue("schema", "Схема БД не соответствует backend.", "В backend выполните .venv\\Scripts\\python.exe -m alembic upgrade head.")
            return None
        except SQLAlchemyError as exc:
            code = getattr(getattr(exc, "orig", None), "sqlstate", "")
            internal = str(getattr(exc, "orig", "")).lower()
            if code in ("28P01", "28000") or "password authentication" in internal:
                return Issue("auth", "PostgreSQL отклонил учётные данные.", "Проверьте DATABASE_URL в backend/.env локально; не отправляйте пароль в чат.")
            if code == "3D000" or "database" in internal and "does not exist" in internal:
                return Issue("missing", "Указанная база не существует.", "Проверьте имя существующей базы в DATABASE_URL; скрипт не создаёт базы.")
            if code in ("42P01", "42501"):
                return Issue("schema", "Нет схемы приложения или прав на неё.", "Проверьте миграции и права роли из DATABASE_URL.")
            return Issue("connection", "Не удалось подключиться к PostgreSQL.", "Проверьте службу, адрес и порт DATABASE_URL.")
        finally:
            if engine is not None:
                engine.dispose()

    def postgres_services(self):
        return self.powershell("""
            $items=@(Get-Service '*postgres*' -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{name=$_.Name; running=($_.Status -eq 'Running')}
            }); ConvertTo-Json -InputObject $items -Compress
        """) or []

    def start_service(self, name):
        self.powershell("""
            $ErrorActionPreference='Stop'; Start-Service -Name $env:YM_DEV_SERVICE
        """, service=name)

    def tags(self):
        try:
            with httpx.Client(timeout=4, trust_env=False) as client:
                response = client.get(self.config.ollama_url + "/api/tags")
                response.raise_for_status()
                models = response.json()["models"]
                if not isinstance(models, list):
                    return None
                return [model["name"] for model in models]
        except (httpx.HTTPError, ValueError, KeyError, TypeError):
            return None

    def spawn(self, component, command, env=None):
        self.log_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        log = self.log_dir / f"{stamp}-{component}.log"
        with log.open("ab") as output:
            child = subprocess.Popen(command, cwd=self.config.root / "backend", env=env,
                stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP,
                close_fds=True)
        self.children.append(child)
        print(f"Лог {component}: {log}", flush=True)

    def start_ollama(self):
        executable = shutil.which("ollama.exe")
        fallback = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/Ollama/ollama.exe"
        if not executable and fallback.is_file():
            executable = str(fallback)
        if not executable:
            raise LaunchError("Ollama", "Не найден установленный ollama.exe.", "Проверьте установку Ollama и PATH. Автоматическая установка не выполняется.")
        env = os.environ.copy()
        # The local server needs no API credentials; do not pass them to its logs.
        for key in list(env):
            if key.upper().startswith("OLLAMA_") and re.search("KEY|TOKEN|SECRET|PASSWORD", key.upper()):
                env.pop(key)
        env["OLLAMA_HOST"] = urlsplit(self.config.ollama_url).netloc
        self.spawn("ollama", [executable, "serve"], env=env)

    def load_model(self):
        from app.db.session import get_session_factory
        from app.core.config import settings
        from app.services.gpu import gpu_slot
        with gpu_slot(get_session_factory(), settings.asr_gpu_serial):
            self._load_model()

    def _load_model(self):
        try:
            with httpx.Client(timeout=180, trust_env=False) as client:
                response = client.post(self.config.ollama_url + "/api/generate", json={
                    "model": self.config.model, "prompt": "", "stream": False, "keep_alive": "5m"})
                response.raise_for_status()
                if response.json().get("done") is not True:
                    raise ValueError("Model not ready")
        except (httpx.HTTPError, ValueError) as exc:
            raise LaunchError("Ollama", "Не удалось загрузить выбранную модель.",
                "Проверьте свободную RAM/VRAM и лог Ollama. Модель не скачивается автоматически.") from exc

    def start_backend(self):
        self.spawn("backend", [str(self.config.python), "-m", "app.run",
            "--lan-host", self.config.lan_host, "--port", "8000"])

    def asr_state(self):
        from sqlalchemy import create_engine, text
        from sqlalchemy.pool import NullPool
        engine = create_engine(self.config.database_url, hide_parameters=True, poolclass=NullPool)
        try:
            with engine.connect() as connection:
                row = connection.execute(text("SELECT pid, status, error_code, "
                    "EXTRACT(EPOCH FROM (now()-heartbeat_at)) AS age FROM asr_worker_state WHERE id=1")).mappings().first()
                if not row:
                    return {"alive": False, "ready": False}
            # A heartbeat alone cannot prove process identity or readiness.
            owned = self.powershell(r"""
                $current=[int]$env:YM_DEV_PID; $rootSeen=$false; $moduleSeen=$false
                for ($i=0; $i -lt 4 -and $current -gt 0; $i++) {
                    $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
                    if (-not $proc) { break }
                    if ($proc.CommandLine -match 'asr_worker\.py') { $moduleSeen=$true }
                    if ($proc.CommandLine.IndexOf($env:YM_DEV_ROOT,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $rootSeen=$true }
                    $current=[int]$proc.ParentProcessId
                }
                [bool]($rootSeen -and $moduleSeen) | ConvertTo-Json
            """, pid=row["pid"], root=str(self.config.root))
            return {"alive": bool(owned), "ready": bool(owned) and row["age"] < 15 and row["status"] in ("ready", "busy"),
                "status": row["status"], "error": row["error_code"], "pid": row["pid"]}
        finally:
            engine.dispose()

    def start_asr(self):
        home = self.config.asr_home or self.config.root / "asr"
        if not (home / ".venv/Scripts/python.exe").is_file():
            raise LaunchError("GigaAM", "Не найдено отдельное ASR-окружение.", "Проверьте ASR_HOME в backend/.env и инструкции ASR. Автоустановка не выполняется.")
        self.spawn("asr-worker", [str(self.config.python), str(self.config.root / "backend/scripts/asr_worker.py")])

    def backend_ready(self):
        try:
            with httpx.Client(base_url="http://127.0.0.1:8000", timeout=3, trust_env=False) as client:
                if getattr(self.config, "demo_enabled", False):
                    headers = {"X-Demo-Key":self.config.demo_secret}
                    health = client.get("/health", headers=headers)
                    me = client.get("/api/v1/auth/me", headers=headers)
                    schema = client.get("/openapi.json")
                    folders = client.get("/api/v1/folders")
                    return (health.status_code == 200 and health.json().get("status") == "ok"
                        and me.status_code == 200 and me.json().get("access_mode") == "demo"
                        and schema.status_code in (401,429) and folders.status_code in (401,429))
                health = client.get("/health")
                schema = client.get("/openapi.json")
                folders = client.get("/api/v1/folders")
                # A deliberately invalid credential must reach auth's DB lookup;
                # this checks backend DB access without a real user or secret.
                auth = client.get("/api/v1/auth/me", headers={"Authorization":"Bearer local-readiness-invalid-token"})
                return (health.status_code == 200 and health.json().get("status") == "ok"
                    and schema.status_code == 401 and schema.json()["error"]["code"] == "authentication_required"
                    and folders.status_code == 401 and folders.json()["error"]["code"] == "authentication_required"
                    and auth.status_code == 401 and auth.json()["error"]["code"] == "invalid_access_token")
        except (httpx.HTTPError, ValueError, KeyError, TypeError):
            return False

    def wait(self, predicate, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.5)
        return False


class Launcher:
    def __init__(self, config, system, *, check_only=False):
        self.config, self.system, self.check_only = config, system, check_only

    def backend_port(self):
        listeners = self.system.listeners(8000)
        if any(not item["owned"] for item in listeners):
            raise LaunchError("FastAPI", "Порт 8000 занят посторонним или неопознанным процессом.",
                "Проверьте владельца порта. Скрипт не завершает процессы и не запускает второй backend.")
        env_file = self.config.root / "backend/.env"
        if env_file.is_file():
            for item in listeners:
                if item.get("started") and env_file.stat().st_mtime > datetime.fromisoformat(item["started"]).timestamp() + 1:
                    raise LaunchError("FastAPI", "backend/.env изменён после запуска backend.",
                        "После завершения обработок остановите свой backend по его PID и повторите запуск для применения настроек.")
        return listeners

    def run(self):
        self.system.check_lan()
        self.backend_port()  # Fail on a collision before starting other components.
        print("[1/4] PostgreSQL: проверка подключения и схемы...", flush=True)
        issue = self.system.database()
        if issue:
            from sqlalchemy.engine import make_url
            host = make_url(self.config.database_url).host or "localhost"
            if issue.code != "connection" or host not in ("localhost", "127.0.0.1", "::1") or self.check_only:
                raise LaunchError("PostgreSQL", issue.reason, issue.action)
            services = self.system.postgres_services()
            if self.config.service:
                services = [s for s in services if s["name"] == self.config.service]
            if len(services) != 1:
                raise LaunchError("PostgreSQL", "Не удалось однозначно выбрать существующую службу.",
                    "Укажите -PostgresService <имя службы>. Новая служба или база не создаётся.")
            if services[0]["running"]:
                raise LaunchError("PostgreSQL", "Служба уже работает, но подключение не прошло.", issue.action)
            try:
                self.system.start_service(services[0]["name"])
            except Exception as exc:
                raise LaunchError("PostgreSQL", "Windows не разрешила запуск существующей службы.",
                    "Запустите службу PostgreSQL в services.msc с нужными правами, затем повторите обычный запуск.") from exc
            if not self.system.wait(lambda: self.system.database() is None, 25):
                issue = self.system.database() or issue
                raise LaunchError("PostgreSQL", issue.reason, issue.action)
        print("PostgreSQL готов: подключение и схема проверены без записи данных.", flush=True)

        print("[2/4] Ollama: проверка API и установленной модели...", flush=True)
        models = self.system.tags()
        if models is None:
            port = urlsplit(self.config.ollama_url).port or 11434
            if self.check_only or self.system.listeners(port):
                raise LaunchError("Ollama", "Настроенный API не отвечает корректно.", "Проверьте OLLAMA_BASE_URL и процесс на его порту.")
            self.system.start_ollama()
            if not self.system.wait(lambda: self.system.tags() is not None, 20):
                raise LaunchError("Ollama", "API не стал доступен после запуска.", "Проверьте лог Ollama и OLLAMA_BASE_URL.")
            models = self.system.tags()
        expected = self.config.model if ":" in self.config.model else self.config.model + ":latest"
        if expected not in models:
            raise LaunchError("Ollama", "Выбранная в OLLAMA_MODEL модель не установлена.",
                "Проверьте ollama list и тег в backend/.env. Скрипт ничего не скачивает.")
        if not self.check_only:
            print(f"Загрузка {self.config.model}, если она ещё не загружена (до 3 минут)...", flush=True)
            self.system.load_model()
        print("Ollama готова; выбранная модель доступна.", flush=True)

        if self.config.asr_enabled:
            print("[3/4] GigaAM: постоянный worker, CUDA, модель и VAD...", flush=True)
            state = self.system.asr_state()
            if not state["ready"]:
                if self.check_only:
                    raise LaunchError("GigaAM", "ASR-worker не готов.", "Запустите start-dev.ps1 без -CheckOnly и проверьте лог ASR.")
                if not state["alive"]:
                    self.system.start_asr()
                if not self.system.wait(lambda: self.system.asr_state()["ready"], self.config.asr_timeout + 10):
                    state = self.system.asr_state()
                    raise LaunchError("GigaAM", "Worker не готов: " + str(state.get("error") or state.get("status") or "нет heartbeat"),
                        "Проверьте ASR_HOME, локальные модели/VAD, CUDA и свободную VRAM. Посмотрите лог ASR; чужие процессы не завершаются.")
            print("GigaAM готов: модель и VAD загружены, очередь доступна.", flush=True)

        print("[4/4] FastAPI: проверка процесса, /health и чтения БД...", flush=True)
        listeners = self.backend_port()
        if not listeners:
            if self.check_only:
                raise LaunchError("FastAPI", "Backend не запущен.", "Запустите start-dev.ps1 без -CheckOnly.")
            self.system.start_backend()
        if not self.system.wait(self.system.backend_ready, 30):
            raise LaunchError("FastAPI", "Backend не прошёл /health, OpenAPI или проверку БД.",
                "Посмотрите лог backend. Скрипт не останавливает процессы и не запускает дубли.")
        listeners = self.backend_port()
        addresses = {item["address"] for item in listeners}
        expected = {"127.0.0.1", self.config.lan_host} if self.config.bind_lan else {"127.0.0.1"}
        if addresses != expected:
            raise LaunchError("Сеть", "Backend не слушает оба настроенных локальных адреса.",
                "Проверьте способ запуска backend; ожидается один процесс app.run с --lan-host.")
        print("\nГОТОВО: PostgreSQL, Ollama, ASR (если включён) и backend проверены.", flush=True)
        for issue in self.config.auth_issues:
            print("Внимание — авторизация: " + issue, flush=True)
        print("ПК: http://127.0.0.1:8000/api/v1 (требуется вход; OpenAPI также защищён)", flush=True)
        if self.config.bind_lan:
            print(f"Телефон (LAN): http://{self.config.lan_host}:8000/api/v1", flush=True)
        else:
            print("LAN listener отключён; используйте USB reverse или защищённый HTTPS-шлюз.", flush=True)
        print("PID backend: " + ", ".join(str(pid) for pid in sorted({x["pid"] for x in listeners})), flush=True)
        print("Закрытие этого окна не останавливает серверы.", flush=True)


class StartupMutex:
    def __init__(self, root):
        self.name = "Local\\YourMettingsDev-" + hashlib.sha256(str(root).lower().encode()).hexdigest()[:16]

    def __enter__(self):
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateMutexW.restype = ctypes.c_void_p
        self.kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
        self.kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        self.kernel.ReleaseMutex.argtypes = [ctypes.c_void_p]
        self.kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        self.handle = self.kernel.CreateMutexW(None, False, self.name)
        if not self.handle:
            raise LaunchError("Запуск", "Не удалось создать локальную блокировку.", "Повторите запуск из обычного PowerShell.")
        if self.kernel.WaitForSingleObject(self.handle, 0) not in (0, 0x80):
            self.kernel.CloseHandle(self.handle)
            raise LaunchError("Запуск", "Другой запуск уже выполняется.", "Дождитесь результата в первом окне; второй экземпляр не запускается.")
        return self

    def __exit__(self, *args):
        self.kernel.ReleaseMutex(self.handle)
        self.kernel.CloseHandle(self.handle)


def load_config(args):
    root = Path(__file__).resolve().parents[2]
    try:
        from app.core.config import Settings
        from sqlalchemy.engine import make_url
        settings = Settings()
        auth_issues = []
        if not settings.demo_enabled and len(settings.auth_secret.encode()) < 32:
            auth_issues.append("AUTH_SECRET не настроен; запрос кода вернёт 503.")
        if not settings.demo_enabled and (not settings.smtp_host or not settings.smtp_from_email or settings.smtp_security not in ("ssl", "starttls")
                or bool(settings.smtp_username) != bool(settings.smtp_password)):
            auth_issues.append("SMTP не настроен полностью; письма не отправляются. См. docs/AUTH_MIGRATION.md.")
        if not (root / "backend/.env").is_file():
            raise ValueError("Missing configuration")
        database = make_url(settings.database_url)
        parsed = urlsplit(settings.ollama_base_url)
        if database.get_backend_name() != "postgresql" or not settings.ollama_model:
            raise ValueError("Invalid configuration")
        if parsed.scheme not in ("http", "https") or parsed.hostname not in ("127.0.0.1", "localhost", "::1") or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
            raise ValueError("Ollama must use a local API")
        return Config(root, settings.database_url, settings.ollama_base_url.rstrip("/"),
            settings.ollama_model, args.lan_host, args.postgres_service,
            settings.asr_enabled, settings.asr_home, settings.asr_startup_timeout_seconds,
            auth_issues=tuple(auth_issues), bind_lan=settings.backend_lan_enabled,
            demo_enabled=settings.demo_enabled, demo_secret=settings.demo_secret)
    except Exception as exc:
        raise LaunchError("Конфигурация", "Не удалось прочитать корректную локальную конфигурацию приложения.",
            "Проверьте backend/.env, DATABASE_URL, OLLAMA_BASE_URL и OLLAMA_MODEL. Содержимое файла не выводится.") from exc


def write_report(path, status, component=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    report = {"status": status, "component": component,
        "time": datetime.now().astimezone().isoformat(), "launcher_pid": os.getpid()}
    temporary = path.with_suffix(f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(report, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lan-host", default="192.168.1.100")
    parser.add_argument("--postgres-service", default="")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    report_path = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "YourMettings/logs/last-start.json"
    try:
        config = load_config(args)
        with StartupMutex(config.root):
            write_report(report_path, "starting")
            Launcher(config, System(config), check_only=args.check_only).run()
            write_report(report_path, "ready")
        return 0
    except LaunchError as exc:
        print(f"\nОШИБКА — {exc}", flush=True)
        if exc.component != "Запуск":
            try:
                write_report(report_path, "error", exc.component)
            except OSError:
                pass
        return 1
    except Exception as exc:
        # Never echo driver exceptions, environment values or credential-bearing URLs.
        print(f"\nОШИБКА запуска ({type(exc).__name__}). Проверьте окружение Python и права на локальные службы.", flush=True)
        try:
            write_report(report_path, "error", "Запуск")
        except OSError:
            pass
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
