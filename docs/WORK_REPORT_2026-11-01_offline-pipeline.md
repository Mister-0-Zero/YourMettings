# Отчёт: durable Qwen и автоматическая аудиовстреча

Последующий разрешённый rollout **выполнен**: [USB deployment/schema0011 и real smoke](WORK_REPORT_2026-11-01_offline-deploy.md). Ниже сохранён review checkpoint до запуска.

**01.11.2026, Москва.** Ветка backend, отдельный clone `C:/Users/Алексей/Documents/Codex/work/YourMettings-backend-offline`, база сравнения **459d39f**. Этап реализован и проверен, готов к независимому финальному ревью. **Production-миграция0011, push и deployment этого этапа не выполнялись; подготовлен локальный review checkpoint.** D:/programming/VSCode/project/YourMettings остаётся на проверенном folder baseline; его процесс, .env и публичный доступ не изменялись.

## Реализованный вертикальный срез

- Audio create получил явный processing_mode=review|automatic (default review). Review допускает запись без папок и сохраняет прежний ручной flow. Automatic требует папки заранее, фиксирует server-resolved snapshot/options до ASR и после ASR/Qwen автоматически сохраняет один Summary в выбранные папки без candidate/галочки.
- TemplateOut.version считается по значимым полям TemplateInput; expected_template_version проверяется при принятии snapshot. Snapshot переживает редактирование/удаление каталога. Для text ProcessInput поддержана та же проверка; legacy default request hashes и audio omitted folders/[] сохранены. Добавление version в snapshot не меняет прежний candidate generation cache hash.
- Dispatch-only ProcessingJob используется classic/candidate/preview и automatic. Enqueue и принятие target — одна короткая транзакция, модель вызывается после commit. Post-commit kick только снижает задержку; потерянный callback восстанавливает отдельный dispatcher.
- PostgreSQL SKIP LOCKED claim, epoch/lease, owner/attempt fences. Независимый heartbeat работает во время blocking LLM и GPU wait, обновляет также heartbeat реального dispatcher процесса. По умолчанию60с/15с, до3 доставок, backoff2/4с, deadline1800с. Transient unavailable/timeout доставляются повторно в пределах лимитов, пользовательская попытка не меняется. Crash может повторить вычисление; exactly-once inference не обещается.
- Новый singleton scripts/qwen_worker.py использует session advisory lock. Launcher проверяет schema/PID/heartbeat и запускает один dispatcher; чужие процессы не завершает. Ctrl+C/Ctrl+Break прекращает новые claims и позволяет закончить текущую работу с heartbeat. Авария восстанавливается lease после нового запуска worker, Windows-служба не добавлена.
- Startup больше не помечает job-backed targets interrupted; legacy callbacks без job сохраняют прежнее error/processing_interrupted. Selection TTL/cancel и delete fence-ят jobs; поздний результат не воскрешает объект.
- ASR-result durable до Qwen. finish_chunk получает user lock перед audio/chunk locks; Qwen persistence согласована с cancel/folders. Исчезнувшая во время ASR папка даёт needs_input/folders_unavailable с сохранённым источником; repair не повторяет ASR. После enqueue действуют прежние folder guards.
- При boundary warnings automatic ждёт реального SHA/границ через существующий confirm, затем продолжает **до сохранённого Summary**. Создание manual Selection по automatic audio_session_id отклоняется automatic_confirmation_required; выбор вариантов уже сохранённого Summary по summary_id остаётся.
- Automatic success сохраняет Summary+links+Transcript.ready/first_processed+audio.completed+job.done атомарно. Ошибка сохраняет source/settings и доступный retry/cancel; нет stranded completed без Summary. До первого успеха source можно поправить при отсутствии активной обработки; после успеха постоянная блокировка сохраняется.

## Точный API для Flutter

