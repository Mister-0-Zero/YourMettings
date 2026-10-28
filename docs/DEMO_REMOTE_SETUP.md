# YourMettings: временный удалённый шлюз

Схема: телефон → доверенный HTTPS 194.117.80.169:443 → Caddy на VPS → VPS 127.0.0.1:18000 → исходящий SSH 22 с Windows → FastAPI 127.0.0.1:8000. PostgreSQL/GigaAM/Qwen остаются дома. AmneziaVPN не отключается; Windows-маршруты/Firewall не меняются. На VPS нет backend/моделей/БД и пользовательской истории. SSH-ключ не копируется; используется существующая локальная SSH-конфигурация alexey.

Выбор SSH вместо нового WireGuard-интерфейса позволяет обойтись штатным OpenSSH Windows и сохранить существующий VPN. На реальном маршруте обнаружены потери TCP и медленная передача крупных PCM-файлов; увеличены таймауты и отключена специальная DSCP-маркировка только SSH. Это не доказательство, что QoS был единственной причиной потерь. Сжатый AAC рекомендован для демонстрации.

## Состояние защиты

Email auth/миграция 0009 сохранены, без downgrade. Временно включён DEMO_ENABLED=true: сильный случайный DEMO_SECRET проверяется до чтения любого HTTP-тела, включая health. Нет ключа/неверный 401, просрочен 403; email endpoints заблокированы. Только отдельный пустой пользователь…0002; старые данные…0001 не открываются. Срок выбран 48 часов. API-ключ — заголовок X-Demo-Key, не URL/cookie/APK. Один Uvicorn process и bounded in-memory rate limits; масштабирование на несколько workers в этой схеме не предусмотрено.

VPS принимает только SSH 22 и IPv4 HTTPS 443. Административный Caddy API 2019 и SSH reverse 18000 слушают 127.0.0.1. Root/password SSH остаются запрещены. AllowTcpForwarding=remote разрешён только alexey, PermitListen=127.0.0.1:18000, GatewayPorts=no; IPQoS=none. Security updates и nftables включены.

