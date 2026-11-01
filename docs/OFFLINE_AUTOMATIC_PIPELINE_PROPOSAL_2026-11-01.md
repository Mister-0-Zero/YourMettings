# Offline и автоматическая обработка: предложение следующего этапа

01.11.2026. **DRAFT для согласования координатором. Не реализовано, не часть текущего API/OpenAPI.** Текущий этап меняет только размещение summary. Ни очередь Qwen, ни аудиопайплайн, ни режим подтверждения этим документом не изменяются. Координатор 01.11 подтвердил имеющееся прямое поручение владельца: automatic (review OFF) автоматически сохраняет Summary в выбранных папках; review ON сохраняет ручной сценарий. Это продуктовое решение принято, дополнительный опрос не требуется.

## 1. От чего отталкиваемся

Проверены текущие `app/api/audio_sessions.py`, `services/audio.py`, `services/processing.py`, `services/variants.py`, `services/folders.py`, `db/session.py` и схемы:

- ASR уже имеет durable chunks, очередь и fencing по generation/attempt. `assemble` сохраняет исходный Transcript и ready_for_review; confirm остаётся явным, с проверкой reviewed_text_sha256 и предупреждений границ.
- Qwen сейчас запускается через BackgroundTasks. Classic сохраняет источник/options/status до вызова; candidates сохраняют immutable source/options в Selection/Candidate и обрабатывают длинный вход через generate_long. Startup переводит прерванные Qwen-операции в error: это recovery ошибки, а не доставка задания до результата.
- Выбранный шаблон окончательно разрешается сервером при запуске генерации. В AudioSession.request_data нет отдельного гарантированного upfront snapshot; parameters возвращается через типизированный AudioSessionInput.
- Удаление папок блокируется для summarizing Transcript и открытой неистёкшей meeting Selection без summary. Запись/ASR до создания Selection этим guard не покрыты.

## 2. Разделение черновика и операции отправки во Flutter

Локальный черновик хранит текст/аудио, название, папки, выбор шаблона/настроек, scope профиля и явно выбранный флаг `auto_start_when_online` (по умолчанию false). Черновик редактируемый, серверный CRUD черновиков не нужен.

Отдельно хранится неизменяемая операция отправки: точный JSON, Idempotency-Key, origin/аккаунт и полученные ID/ACK. При потерянном ответе сначала повторяется тот же JSON с тем же ключом. Нельзя подставить уже отредактированный черновик под старый ключ; нельзя создать новый ключ до выяснения результата старой отправки — возможен дубль встречи. После подтверждения исходной операции новая правка становится отдельным явным действием.

Автоотправка допустима только после явного сохранённого согласия для данного черновика и подтверждения текущего профиля/доступа. Восстановление приложения не включает флаг само. Смена origin/аккаунта, истёкший доступ, отсутствие папки/шаблона → пауза с сохранением локальных данных. Ключи остаются в защищённом хранилище, не в JSON черновика.

Offline-аудио записывается до создания серверной сессии с последними допустимыми ограничениями записи. При появлении связи: один идемпотентный create, досылка тех же байтов/ID фрагментов, complete с точным expected count. ACK и удаление локальных файлов сохраняют существующие гарантии. Исходное аудио не удаляется по одному факту наличия сети.

## 3. Предлагаемое расширение контракта

Добавить явный `processing_mode: review | automatic`, default review. Поле пока отсутствует в реализации. Для review сохранить создание без папок и существующий confirm. Для automatic до принятия нужны название, 1–100 доступных папок и разрешённые сервером template/options. Новые поля не включать в канонический digest старых запросов, если они отсутствуют/default: существующие idempotency receipts должны остаться действительными.

