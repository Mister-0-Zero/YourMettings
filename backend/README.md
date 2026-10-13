# Backend YourMettings

Python 3.11+, PostgreSQL, локальный Ollama. Команды ниже выполняются из `backend/` в PowerShell.

```powershell
python -m venv .venv
& .\.venv\Scripts\python.exe -m pip install -e '.[test]'
Copy-Item .env.example .env
# Заполните DATABASE_URL, TEST_DATABASE_URL и OLLAMA_MODEL локально.
& .\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
& .\.venv\Scripts\python.exe -m pytest
```

Swagger: http://127.0.0.1:8000/docs. OpenAPI: http://127.0.0.1:8000/openapi.json.

Для телефона используйте LAN-IP ПК и запуск с `--host <LAN-IP-ПК>`. При необходимости разрешите входящий TCP 8000 только для частной сети и локальной подсети в Windows Firewall. Не настраивайте проброс порта роутера.

Авторизация пока отсутствует: все клиенты работают с одним серверным тестовым пользователем. Используйте только доверенную локальную сеть. Мобильный клиент не получает credentials PostgreSQL или адрес Ollama.

Настройка `.env` читается независимо от текущей папки; секреты не коммитятся. Реальный тег проверьте через `ollama list`; новую модель backend самостоятельно не скачивает.