Caddy 2.11.7 установлен из официального подписанного репозитория. [Let's Encrypt поддерживает IP-сертификаты](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability) профиля shortlived на 160 часов; Caddy автоматически продлевает их. Проверка TLS-ALPN-01 работает на 443, порт 80 не нужен. TLS-проверка на клиентах не отключается. Настройка сертификата — [официальный Caddy tls](https://caddyserver.com/docs/caddyfile/directives/tls).

На VPS нет буферизации запросов/ответов на диск. Access logging не включён; runtime namespace http.log исключён, поскольку proxy error log мог бы сохранить custom X-Demo-Key. Сохраняются lifecycle/ACME журналы. Backend в DEMO также отключает Uvicorn access log. Ключа нет в Caddyfile или VPS environment, он проверяется только дома. Не включать debug/log_credentials/полные HTTP логи для диагностики.

## Воспроизведение VPS

Конфиги: deploy/demo/Caddyfile, Caddyfile.bootstrap, setup-vps.sh, update-tunnel-qos.sh, update-tunnel-liveness.sh, close-public.sh. Скопировать **только эти файлы** в /home/alexey/yourmettings-deploy через существующий SSH/SCP, затем:

```sh
sudo sh /home/alexey/yourmettings-deploy/setup-vps.sh
# При необходимости обновления существующего блока SSH:
sudo sh /home/alexey/yourmettings-deploy/update-tunnel-qos.sh
# Обязательно для развёртываний до 28 октября: освобождение зависших listener.
sudo sh /home/alexey/yourmettings-deploy/update-tunnel-liveness.sh
```

setup создаёт приватные резервные копии в /var/backups/yourmettings-demo-<UTC>. Предварительно проверяет sshd -t, эффективный запрет root/password, ограничение listener и nft -c; правило SSH 22 сохраняется. Начальный шлюз отдаёт 503 bootstrap, не проксирует данные. Только после локальной проверки DemoKey и отдельного аккаунта активировать:

```sh
sudo caddy validate --config /home/alexey/yourmettings-deploy/Caddyfile --adapter caddyfile
sudo install -m644 /home/alexey/yourmettings-deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Повтор setup намеренно возвращает bootstrap503; не выполнять его во время демонстрации без окна обслуживания. Он не обновляет все пакеты системы и не развёртывает модели. Секрет на VPS не загружать. Не применять эти скрипты на чужом сервере без адаптации IP/user/имеющихся firewall правил.

## Windows: ключ и сервисы

В корне репозитория:

```powershell
# Локальная настройка .env и приватного файла, секрет не печатается:
.\backend\.venv\Scripts\python.exe deploy\demo\configure-access.py enable --hours 48
.\start-dev.ps1
# Если backend уже работает с иной конфигурацией, сначала дождаться задач
# и штатно перезапустить только свой процесс, не создавать дубль.
powershell.exe -NoProfile -File deploy\demo\install-tunnel-task.ps1 -StartNow
```

Ключ хранится в backend/.env и приватном `%LOCALAPPDATA%\YourMettings\demo-access-key.txt`, файл ограничен текущим Windows-пользователем. SMTP-пароль не является демонстрационным ключом. Существующие DB/SMTP/AUTH_SECRET настройки не удаляются; перед включением сохранена приватная копия .env вне Git.

BACKEND_LAN_ENABLED=false связывает FastAPI только с 127.0.0.1. TRUSTED_PROXY_IPS=["127.0.0.1"] доверяет SSH-источнику; Caddy всегда заменяет X-Forwarded-For своим remote_host, клиент не выбирает IP для rate limit. До 360 правильных запросов/мин на IP, до 10 ошибочных; глобальные лимиты и число buckets ограничены. JSON ограничен 2 MiB в backend; аудио ограничено 32 MiB и в backend, и в прокси.

Туннель использует текущий ключ/known_hosts с BatchMode и StrictHostKeyChecking=yes. Keepalive15×3 обнаруживает обрыв; reconnect3/6/12/24/30 секунд. Mutex предотвращает второй supervisor. Task YourMettings-Tunnel-428E48DB227F0DF5CD19 стартует при входе текущего пользователя, без сохранения Windows-пароля и без admin RunLevel. После перезагрузки Windows **нужен вход этого пользователя** и работающий backend; логон-задача не даёт доступ к GPU до входа и не предотвращает сон ПК. Caddy на VPS запускается systemd при boot. Глобальная ExecutionPolicy не менялась; задача ограниченно запускает проверенный локальный script с параметром процесса.

## Диагностика и восстановление

```powershell
.\start-dev.ps1 -CheckOnly
Get-ScheduledTask -TaskName 'YourMettings-Tunnel-*'
```

Логи/PID state туннеля: `%LOCALAPPDATA%\YourMettings\logs\tunnel-428E48DB227F0DF5CD19*`. Там нет demo key/.env. Секрет не выводить через диагностические команды. Отказ 403 expiry — продлить период/сменить ключ после решения владельца.401 означает отсутствие/ошибку ключа;502/503/504 при работающем сертификате — проверить ПК/SSH/upstream. Повторы аудио/операций идут с прежними IDs/ключами, локальные файлы сохраняются до подтверждения.

На VPS: `systemctl status caddy`, `ss -lntp`, `curl -fsS http://127.0.0.1:2019/config/logging`, ACME journal. Backend без ключа недоступен, это ожидаемо. Не включать полные HTTP error logs для поиска 502. Проверять отсутствие X-Demo-Key в журналах программно без печати ключа.

## Ротация и закрытие

Для быстрой блокировки публичного доступа при потере ключа остановить Caddy на VPS — домашние GPU-задачи при этом не останавливаются. Затем, когда backend можно безопасно перезапустить:

```powershell
.\backend\.venv\Scripts\python.exe deploy\demo\configure-access.py rotate --hours 48
# Перезапустить свой backend, передать новый приватный ключ устройствам.
```

Старый ключ прекращает действовать после загрузки новой конфигурации. Перезапуск посреди генерации переводит её в processing_interrupted по прежним правилам, поэтому сначала закрывать публичный вход и ждать задач. Не менять ключ во время активных пользовательских операций без необходимости.

После демонстрации:

```powershell
powershell.exe -NoProfile -File deploy\demo\remove-tunnel-task.ps1
```

```sh
sudo sh /home/alexey/yourmettings-deploy/close-public.sh
```

Этот script останавливает/отключает Caddy, удаляет только наше правило 443 и Match-блок туннеля, сохраняет SSH и посторонние изменения. Новый публичный вход закрыт. При желании вернуть email mode локально: `backend\.venv\Scripts\python.exe deploy/demo/configure-access.py disable`, затем свой backend restart. Это **не открывает LAN автоматически**; восстановить старые сетевые параметры можно отдельно по приватному pre-demo-config backup. Данные demo-пользователя не удаляются автоматически; очищать только синтетические тестовые записи через API до отключения режима.

## Что проверять перед показом

Не ограничиваться health. Нужны: доверенный TLS, запрет без/с неверным ключом, доступ только demo-данным, загрузка/повтор крупного фрагмента, complete/ASR/review/confirm/Qwen, один summary, сохранность прежних записей и восстановление после остановки SSH-child. Полный мобильный тест с сотовой сетью выполняется после доработки Flutter, см. FLUTTER_DEMO_HANDOFF.md. Результаты фактической проверки — DEMO_REMOTE_RESULT.md.

## Исправление восстановления после reboot/VPN — 28 октября 2026

После входа Windows туннель может подключиться раньше AmneziaVPN. Если маршрут затем меняется, клиент теряет связь, а VPS без server keepalive продолжает удерживать старый reverse listener 18000. Новая попытка получает `remote port forwarding failed for listen port 18000`. Это не конфликт с backend и не повод завершать все SSH-процессы.

Для managed Match User alexey теперь включены **ClientAliveInterval 15 / ClientAliveCountMax 3**. VPS проверяет клиента и освобождает умершие сессии примерно за 45–60 секунд; затем Windows supervisor подключается в очередную попытку (до 30 секунд). Клиентские ServerAliveInterval/CountMax также сохранены. Настройки VPN, маршрутов и Windows Firewall не меняются.

Применение к существующему серверу: загрузить `update-tunnel-liveness.sh` и выполнить его через sudo. Скрипт сохраняет backup, проверяет sshd -t и эффективные значения auth/listener/keepalive, затем reload SSH. **Ранее открытые соединения не наследуют новый keepalive**; они должны переподключиться. При первоначальном ремонте завершена только проверенная зависшая сессия нашего reverse listener, административные SSH-соединения сохранены. Не копировать PID из старого отчёта для последующих остановок.

PostgreSQL/GigaAM/Ollama/backend запускаются существующим ярлыком; задача туннеля AtLogon запускает только туннель. Если после reboot не запускали домашние сервисы, сначала нажать ярлык. При возвращении сети подождать завершения keepalive/reconnect, затем проверить HTTPS с ключом. Смена маршрута не требует повторной установки задачи.
