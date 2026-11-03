# План общей очереди черновиков и ASR → Qwen

Дата: 1 ноября 2026, МСК. Статус: **основа плана принята координатором**, реализация следующего этапа авторизована; на момент папочного коммита pipeline ещё не реализован. Прямое новое поручение об offline заменяет прежнее ограничение MVP. Текущий этап папок описан в [MOBILE_FOLDERS_2026-11-01.md](MOBILE_FOLDERS_2026-11-01.md). До согласования backend-контракта не добавляются новые endpoints и автоматические переходы.

## Что уже есть и что мешает offline

- `mobile/lib/services/recovery_store.dart`: один активный текстовый черновик, PendingRequest с неизменяемыми key/draft, AcceptedOperation с transcript ID. Это не коллекция независимых текстовых встреч.
- `mobile/lib/services/audio_draft_store.dart`: отложенные аудиочерновики индексируются обязательными sessionId/transcriptId; сохраняется review/обработка, а не отдельный полный offline audio spool каждого черновика.
- `mobile/lib/features/recording/audio_engine.dart`: prepare делает POST с key/parameters, получает server ID и лимиты, после чего разрешается capture. Поэтому без сервера сейчас микрофон не стартует.
- `audio_journal.dart` и `pcm_chunk_writer.dart`: manifest, WAV, sequence/hash/ACK и один владелец. `recorder_coordinator.dart` использует server ID также как service owner; команды проверяют scope, service instance, session ID. Простая подмена id локальным значением нарушила бы эти проверки.
- `main.dart` и `services/recorder_context.dart` уже разделяют данные по `sha256(origin|access_mode|accountId)`. Эта граница сохраняется; USB/HTTPS одного аккаунта не объединяются автоматически.

## Минимальная модель

Один формат долговечного задания для audio/text, отдельная директория каждого черновика внутри существующего scope: `drafts/<localDraftId>/`. **localDraftId стабилен с создания до удаления**, независимо от появления serverSessionId/transcriptId/summaryId. Серверные идентификаторы — отдельные nullable поля, никогда не заменяют локальный owner.

Авторитетен manifest конкретного черновика; индекс каталога восстанавливается из manifests, а не служит второй расходящейся копией содержимого. Запись сериализована; снимок подтверждается UI только после durable write через tmp/flush/rename. Ключи доступа остаются в SecureStorage, в manifest их нет.

В manifest нужны только незавершённые данные: тип/локальный ID/scope/ревизия, редактируемый input, параметры/папки/шаблон, явный durable autoStart opt-in и его снимок настроек, состояние шага, замороженный request+idempotency key, принятые серверные IDs/квитанции, attempt/nextAttemptAt/error classification. У audio дополнительно capture state, формат, лимиты/их источник, chunks (путь/sequence/hash/размер/ACK), handoff/delete markers. Завершённые summary не превращаются в локальную библиотеку встреч.

**Редактируемое состояние и замороженный запрос различаются.** Если ответ POST потерян, правка названия/папок/шаблона не меняет старый payload под прежним ключом. Сначала exact replay старого создания → сохранение полученных IDs; затем только предусмотренный контрактом следующий шаг с актуальными правками. Нельзя выбросить новые правки или завести второй server session ради неизвестного ответа.

## Подэтапы реализации