Полный контракт и примеры: [API_CONTRACT.md](API_CONTRACT.md#durable-qwen-и-opt-in-automatic--01112026), [FLUTTER_OFFLINE_PIPELINE_HANDOFF.md](FLUTTER_OFFLINE_PIPELINE_HANDOFF.md), [openapi.json](openapi.json).

- GET audio добавляет nullable pipeline с phase/error_code/summary_id; parameters содержит только пользовательские поля, в том числе актуальные после repair, без внутренних job/snapshot.
- `POST /audio-sessions/{id}/pipeline/retry`, Idempotency-Key обязателен: `{}` для прежнего snapshot либо `{ "parameters": <полный ProcessInput> }` для явного repair. Первый202/точный повтор200 с сохранённой acceptance receipt; текущий результат — GET. Другой body с тем же ключом409 idempotency_conflict. Источника нет409 transcript_not_ready; активный job409 pipeline_busy; успех уже был409 summary_exists; предупреждения409 boundary_review_required; capacity429 generation_busy.
- `POST /audio-sessions/{id}/pipeline/cancel`, `{ "confirm": true }`:200/cancelled, повтор200; без true422 confirmation_required. Cancel fence-ит Qwen/ASR, не удаляет данные. Active upload409 audio_session_busy, completed409 summary_exists, review409 automatic_required.
- DELETE audio расширен на безопасные automatic terminal/cancelled состояния до успеха; после cancel допустим до ASR. Первый/повтор204, GET404, старый create ключ410, old pipeline retry404. Внешние зависимости сохраняют409; завершённые встречи удаляются через Summary.
- Frozen JSON/key/origin/account и несколько offline-черновиков принадлежат Flutter. Серверный drafts CRUD не добавлен. При lost ACK повторять именно frozen operation; auto-start только по отдельному локальному opt-in. Мобильный код этого этапа реализует другой агент, backend-агент его не изменял.

## Проверки и результаты

**Итоговый полный pytest после pre-complete parameters: 448 passed, 1 warning, 110.26с.** Существующая отдельная PostgreSQL с именем _test, проверены отличие от production и область тестов. Миграция0011 применялась **только в _test**; существующие migration regression tests также проходят downgrade/upgrade старых схем с данными. Использовано существующее Python-окружение D: и локальные ASR validation resources; новые модели/зависимости не скачивались.

33 добавленных теста (29 основного среза и4 pre-complete parameters):

- test_durable_pipeline.py —23 сценария: source/job до модели, atomic auto-save, отсутствие дубликата, restart после commit до dispatch, два конкурирующих исполнителя, expired lease/epoch и late result, независимый heartbeat при blocking model, bounded retries, явный retry/repair без ASR, template snapshot/version, warnings, confirm automatic→saved Summary, late ASR/Qwen после cancel/delete, concurrent retry/lost ACK, deadline, rollback сохранения, owner fences, legacy hash, candidate TTL.
- test_job_recovery.py —4 сценария: resume cancelled source; heartbeat во время GPU queue wait; совместимость старого generation cache hash; **реальные отдельные процессы dispatcher** на _test — второй завершается без владения, crash первого освобождает PG lock и новый получает heartbeat. Останавливались только собственные test children, не пользовательские службы.
- test_offline_template_guard.py —2 сценария: text cached version mismatch не занимает ключ, changed key parameters409; version не зависит от owner/timestamps и меняется при prompt edit.

Прежние regression assertions обновлены только там, где изменилось требуемое поведение: job-backed restart/endpoint inventory/launcher order; отдельный legacy candidate test намеренно удаляет dispatch row и проверяет прежний interrupted. По умолчанию regression fixtures используют одну delivery для предсказуемого terminal-error сценария; dedicated bounded-retry test явно включает3 и проверяет каждую доставку.

Промежуточные прогоны: 438 тестов проходили до последних6 дополнительных проверок; новые23 pipeline и4 process/GPU теста отдельно прошли. Первоначальный process-test ошибочно сравнивал PID Windows venv redirector с реальным worker PID; исправлен запуск реального интерпретатора с существующими venv packages. Повтор4/4 успешен, затем весь444/444. Компиляция, AST, git diff --check, Markdown file links, точное соответствие OpenAPI app.openapi и scan локальных secret значений выполнены при финальной подготовке. Единственный warning — прежний Starlette/httpx deprecation.

Реальные GigaAM/Qwen вызовы нового automatic пути и приёмка на телефоне **ещё не выполнялись**; генераторы/ASR results в интеграционных тестах синтетические. Реальный Qwen smoke предыдущего folder этапа не выдаётся за проверку нового automatic. Graceful OS console shutdown в отдельном интерактивном окне специально не проверялся; process-test проверял именно crash recovery.

## Ревью и rollout

Координатор сообщил результат независимого code_reviewer: существенных подтверждённых дефектов промежуточного diff не найдено; последующие дополнения должны войти в финальную сверку. Новых подагентов на реализацию не запускал. Ранее использованный read-only project_advisor offline_pipeline_advice учтён при проектировании lease/heartbeat; код и проверки выполнены backend-агентом.

Для rollout **нужна миграция0011**, в отличие от этапа папок. После разрешения: проверить отсутствие active jobs/чужих процессов, сделать проверяемый приватный backup, применить миграцию, штатно обновить backend и ASR-worker, поднять один dispatcher. ASR-worker должен загрузить новый finish_chunk/enqueue код; одного reload FastAPI недостаточно. Проверить source/job→auto Summary на synthetic аудио, review_required→confirm→auto save, ошибки/retry и cleanup. До этого clone не запускается на рабочей БД. Public port8000, внешний HTTPS, ключ/expiry и сетевые настройки в этом этапе не продлевались/не менялись.

Hash локального review commit указывается в итоговом сообщении; push и rollout ожидают разрешения координатора; этот отчёт не подтверждает публикацию или runtime-ready schema0011. D: folder baseline459d39f и чужой READMI.md остаются нетронутыми.


## Дополнение после обнаруженного разрыва lost ACK → editable config

По замечанию координатора добавлен owned/idempotent PUT `/audio-sessions/{id}/pipeline/parameters` до complete. Он принимает явную новую конфигурацию той же сессии после точного восстановления исходного create, фиксирует server snapshot, сериализуется с complete. После закрытия новая операция409 pipeline_parameters_locked; уже принятый exact replay возвращает200 квитанцию без перезаписи результата. Fingerprint явно включает endpoint operation name для PUT parameters и POST retry; совпавший ключ разных операций даёт409, а не чужую квитанцию.

Добавлены4 теста test_pipeline_parameters.py: lost create ACK→edited settings→одна сессия/новый Summary; replay после complete не откатывает состояние; update/complete race; changed samekey409, template/folder validation и cross-endpoint key scope; concurrent identical update. Целевой прогон вместе с summaries:9 passed. Ранее444-pass результат относится к состоянию до этой доработки; итоговый полный прогон повторяется и будет указан ниже.


### Финальная проверка дополнения

После operation-scoped fingerprints и нового PUT полностью повторён suite: **448 passed, 1 warning, 110.26с**. Новых ошибок нет. OpenAPI повторно экспортирован из фактического app.openapi и включает PUT parameters; API/handoff/inventory синхронизированы. Выполнены AST всех33 изменённых Python-файлов, git diff --check, локальные Markdown file links и scan secret значений. Receipt PUT проверяется перед закрытым состоянием и не перезаписывает результат; отдельный operation name не позволяет смешать PUT/retry по совпавшему ключу. Это финальное состояние для review дельты, production schema остаётся0010.
