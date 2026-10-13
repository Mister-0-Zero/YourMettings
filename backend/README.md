# Backend YourMettings

Python 3.11+, PostgreSQL, локальный Ollama. Команды ниже выполняются из `backend/` в PowerShell.

```powershell
python -m venv .venv
& .\.venv\Scripts\python.exe -m pip install -e '.[test]'
Copy-Item .env.example .env
# Заполните DATABASE_URL, TEST_DATABASE_URL и OLLAMA_MODEL локально.
& .\.venv\Scripts\python.exe -m alembic upgrade head
& .\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
& .\.venv\Scripts\python.exe -m pytest
```

Swagger: http://127.0.0.1:8000/docs. OpenAPI: http://127.0.0.1:8000/openapi.json.

Для телефона используйте LAN-IP ПК и запуск с `--host <LAN-IP-ПК>`. При необходимости разрешите входящий TCP 8000 только для частной сети и локальной подсети в Windows Firewall. Не настраивайте проброс порта роутера.

Для одновременного доступа с ПК и телефона одним процессом:

```powershell
& .\.venv\Scripts\python.exe -m app.run --lan-host 192.168.1.100 --port 8000
```

Это слушает только loopback и выбранный LAN-IP, не VPN-интерфейсы. Подставьте актуальный IPv4 ПК. Если Windows блокирует подключение телефона, предусмотрен `scripts/allow_lan.ps1`: запустите его явно из Administrator PowerShell с актуальными `-LanAddress` и `-RemoteSubnet`. Он добавляет только правило входящего TCP для заданных адреса, подсети и порта, действует при любом профиле Windows и не отключает Firewall. Удалить созданное правило: `Remove-NetFirewallRule -Name YourMettingsBackendLAN`. В этой сессии правило автоматически не добавлялось.

Авторизация пока отсутствует: все клиенты работают с одним серверным тестовым пользователем. Используйте только доверенную локальную сеть. Мобильный клиент не получает credentials PostgreSQL или адрес Ollama.

Настройка `.env` читается независимо от текущей папки; секреты не коммитятся. Реальный тег проверьте через `ollama list`; новую модель backend самостоятельно не скачивает.

## PostgreSQL

Создайте отдельную роль приложения с LOGIN и две базы, принадлежащие ей: `yourmettings` и `yourmettings_test`. Не используйте роль postgres для обычной работы backend. Connection strings укажите в локальном `.env` (пример в `.env.example`). Миграции запускаются вручную до старта; приложение не создаёт таблицы самостоятельно. При старте идемпотентно создаётся фиксированный пользователь с отключённым входом.

Интеграционные тесты используют только PostgreSQL из TEST_DATABASE_URL и очищают таблицы этой базы. Имя тестовой базы должно оканчиваться на `_test` и отличаться от базы разработки. Если TEST_DATABASE_URL отсутствует, интеграционные тесты пропускаются; это не подтверждает готовность backend.

## Обработка и тесты

Один процесс Uvicorn, без `--workers` и без `--reload` во время генерации. Фоновая задача не держит транзакцию при вызове модели. После перезапуска незавершённые обработки становятся error и допускают явный повтор.

Текст блокируется во время генерации, разблокируется при ошибке до первого успеха и навсегда блокируется после первого успешного сохранения summary. Удаление summary сохраняет исходный transcript и постоянную блокировку.

```powershell
& .\.venv\Scripts\python.exe -m pytest -q
& .\.venv\Scripts\python.exe -m alembic check
# После запуска backend: реальная генерация (явная операция, не часть обычного pytest).
& .\.venv\Scripts\python.exe tests/e2e_real.py 'http://<LAN-IP-ПК>:8000'
```

E2E создаёт папку `E2E smoke` и короткий transcript в dev-БД, проверяет реальную генерацию, редактирование и удаление summary. Папка и заблокированный transcript остаются для проверки: их удаление не входит в MVP.

`requirements.lock` фиксирует проверенные версии окружения. Для воспроизведения: `python -m pip install -r requirements.lock`, затем `python -m pip install -e . --no-deps`. Конфигурация Ollama host может отличаться от стандартного порта 11434; проверяйте OLLAMA_HOST и локальную настройку сервера.

Контракт Flutter: `../docs/API_CONTRACT.md`. Статусы и ошибки фоновой генерации читаются через polling. Удаление папок отложено.

Основной сценарий Flutter: `POST /api/v1/transcripts/process` с `text`, `title`, `folder_ids` и стабильным `Idempotency-Key`. Ответ 202 содержит transcript_id для polling. Повтор исходного запроса возвращает текущее состояние без новой генерации; явный повтор после ошибки выполняется через `POST /api/v1/transcripts/{id}/process`.

Длинные транскрипты и нагрузка на GPU требуют отдельной проверки: ограничение символов API не гарантирует, что весь текст поместится в контекст выбранной модели. В первой версии используется контекст, настроенный в Ollama; автоматического разбиения текста пока нет.