Для автоматического режима сервер принимает и сохраняет immutable snapshot шаблона/options **до ASR**. Для кешированных offline-шаблонов предложен серверный version hash значимых полей TemplateOut и expected_template_version в create. Изменённый/исчезнувший шаблон → документированный conflict/not found и needs_input, без скрытой замены prompt. Клиентский snapshot и флаг системного шаблона не доверенные. Resume после согласованного выбора использует сохранённый ASR-текст, не запускает ASR повторно.

Снимок/режим хранить отдельно от типизированного request_data, например AudioSession.pipeline_config JSONB; не добавлять внутренние поля в parameters без согласования схемы ответа. Существующий AudioSession.status сохранить; добавить отдельное optional pipeline-состояние с этапом и причиной ожидания: receiving → asr → queued_qwen → generating_qwen → completed (summary_id); боковые состояния needs_input/review_required/error. Это будущая миграция, сейчас её нет.

После сборки текста automatic фиксирует Transcript.processing_options/title/folders, status summarizing и dispatch job для Transcript в одной короткой транзакции. Пользователь уже явно выбрал automatic заранее; это отдельный серверный путь, который не вызывает ручной confirm с выдуманным reviewed SHA. Предупреждения границ или недопустимый источник → review_required без Qwen; явное продолжение сохраняет результат ASR. Text-offline использует тот же принцип неизменяемой отправки и durable Transcript job для автоматического сохранения; review сохраняет существующие selection/candidate operations. Отдельный CRUD черновиков не вводится.

**Принятый конечный результат automatic:** ASR→Qwen→Summary в выбранных папках, без candidate/галочки/второго обязательного нажатия. После успешной генерации одна транзакция сохраняет Summary и связи, переводит Transcript в ready с постоянной блокировкой исходника, AudioSession/pipeline в completed и job в done. Она повторно проверяет owner/attempt/lease и отсутствие уже сохранённого результата. После потерянного ответа или redelivery возвращается тот же summary_id; дубликат Summary не создаётся. Ошибка сохраняет источник и параметры, позволяет явный retry без повторной ASR. Review ON оставляет существующую проверку транскрипта, confirm, варианты и явное принятие результата. Это согласованное требование следующей реализации, пока не действующий контракт.

## 4. Минимальная durable очередь Qwen на PostgreSQL

Одна таблица `processing_jobs`, без Redis/Celery и без копирования большого source/options:

| Поле | Назначение |
|---|---|
| id, owner_user_id | Идентификатор и неизменный владелец |
| transcript_id XOR candidate_id | Ровно один существующий target, FK и CHECK |
| target_attempt | Пользовательская попытка target, не транспортная доставка |
| status | queued/running/done/error/cancelled |
| claim_epoch, lease_until | Ограждение старого worker и срок аренды |
| available_at, delivery_count | Backoff и ограничение доставок |
| last_error_code, created_at, deadline_at | Диагностика без исходного текста и общий срок |

Частичные уникальные индексы target+attempt исключают двойной enqueue. Источник classic берётся из Transcript, candidate — из Selection.source_text и Candidate.options; их immutable snapshot уже принадлежит target. Принятие запроса/параметров, target status и job фиксируются одной транзакцией; HTTP 202 означает durable acceptance, а не начало сетевого вызова.

Claim: короткий `FOR UPDATE SKIP LOCKED`, увеличение claim_epoch, lease, commit **до** ожидания GPU и LLM. Worker использует существующий gpu_slot и генератор; candidate/новый automatic путь — generate_long. Для automatic переиспользуется финальная транзакционная логика сохранения Summary из classic, расширенная проверкой job/lease и завершением audio; промежуточный Candidate не нужен. Не делать второй независимый алгоритм генерации. Перевод classic на длинный путь — отдельное явно проверяемое изменение, не случайный побочный эффект очереди.

Heartbeat работает отдельным потоком/соединением также во время блокирующего HTTP и ожидания GPU (предложение: heartbeat 15 секунд, lease 60 секунд). Каждый прогресс, ошибка и финальная запись требуют текущего epoch, неистёкшей lease, owner, target_attempt и допустимого состояния target. Сохранение результата и job done атомарно. Старая генерация после истечения lease не может изменить объект или воскресить удалённый target.