1. **Хранилище и безопасная миграция без изменения pipeline.** Ввести независимые audio/text записи и список «Черновики», переместить существующие draft/checkpoint в соответствующий scope. Старый active journal, server IDs, keys, frozen payload, WAV и ACK сохраняются. Миграция идемпотентна: сначала durable mapping/manifest, затем проверка целостности, только после неё переключение ссылки владельца. При сбое старое состояние остаётся пригодным для восстановления. Не мигрировать чужие/unscoped файлы в текущий аккаунт молча.
2. **Старт микрофона offline.** Создать локальный draft и durable manifest до запуска foreground microphone service; команды содержат localDraftId + scope + service instance. Capture не зависит от HTTP POST. Формат и безопасные границы offline chunks нужно зафиксировать в актуальном контракте. Для уже подтверждённого профиля микрофон должен стартовать даже без кэша прежней аудиосессии; HTTP/получение session ID не являются условием старта. Нужен согласованный встроенный PCM/WAV профиль и безопасные fallback границы, а кэшированные лимиты — лишь дополнительная информация. При несовпадении фактических upload limits до первой отправки формируется durable детерминированный wire-plan/пересегментация из сохранённого исходного PCM. После первого неизвестного chunk ACK bytes/sequence/hash этого wire-plan неизменяемы. Не терять уже записанное при отказе сервера. Диск/permission проверяются локально. Загрузка может догнать capture после появления связи.
3. **Очередь передачи и восстановление.** Frozen create request → exact replay → durable server IDs → upload неизменяемых bytes/sequence/hash → ACK → complete → polling существующего ASR ID. Пока ответ неизвестен, не переходить к новому key/заданию. Задачи сериализуются одним диспетчером, запись микрофона имеет одного владельца; очередная встреча не блокируется незавершённой передачей предыдущей.
4. **Автоматический переход ASR → Qwen.** Только явный сохранённый opt-in конкретного draft с валидными выбранными папками/шаблоном. При готовом ASR замораживается один confirm/generation request согласно новому контракту; после перезапуска восстанавливается по тем же IDs/ключам. Без папки или при недоступном шаблоне — понятный статус «Нужен выбор», локальный материал сохранён. **Принятое решение:** automatic при выключенном просмотре транскрипта должен автоматически получить и сохранить итоговый summary в выбранной папке, без промежуточного кандидата/галочки. Review по умолчанию сохраняет прежний ручной сценарий. Per-draft autostart false по умолчанию. Точные поля/статусы автоматического сохранения готовит backend; клиент не подменяет их самовольной цепочкой candidate/accept.
5. **Android background и итоговая приёмка.** Реализовать immediate foreground/resume triggers и durable Android schedule, а не только продолжение при открытии экрана. Предлагаемый минимальный адаптер и границы ОС описаны ниже. Capture остаётся штатным foreground microphone service; worker не запускает микрофон из фона.

## Предложение по Android scheduler и единственному владельцу

Это архитектурное предложение для согласования следующего этапа, **не добавленная зависимость**. В установленном `flutter_foreground_task 11.0.3` repeat связан с работающим service; текущий `audioServiceCanStop` завершает его в том числе на transcribing/review. Поэтому существующий TaskHandler не даёт долговечного расписания после остановки записи.

