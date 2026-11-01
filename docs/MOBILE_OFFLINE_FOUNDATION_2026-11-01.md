# Основа offline-черновиков и локального аудио — 01.11.2026

**Проверенный промежуточный checkpoint. Production UI/runner ещё не подключены.** Общая задача offline → ASR → Qwen → сохранённый Summary продолжается. Коммит реализации: [`75003b5`](https://github.com/Mister-0-Zero/YourMettings/commit/75003b579870f532c39e8bf52e63a55e032ee893), исправление конкурентной подготовки: [`9f4de77`](https://github.com/Mister-0-Zero/YourMettings/commit/9f4de7768460e09c8f6fa514b2061afc05bf27e2), ветка `mobile`. Backend-код, рабочая БД и публичный доступ не менялись.

## Что реализовано

- Независимые audio/text manifests в `scopes/<verified-scope>/drafts/<localUUID>/`. Локальный ID не зависит от server session/transcript ID. Репозиторий восстанавливает список из manifests, проверяет scope/schema/revision; повреждённый документ и WAV не удаляются. Единого перезаписываемого аудиочерновика новый механизм не использует.
- Editable input отделён от frozen method/path/точного JSON/key. Существующие requests, receipts, привязанные server IDs и опубликованный wire-plan нельзя незаметно заменить при правке. Opt-in автоматического старта хранится отдельно и по умолчанию false.
- Кэш дерева папок и шаблонов с временем получения/версией в том же scope. Неудачное обновление сохраняет последний корректный снимок; чужой scope отвергается. Это метаданные, не локальная библиотека summary.
- Read-only staging старого текстового PendingRequest/AcceptedOperation, точного key/body/ID и отдельный архив generation selection/accept checkpoints. Старые файлы сохраняются; импорт пока dispatch-blocked. Изменившийся источник миграции не перезаписывает уже созданное соответствие.
- `LocalAudioCapture`: PCM16 little-endian, mono, 16 kHz; durable manifest до открытия микрофона, без HTTP/session ID/кэша серверных лимитов. Pause/resume/stop, последовательный drain буфера, восстановление фактического количества сохранённых байтов после смерти процесса без самозапуска микрофона. Встроенная граница локального хранения — 4 часа; она не выдаётся за серверный upload limit. Ошибка записи/переполнение буфера останавливает capture с понятным error code; сохранённый префикс не удаляется.
- `AudioWirePlanner`: после остановки capture формирует WAV из неизменяемого PCM по реально полученным chunk target/max seconds/max bytes/max chunks. Ищет паузу после target, сохраняет последовательность, все PCM samples и временную шкалу; sub-ms хвост не отбрасывает. Каждая подготовка использует отдельное пространство имён `wire-<plan SHA>-<sequence>.wav`; plan SHA зависит от исходника, версии алгоритма и лимитов. Файлы публикуются до фиксации плана, HTTP разрешается только после committed plan. Native publish запрещает заменять существующий WAV; оставшиеся после сбоя файлы повторно используются только при точном совпадении bytes/SHA. После этого нельзя пересегментировать потенциально принятые bytes/sequence/SHA, даже при новых лимитах. Несоответствие SHA останавливает передачу с сохранением источника.
- Native `queue_owner`: общий JVM-реестр между Flutter engines + exclusive kernel FileChannel lock. Stable lock inode, owner token и engine identity. Публикация JSON/WAV, удаление и append PCM проверяют token под тем же mutex, что release/detach/acquire. PCM append имеет expected offset, fsync до ACK; прежний engine не может дописать файл нового владельца. Уникальный tmp старого владельца не может заменить committed manifest. Подтверждённое удаление имеет внешний durable cleanup marker, который переживает частично удалённую директорию.
- Workmanager **0.10.10** закреплён; добавлен отдельный device prototype. Версии шаблонов доступны в `SummaryTemplate.version` / `ProcessingOptions.expectedTemplateVersion`; смена шаблона сбрасывает прежнюю версию, legacy JSON без версии сохраняет старую форму.

Основные файлы: `mobile/lib/services/drafts/`, `mobile/packages/queue_owner/`, четыре новых test-файла, `mobile/tool/queue_probe_main.dart`. Репозиторий сам сериализует create/update/freeze: оборачивать эти вызовы во второй `serialized()` нельзя. В будущем runner удерживает lifetime lease и сам abort/drain-ит HTTP перед release; один Dart Future-tail не заменяет междвижковое владение.

## Фактические проверки Flutter и JVM

- **`flutter analyze`: No issues found.**
- **Полный `flutter test`: 315 passed до последнего concurrency-фикса.** На предыдущем опубликованном этапе было 288; этот прогон включал 27 новых проверок. После изменения wire paths/guard отдельно повторены **16 целевых тестов** repository + capture/wire/version, включая новый управляемый concurrency regression. Все прошли. Остальной полный набор после локального delta повторно не запускался; analyze и APK сборка повторены на окончательном коде.
- Проверены независимые две аудио- и две текстовые записи, cold reload, lost-create frozen payload + последующие правки input, optimistic CAS, сбой commit/delete, повреждённый manifest, разделение scope, старый source changed, неопределённый legacy submit, принятый transcript без нового POST, preservation selection/accept receipt.
- Capture/wire проверки используют синтетический поток: offline start без HTTP/server ID, pause/resume/stop drain, восстановление durable PCM, отказ permission, точное восстановление всех PCM samples из WAV, таймкоды/контейнер/SHA, неизменяемый план при новых limits, запрет дописывания после его публикации, disk-failure с сохранением префикса. Это автоматические проверки механизма, не реальная запись production UI на HONOR.
- **9 native JUnit passed**, assertions включены: engine exclusion/kernel lock, stale release/publish, scope traversal/lock protection, PCM offset/fsync/stale-owner rejection и запрет перезаписи опубликованного WAV текущим owner. Gradle compile tasks успешны. Сам `testDebugUnitTest` в этой Windows не смог запустить GradleWorkerMain через Unicode classpath; тесты выполнены непосредственно `org.junit.runner.JUnitCore` на тех же скомпилированных классах/classpath. Штатный Gradle test task успешным не объявляется.
- `git diff --check` успешен. Проверены файловые Markdown-ссылки отчёта/плана/индекса; backend-only ссылки импортированного контракта направлены на существующие файлы опубликованного commit `4708232`, требования API не переписаны.

Локальные логи в игнорируемом `mobile/build/`: `offline-full-tests.log`, `offline-wire-concurrency-tests.log`, `offline-analyze.log`, `queue-owner-compile.log`, `queue-owner-jvm-direct.log`. Сырые логи/пользовательские данные в Git не добавлены.

## Исправление по checkpoint review

Ревью подтвердило P2: два planner instances могли одновременно прочитать отсутствие плана, затем поочерёдно писать общие `wire-000000.wav`. Проигравший замечал committed plan лишь после перезаписи WAV. Это нарушало frozen hash/unknown-ACK replay. В `9f4de77` результаты подготовки изолированы по plan SHA, победивший manifest выбирается revision CAS, а опубликованные WAV неизменяемы и на уровне native publish. Проигравшая подготовка оставляет только собственные неиспользуемые файлы в том же draft; они не идут в HTTP и удаляются вместе с draft после разрешённого cleanup. Вложенный `serialized()` не добавлялся.

Новый тест двумя разными planner instances удерживает первую запись A, ждёт постановки первой записи B с другими limits, затем освобождает A. После завершения обоих вызовов ровно один plan committed, второй получает DraftRevisionConflict. Проверены SHA256 и длина каждого файла победителя, точное восстановление всех PCM samples и повторное открытие того же плана. Дополнительно native JUnit запрещает замену WAV текущим owner. Capture также повторно проверяет frozen intent/plan перед durable переходом в capturing, а planner не коммитит при уже возобновлённом микрофоне.

## Отдельный HONOR probe

На HONOR 400 установлен **только отдельный** `dev.yourmettings.queue_probe`, не промежуточная YourMettings. Реальный Android WorkManager поднял новый headless Flutter engine. Результаты:

| Проверка | Результат |
|---|---|
| Callback действительно в отдельном headless engine | true |
| Worker читает synthetic nonce, записанный UI в отдельный SecureStorage namespace | true |
| UI не получает ownership, пока worker владеет lease | true |
| UI получает ownership после drain/release worker | true |
| Token-checked atomic JSON publish revision 1 → 2 | true |

Nonce — искусственное значение, не demo-ключ. Итог `passed=true`. После сверки package и SHA256 собственного APK прототип удалён; основная YourMettings снова открыта. ADB отдельно подтвердил основную **0.1.5 / versionCode 6**, тестового пакета больше нет. Пользовательские данные основного приложения этим probe не очищались/не переносились. Новое native PCM append покрыто JVM-тестами; отдельной физической записью через production UI оно в этом checkpoint ещё не проверялось.

Локальный результат: `mobile/build/queue-probe-device-result.json`. SHA256 probe APK: `71B7DEA1A3B110B965ED751CA20553BD41CFB35E5A57E7ADE3EAD6E8ED6C79F0`.

## Android APK

Финальный debug ARM64 `flutter build apk --debug --target-platform android-arm64 --no-pub` успешен. Промежуточная версия **0.1.6+7**, файл `mobile/build/app/outputs/flutter-apk/app-debug.apk` (локально `D:/programming/VSCode/project/YourMettings-mobile/mobile/build/app/outputs/flutter-apk/app-debug.apk`).

SHA256: `6706F053C4770D20856A3F27388B6B908206C61BAD51158C66DF15C4DE0F93A2`.

AAPT подтвердил package/version. Apksigner verify успешен, v2 true; signer SHA256 `79977dbf53974bd6f768f78e0b4b46c25a63fec6e7dd925e0b8413ab33f993f5`. **На основной пакет телефона этот APK не устанавливался и как готовая offline-версия пользователю не выдавался.**

Сборка предупреждает, что `workmanager_android` пока использует Kotlin Gradle Plugin и будущие версии Flutter потребуют миграции plugin. В текущем установленном Flutter сборка работает; обновление Flutter потребует повторной проверки совместимости. Проверки/предупреждения не отключались.

## Контракт и оставшаяся работа

API взят из backend **`4708232`**, реализация **`faf09db`**, schema **0011**. [Контракт](API_CONTRACT.md), [handoff](FLUTTER_OFFLINE_PIPELINE_HANDOFF.md). Backend-агент сообщил 448 backend-тестов и real synthetic ASR→Qwen→saved Summary/retry/cancel/restart: эти результаты не выдаются за наши Flutter integration tests.

Авторизованный USB API: host `127.0.0.1:8001`, phone `127.0.0.1:8000` через reverse. Локальный доступ ограничен прежним сроком **01.11.2026 17:07:46 МСК**, ключ уже provisioned в USB vault. USB не отменяет авторизацию. На текущей проверке без ключа `/health` и `/api/v1/folders` ответили 401 — listener работает, это не доказательство сетевого разрыва. Публичный expired доступ и конфигурацию backend в этом этапе не меняли.

**Следующий обязательный checkpoint:** production cold-offline graph/cache и UI независимых черновиков, foreground capture service с local ID+scope+instance, единый dispatcher ownership и безопасный legacy audio/WAV handoff. Затем exact replay/parameters/upload/complete/polling, review/manual flow и automatic ASR→Qwen→**уже сохранённый** Summary без дополнительной галочки, persisted opt-in/backoff/Retry-After/WorkManager, cancel/delete/scope/auth pause. После интеграции нужны общий suite, APK и полноценная HONOR offline/restart/background/automatic приёмка. Текущий core эти сценарии целиком ещё не реализует.

План и актуальный checkpoint: [MOBILE_OFFLINE_QUEUE_PLAN_2026-11-01.md](MOBILE_OFFLINE_QUEUE_PLAN_2026-11-01.md). Это граница проверенного этапа, а не завершение всего поручения.