Порядок result-lock: существующий user lock → target/selection/audio в согласованном порядке → job. Claim не держит job lock при ожидании user lock. Для automatic enqueue из finish_chunk требуется привести порядок к user lock → audio lock: сейчас worker начинает с audio lock, а HTTP — с user lock, добавление обратного порядка создаст deadlock.

Истёкшая lease повторно доставляет тот же target_attempt с новым epoch; инфраструктурный retry не считается новой генерацией пользователя. Предложение: до трёх доставок с backoff и общим deadline 30 минут; постоянные ошибки входа/context → terminal error. Явный retry после ошибки использует новый пользовательский attempt/ключ, сохраняя ASR. Возможен повтор вычисления Qwen после crash; гарантируется один принятый результат, **не exactly-once inference**.

Startup сохраняет нынешнюю обработку legacy BackgroundTasks. Для targets с новым job не переводить queued/running в processing_interrupted: их восстанавливает lease recovery. Cancellation/удаление/истечение Selection должны fence/cancel job транзакционно; просроченная Selection не продлевается worker автоматически. Новый Selection после явного решения использует сохранённый transcript без повторного ASR. TTL Selection начинается при серверном принятии/сборке, а не при создании offline-черновика; queued job не переживает TTL своего target.

## 5. Папка исчезла во время ожидания

Минимальное решение использует действующие guards. При синхронизации offline create проверяются доступные папки. Во время записи/ASR папку пока можно удалить: после сохранения распознанного источника перед enqueue повторно проверить доступность. Если папка исчезла — needs_input, Qwen не запускать, источник/результат ASR сохранить, предложить явный выбор через review/Selection без повторной транскрибации. Скрытых папок/переноса не делать.

Для automatic Transcript summarizing и job создаются атомарно: существующий Transcript guard защищает папки и во время queued, и во время running до атомарного сохранения Summary. Для review Selection и candidate job создаются атомарно, guard открытой meeting Selection защищает её папки до завершения/принятия/отмены/TTL. Для classic summarizing также означает queued, поэтому существующий Transcript guard сохраняется. Для варианта существующего summary используются текущие размещения; старые папки из генерации не восстанавливаются, удаление самого summary отменяет технические копии/задание.

Если продукт потребует удалять папки во время Qwen без отказа, это уже отдельная логика сохранённого результата и явного finalize после needs_input. Для предложенного минимального решения она не нужна. Все проверки folder/enqueue/delete выполняются под одним user lock, иначе между проверкой и enqueue остаётся race.

## 6. Поэтапная реализация после согласования

1. Миграция dispatch table + claim/lease/fencing/recovery tests; подключить существующие text/candidate targets, не менять review flow. Crash между commit и dispatch, lease expiry во время блокирующей модели, late result, cancel/delete, повтор enqueue, TTL и tenant isolation — обязательные проверки.
2. Flutter: несколько offline-черновиков, immutable submit operation, explicit opt-in, account/origin scope, восстановление загрузок. Потерянный create ACK + изменение черновика тестируются отдельно.
3. Upfront template snapshot/version и explicit automatic; автоматическое атомарное сохранение Summary без ручного accept, needs_input/review_required, enqueue из ASR с правильным порядком locks. Проверить удаление папки во время ASR и отсутствие повторной ASR при исправлении настроек.
4. Отдельное deployment-решение: миграция, один Qwen dispatcher process, корректировка start-dev проверок и штатного shutdown. Перезапуск только после разрешения и проверки активных задач.

Этот этап не имеет публичных job endpoints, серверных drafts CRUD, новой авторизации или фонового согласия вместо пользователя. API_CONTRACT/OpenAPI обновляются вместе с реализацией после решения координатора, а не заранее как будто эти возможности уже доступны.