Минимальный предлагаемый scheduler — native AndroidX **WorkManager (`androidx.work:work-runtime`)**, маленький Kotlin adapter и headless entry point общего Dart-диспетчера. Это отдельная Android-зависимость; точная стабильная совместимая версия фиксируется при реализации. WorkManager предназначен для persistent work, запускаемого при выполнении constraints; обычный worker ограничен временем выполнения, поэтому обработка делится на короткие upload/poll/confirm проходы с checkpoint и корректной остановкой. [Официальный API WorkManager](https://developer.android.com/reference/androidx/work/WorkManager).

Предлагаемое поведение: foreground/resume немедленно будят dispatcher, а unique one-time work сохраняет ближайший retry вне UI; periodic work служит страховкой пока есть ожидающие задания. Дубли scheduler подавляются unique work, завершённые/blocked задачи не опрашиваются бесконечно. Periodic имеет минимум **15 минут**, время запуска неточное и может откладываться Doze/оптимизацией батареи. Это фоновое продолжение без открытого экрана, но не обещание запуска сразу после появления связи. После force-stop восстановление проверяется при следующем открытии. [PeriodicWorkRequest](https://developer.android.com/reference/androidx/work/PeriodicWorkRequest).

**Готовность = доступен наш backend соответствующего scope**, проверяется коротким авторизованным запросом на его origin. Наличие Wi-Fi/mobile Internet/validated network не является обязательным условием: USB reverse/localhost может работать и без интернета. Не ставить обязательный Internet network constraint на worker. Connectivity callback допустим как дополнительный сигнал, а пропущенное USB-подключение обнаруживается retry schedule/foreground wake.

**Unique WorkManager и Dart `_queue` сами по себе не защищают от второго engine/isolate.** Предлагается один native owner broker на scope: process-wide mutex/реестр владельцев для нескольких Flutter engines в одной JVM плюс advisory exclusive FileChannel lock для возможного второго процесса. Lock-файл стабилен, не переименовывается вместе с manifest; handle удерживается весь период владения. Все пути записи обязаны использовать broker, старый token не даёт права записи. FileLock сам по себе не является mutex для потоков одной JVM, а advisory lock требует кооперации всех писателей. [Официальный FileLock](https://developer.android.com/reference/java/nio/channels/FileLock).

Когда capture service уже владеет dispatcher, UI/worker передают ему wake/commands; второго upload/writer не запускают. После остановки capture — durable checkpoint, drain текущего запроса/неизвестного ACK, подтверждённая передача владения и release lock. Только затем foreground runner либо headless worker получает новый owner token и перечитывает manifest. После смерти процесса OS lock освобождается, новый owner сначала восстанавливает незавершённый frozen request. TTL-файл без kernel lock и тихое «воровство» ownership не подходят.

Параметры background job содержат только scope/local ID и binding, никаких секретов. Job использует immutable scope-specific binding, а не глобальный последний `audio-context.json` от другого профиля. Перед отправкой проверяется identity; credential читается через штатный vault по нужному origin. Headless доступ к SecureStorage/регистрации plugins и graceful worker stop должны пройти отдельный прототип до включения autostart. Если этот адаптер окажется сложнее поддерживаемого Flutter WorkManager-плагина, решение сравнивается на этом прототипе; оба подхода обязаны использовать тот же owner broker и manifests.

Acceptance scheduler: worker действительно продолжает передачу после закрытия Activity/остановки capture; foreground+worker+FGS одновременно претендуют на scope и только один пишет/upload; kill между ACK/checkpoint/handoff; повтор после перезагрузки; USB с выключенным Internet; Doze/stop worker; force-stop с последующим открытием. Никакой заявки о гарантированной точной задержке или работе принудительно остановленного приложения.

## Освобождение диктофона без потери bytes

Каждый audio draft владеет своим spool с момента старта; не требуется опасное копирование единственного active-audio в последний момент. Для legacy active-audio нужен crash-safe handoff: durable intent со старым/новым owner, остановка writer и его подтверждение, проверка всех WAV/hash/ACK, атомарное переключение pointer/repository, проверяемое восстановление после каждого шага. Удаление старого пути допускается только после подтверждённого владения новым. UI не пишет manifest одновременно с engine; команды старого service instance/чужого scope отклоняются. Непереданные chunks и незаписанный хвост нельзя оставить в одном переиспользуемом active journal и начать там следующую встречу.

## Кэш и повторные попытки

- Кэшировать дерево папок и нужные данные каталога шаблонов только в scope последней проверенной учётной записи. Хранить дату получения, показывать устаревание. Не подменять отсутствующую папку/шаблон произвольным значением. Проверка сервером перед запуском остаётся обязательной; выбранные локальные IDs не исчезают при неудачном refresh.
- Offline-запись для уже известного scope допустима даже при истёкшем доступе, но отправка блокируется до восстановления авторизации этого же scope. Для неизвестного аккаунта не угадывать владельца и не пересылать материал в другой профиль.
- Сетевые ошибки/timeout/5xx: ограниченный exponential backoff с jitter и сохранённым nextAttemptAt; после неизвестного POST exact replay; после принятых IDs только предусмотренные GET/retry. 429 соблюдает Retry-After, без параллельного шторма из всех drafts.
- 401/403/истёкший demo — auth blocked, материал сохранён; изменение credentials не меняет owner. 409 idempotency conflict/несовместимые параметры — blocked, без автоматического нового key. Busy/processing conflicts повторяются лишь если это прямо допускает контракт. 404/410 удалённого источника не превращаются в молчаливое повторное создание. 422/недоступные папки/шаблон требуют правки пользователем. Storage failure не объявляется успешным сохранением.
- Отмена opt-in предотвращает новые шаги; уже отправленный неизвестный запрос сначала сверяется. Удаление имеет отдельный durable intent и следует доступным серверным состояниям удаления. Локальные данные удаляются только после необходимых подтверждений/безопасного отказа от чисто локального draft.

## Проверки, без которых этап не завершён

- Две offline аудиовстречи и два текстовых черновика независимы; новая запись не затирает непринятые bytes первой.
- Offline microphone → pause/resume → выключенный экран → restart/восстановление, полный хвост PCM и sequence/hash без разрывов.
- Потерянный create reply → правка title/folders → kill/restart: ровно одна серверная сессия, exact replay старого payload, новые правки сохранены отдельно.
- Сбой в каждой точке handoff/миграции/ACK/index write, disk full и испорченный manifest: ни удаления единственного WAV, ни присвоения чужого owner.
- Сеть пропадает между каждым шагом ASR/Qwen; один confirm/generation, polling по прежнему ID, opt-in и настройки переживают restart. Без opt-in нет запуска Qwen.
- Пропали/переименованы вложенные папки, удалён шаблон, 401/429/409/404/422, concurrent text edit; никакого unconditional fallback.
- Account/origin switch при очереди и delayed commands: старые данные остаются в старом scope; запросы/секреты не уходят на новый origin; legacy операции не смешиваются.
- Повторное открытие готового результата и очистка исходного draft только после требуемого подтверждения; существующие compare/atomic accept и папочные действия не регрессируют.

## Контрактные точки для согласования

Нужны окончательные правила offline capture limits/формата и wire-plan, frozen create payload и последующих editable confirm parameters; идемпотентность automatic ASR→Qwen→сохранённый summary и классификация допустимых retry; принадлежность/удаление сессий до/после Qwen; точные поля режима review/automatic и статусы результата. Если backend выбирает единый серверный pipeline, мобильная очередь отслеживает его operation IDs и не дублирует шаги ручными POST.

Это план последовательной реализации, не отчёт о существующей поддержке offline. Новые зависимости/endpoint/фоновые гарантии данным документом не вводятся.

Уточнения координатора к принятому плану: cold offline launch ранее подтверждённого scope открывает локальный UI без обязательного auth-запроса; старые pending selections/accept receipts не импортируются как новые submit. Backend следующего этапа готовит контракт в отдельном клоне `C:/Users/Алексей/Documents/Codex/work/YourMettings-backend-offline`; production deployment и миграции — после общего ревью. Мобильный агент backend-код/конфигурацию в этом клоне не меняет.


## Исторический checkpoint основы — 01.11.2026, 16:50 МСК

**Активная задача — полный offline/pipeline этап, а не старый вопрос о demo-ключе.** Backend готов: `faf09db`, схема `0011`, deployment report `4708232`. По сообщению backend-агента: 448 тестов и реальная synthetic ASR → Qwen → saved Summary. Это его проверки, не проверки Flutter. Локальный API `127.0.0.1:8001`, `adb reverse tcp:8000 tcp:8001`; авторизованный USB-сеанс до **01.11.2026 17:07:46 МСК**. Ключ уже provisioned в USB SecureStorage; просить вводить истёкший внешний ключ не нужно. Срок публичного доступа/конфигурацию backend Flutter-агент не меняет.

На HONOR остаётся опубликованная **0.1.5+6** с проверенными папками (`95c23d5`). Текущая **0.1.6+7** — незавершённая разработка, в основное приложение на телефоне ещё не установлена.

Готовая основа (пока без production UI/runner):

- `mobile/packages/queue_owner/`: междвижковая JVM-регистрация + kernel file lock; token-checked atomic publish/cleanup и уникальные tmp, защита при engine detach. Append-only PCM расширение проверено JVM-тестами: offset CAS, fsync, stale-owner rejection.
- `mobile/lib/services/drafts/draft_record.dart`, `draft_repository.dart`: независимые manifests по stable local UUID, scope/revision CAS, отдельный editable input и frozen точный JSON/key, receipts/IDs, crash-safe cleanup marker.
- `catalog_cache.dart`: scoped last-good folders/templates и версии шаблонов. `legacy_draft_import.dart`: только read-only staging старого PendingRequest/AcceptedOperation и архива selection/accept receipts; источники сохранены, dispatch заблокирован до handoff.
- `ProcessingOptions.expectedTemplateVersion`, `SummaryTemplate.version`; Workmanager **0.10.10** закреплён. `tool/queue_probe_main.dart` — отдельный тестовый пакет, не подмена основного приложения.

Фактические текущие результаты и ограничения публикуются в [отчёте основы](MOBILE_OFFLINE_FOUNDATION_2026-11-01.md). Девять native JUnit прошли через прямой запуск скомпилированных классов с assertions: штатный Gradle test launcher на этой Windows не нашёл GradleWorkerMain при Unicode classpath; тестовый task целиком успешным не объявляется.

Отдельный APK `dev.yourmettings.queue_probe` на HONOR подтвердил: новый headless engine, чтение synthetic UI-written SecureStorage, взаимное исключение UI/worker, передача ownership после drain, **token-checked atomic publish**. Все пять проверок true. Прототип удалён после сверки package/hash; основная 0.1.5+6 сохранена. Результат локально `mobile/build/queue-probe-device-result.json`, без пользовательских данных/ключей; это проверка механизма, не полная offline-приёмка.

**Подэтап на момент этого checkpoint:** `local_audio_capture.dart` — локальный PCM16 mono/16kHz с durable manifest до микрофона, stable local ID, pause/resume/stop/recover; ещё не подключён к foreground service/UI. PCM/deterministic wire-plan по negotiated limits проверены автоматическими тестами; гонка между planner instances исправлена изолированными immutable WAV (9f4de77), 16 целевых проверок прошли после фикса. Далее обязательно: production cold-offline graph/cache; FGS-команды local ID+scope+instance и единый владелец; safe legacy audio/WAV handoff; независимые audio/text drafts UI; runner exact replay → parameters ACK → immutable upload → complete/poll; automatic ASR→Qwen→saved Summary без дополнительной галочки, review/manual flow; persisted opt-in/backoff/Retry-After и WorkManager/resume triggers; cancel/delete и scope/auth pause; analyze/full tests/APK/HONOR offline+restart+background+automatic приёмка. Вложенный `serialized()` вокруг repository.create/update/freeze запрещён: эти методы сами сериализуют мутации.

Этот checkpoint не объявляет всю задачу завершённой. Следующие изменения и результаты обновляются здесь и в итоговом отчёте; после успешных проверок этапов — commit/push `mobile`.

## Исторический checkpoint A — UI/FGS завершён 01.11.2026

Реализация **7f27a6c**. Полный отчёт: [MOBILE_OFFLINE_UI_FGS_2026-11-01.md](MOBILE_OFFLINE_UI_FGS_2026-11-01.md). **343 Flutter tests,11 native JUnit, analyze и Android build успешны.** Основная HONOR остаётся0.1.5+6; промежуточная0.1.6+7 не установлена.

Подключены production cold-local graph, независимые text/audio drafts UI/cache/options/version/review/opt-in, foreground LocalAudioCapture и native ownership. Legacy local-only text активируется crash-safe; pending/accepted/selection/accept receipts и прежние audio/WAV/ACK доступны через dispatch-blocked legacy bridges/старого владельца, не новые submit. Close дренирует foreground/restore проверки.

Поздний реальный blocker **ArgumentError local-recorder** закрыт: стек точно указал SharedPreferences Android NativeInterop при Activity recreation с живым FGS. Служебный launch pointer перенесён в token/engine/nonce-checked native `capture-ticket.v1`; getData/saveData из нового recorder удалены. Это только microphone pointer без секретов: queue jobs обязаны использовать собственный scoped immutable queue-binding.json. Restore error известного scope не превращается в запрос повторного подключения. Resume/autosave P2 также закрыта.

HONOR isolated production probe доказал cold local home при пустом vault/недоступном сервере, HTTP-free mic, pause/resume/Home/stop, две отдельные аудиозаписи, force-stop/cold recovery/explicit append с сохранением prefix SHA, настоящий Activity recreation при том же process/service instance, два разных текста (итого4localUUID). Probe удалён по package/hash;10JSON основной1.5 сохранили прежние SHA. USB reverse8000→8001 восстановлен. Evidence mobile/build/device-check/offline-ui-20261101 (ignored), отчёт отделяет все фактические device/unit проверки. Подагентов Flutter-агент в A не запускал; независимое review выполнял координатор.

**Следующий B авторизован, ещё не реализован:** production dispatcher/exact replay/PUTparameters/immutable upload+ACK/complete/poll; automatic ASR→Qwen→saved Summary без дополнительной галочки, review/manual flow; per-draft opt-in false для новых offline jobs; WorkManager0.10.10 durable schedule и foreground/resume triggers; actual backend availability, scope/auth pause, backoff/Retry-After, cancel/delete/reconciliation. Legacy bridges не активировать вслепую. После B — общая основная APK/HONOR screen-off/reboot/Doze/ASR/Qwen/recovery приёмка.

Backendreadyfaf09db/report4708232/schema0011, точный API/handoff уже в mobile/docs. Координатор обновил только локальный USB session до **01.11 19:09:47 МСК**, ключ не менялся. Не возвращаться к старому вопросу expired public demo ключа: он не является текущей задачей, public .env не менять. Следующее поручение — B, а не повтор папок/foundation/A.


## Исторический промежуточный checkpoint B —01.11.2026,19:42 МСК

Production runner/immutable requests+receipts, new automatic/review routes, native cooperative yield, scoped WorkManager/resume scheduling и processing/settings/result UI подключены. **367 Flutter/12 JVM tests + analyze прошли**; Android build прошёл, новая APK не установлена в основной пакет. Отчёт [MOBILE_OFFLINE_PIPELINE_2026-11-01.md](MOBILE_OFFLINE_PIPELINE_2026-11-01.md) содержит ограничения и оставшуюся matrix/integration. Это промежуточный checkpoint, B не объявлен завершённым. Независимые core findings ACKsha256/atomicboundary закрыты и повторно приняты координатором. Backend готовит совместимое review discard_unprocessed (f8b2f18,471tests другого агента); ждём READY перед реальными запросами, не меняем сервер. Локальный USB доступ продлён координатором до01.11 21:13:41МСК, ключ/account прежние. A не перепроверять без причины; следующий этап — завершение B review/real synthetic pipeline, затем ограниченная основная APK/HONOR приёмка.

Новое прямое ограничение пользователя: проверки HONOR/USB перенесены на потом. B реализацию, unit/widget/native/build и real synthetic backend наПК довести сейчас; телефон не трогать/не просить подключать. Backendguard/объёмB не ослаблять.

B runtime-update: backend discard READY (`ffbb98e`, functionalf8b2f18/2932e56), host127.0.0.1:8001/schema0011, expiry01.11 21:13:41МСК, прежний ключ. Принят actual API_CONTRACT и handoff; новая review DELETE opt-in интегрируется. Пользователь перенёс ВСЕ установки/проверки физическогоHONOR на потом: сейчас толькоПК/hostbackend/build, новый эмулятор/образы не устанавливать. Не проситьUSB/unlock/ключ; полнуюB очередь и automaticpipeline закончить сейчас.


## Актуальный финальный checkpoint B —01.11.2026

B implementation/host validation завершены:389 Flutter/12 JVM, analyze чистый, финальная APK0.1.6+7 пересобрана после fixes, подпись/v2/версия/SHA проверены. Production queue, frozen replay/parameters/WAV/ACK/complete/poll, automatic/review, per-draft opt-in, scoped WorkManager/resume/credentials, cancel/delete/repair и UI подключены. Core/final/security review принят. Реальный host8001 E2E: automatic audio/text, manual audio/text, lostACK9операций, cancel→новыйшаблон на томжеASRисточнике, pipeline repair безASR, review discard,5Summary бездублей; собственнаяQAочищена. Отчёт [MOBILE_OFFLINE_PIPELINE_2026-11-01.md](MOBILE_OFFLINE_PIPELINE_2026-11-01.md).

Backend READYffbb98e/functional f8b2f18+2932e56/schema0011; использованhost127.0.0.1:8001, expiry откоординатора01.11 21:13:41МСК, ключне менять. Пользователь ЯВНО перенёс физическийHONOR/USB/установкуна потом: сейчас не проситьUSB/unlock/ключ, новыйэмулятор/SDKнеставить. BнаПКдоведён, основнаяAPKнеустанавливалась. Следующийэтаптолько по возвращениипользователяк телефону — AndroidWorkManager/OEM/screen-off/reboot/processdeath и установка итоговойAPK. СтарыйAprobe не доказательство новойBочереди.

Финальная реализацияB опубликована вmobile: **457525b** (после e33cdea). APKисточник —457525b, SHA256 **8A6BDFCB43FF1D5260FC9C80F89224EF5EE7630CB9CFE9B0DAF941732CF8BB17**; постоянныйфайл mobile/build/releases/YourMettings-0.1.6+7-offline-8a6bdfcb.apk. Отчёт/индекс содержат итог389tests иполныйhostE2E; дальнейшаяAndroid/HONORприёмкаотложенапользователем.


## Актуальный checkpoint — 03.11.2026

По разрешению пользователя провели проверку основной YourMettings на HONOR 400 (Android 16). Исходная B-сборка `457525b` и релиз с исправлением `4baae21` установлены обновлением поверх данных. Проверены офлайн-черновики, прерывание и продолжение записи, реальный GigaAM/Qwen, ручное принятие, автоматическое сохранение аудио после открытия приложения, варианты и редактор, добавление и перемещение в подпапку.

Исправлена конкуренция пассивного восстановления диктофона с фоновым worker: до исправления свёрнутый интерфейс просил worker уступить владение очередью. На новой APK при восстановлении USB с закрытым экраном приложения текстовый черновик дошёл до просмотра кандидата без ручного запуска. Анализ и 390 Flutter-тестов прошли. HONOR отдельно задерживал старт задачи после завершения процесса по ограничению производителя; Doze, перезагрузка и новый полный автоматический аудиопроход в фоне не подтверждены.

См. [отчёт по приёмке и APK](MOBILE_OFFLINE_PHONE_QA_2026-11-03.md). USB-переадресация восстановлена, backend не менялся.
