# Offline B: очередь и обработка — 01.11.2026

## Статус

Промежуточный B checkpoint после A (`7f27a6c`, отчёт `42c8801`). Это ещё не полная приёмка B: автоматические проверки production wiring выполнены, новая основная APK не установлена. Основной пакет HONOR0.1.5+6 не заменялся. По новому прямому решению пользователя USB/проверки телефона прекращены; дальнейшая B приёмка выполняется на ПК, HONOR/OEM этап перенесён на потом. API/БД/worker Flutter-агент не менял. Ветка mobile, merge/force-push не выполнялись.

## Реализовано

- Отдельный журнал каждого audio/text draft: frozen method/path/query/точный JSON/key до HTTP, неизменяемые receipts и привязанные серверные IDs. Editable input не подставляется в неизвестный старый запрос.
- Audio create → отдельный PUT новых automatic-параметров после replay старого create → immutable WAV по negotiated limits → ACK каждого номера/hash/размера → complete → ASR/pipeline polling. Text automatic использует существующий transcripts/process без processing_mode. Review использует существующий per-draft selection/candidate/atomic accept, без копирования источника.
- Automatic audio приводит к сохранённому Summary; в режиме review нужна проверка полного текста, фактического SHA и предупреждений стыков. Выключатель review доступен в настройках до/во время записи; FGS сохраняет настройки через scoped RPC после durable ACK, без конкурирующего UI-writer.
- auto_start_when_online=false отделён от review/automatic. Обычное завершение записи допускает один онлайн-check; недоступный backend оставляет новый offline draft без отложенного старта, если opt-in не дан. Принятые/неизвестные операции повторяются по сохранённым ключам.
- Native cooperative yield: UI просит освободить scope; передача прерывает HTTP, дренирует записи и освобождает lock. Нет TTL stealing. Планирование/хеширование PCM проверяет отмену порциями. Поздний HTTP-ответ не публикует данные после передачи доступа.
- Persisted attempt/next_attempt_at, exponential backoff+jitter и Retry-After; auth/conflict/404/410/422 останавливают сетевые повторы до явного действия. Неподтверждённое/принятое удаление хранится отдельно, источник сохраняется до подтверждения.
- Workmanager0.10.10: scoped unique one-off, persisted due scheduling, periodic15min fallback, foreground/resume wake, bounded runner и onTaskStopped. JobData содержит только scope_id. USB не требует NetworkType.connected. Перед HTTP проверяются immutable binding, текущий profile/account/origin, SecureStorage-key и auth/me. Worker микрофон не включает.
- UI состояния/ошибок/паузы/retry/result; обычный просмотр сохранённого summary, прежний WYSIWYG/сравнение/цвет/atomic accept. Receipt+summary_id сохраняются до удаления selection checkpoint. Уведомления о доставке ограничены20 краткими записями без содержимого summary, не являются локальной библиотекой.

## Закрытые ошибки независимого core review

1. Ответ upload содержит chunk.sha256, входной query называется content_sha256. Guard/fixture исправлены; также проверяются sequence_number и byte_count. Тест lostACK использует фактическую форму ответа.
2. Complete и input_at_boundary первоначально писались раздельно. Теперь frozen complete + снимок принятых параметров фиксируются одним repository.update. При старом missing boundary приложение оставляет saved_with_changes, не восстанавливает «отправленный» ввод из текущих правок. Проверены поздние правки после lostACK и искусственный manifest ровно в прежнем crash window.
3. Состояние manual_ready могло скрыть незавершённый accept от очереди. Checkpoint сохраняет accept_pending/result_pending одновременно с намерением/receipt; перезапуск повторяет тот же выбранный candidate/body и не требует второго нажатия.

## Выполненные проверки

Собственные проверки Flutter-агента на этом checkpoint:

- flutter analyze: **No issues found**.
- Полный flutter test: **367 passed** (343 прежних +24 новых queue/manual tests).
-12 native JVM JUnit passed, включая cooperative yield/no-steal/stale-token rejection. Kotlin compile/runtime jar Gradle tasks прошли. Сам Gradle test launcher на этой Windows имеет ранее описанную Unicode-classpath проблему; JUnit запущен напрямую с assertions из скомпилированных классов, штатный test task успешным не объявляется.
- HTTP-fake/clock: lostACK create/PUT/chunk/complete/selection/candidate/accept; новый input после accepted/unknown запроса; сохранённый receipt до callback; зависший HTTP + создание второго audio draft <3s; lateACK не меняет revision; opt-in; auth/404/410/409/422; persisted Retry-After/date/backoff; чужой active scope; immutable DELETE query; atomic boundary/restart.

Android arm64 debug build успешен. APK0.1.6+7: mobile/build/app/outputs/flutter-apk/app-debug.apk,126152207bytes, SHA256 **9AA19A02A5E27048F071CF3DB8D3E8A90881BCB215A44FCF0F2DBA23823FE38A**. Это промежуточный B артефакт; не прежний A APK с тем же номером. Установки на телефон не было. Последующие интеграционные результаты будут внесены после завершения проверок. Логи в mobile/build ignored; ключи/пользовательские встречи в Git не включены. Backend448/471 tests и серверные ASR/Qwen smoke — данные других агентов, не собственные проверки Flutter.

## Осталось до завершения B

- Принять READY обновлённого backend и актуальный API_CONTRACT для явно подтверждённого review discard_unprocessed; текущий код честно сохраняет/приостанавливает partial review, endpoint не выдумывает.
- Дополнить boundary/retry/cancel/delete и scheduler/widget matrix, провести final scope/credentials/WorkManager/UI review.
- Выполнить synthetic real-backend audio→ASR→Qwen→saved Summary и нужные restart/replay проверки production queue. Не использовать пользовательские встречи.
- Довести desktop E2E и итоговый APK до готовности. Установка основной APK и HONOR-приёмка перенесены на потом по прямому указанию пользователя; к телефону не обращаться. Текущие unit/JVM результаты не объявляют Doze/reboot/OEM background гарантии проверенными.

Flutter-агент подагентов в B не запускал. Независимый review организует координатор.
