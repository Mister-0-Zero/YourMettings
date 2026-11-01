# Отчёт: opt-in discard незавершённого review audio

**01.11.2026, Москва.** Ветка backend, изолированный clone `C:/Users/Алексей/Documents/Codex/work/YourMettings-backend-offline`, база сравнения **7ba9cdd**. Реализовано и проверено, подготовлено к независимому review/публикации. **На работающий D: новый код не развёрнут**: там остаются faf09db/schema0011 и разрешённая USB-сессия до **21:13:41 МСК**. Mobile/mobile-worktree и посторонний READMI.md не изменялись.

## Подтверждённая причина

Review create допускает отсутствие папок и source. Chunk ACK не закрывает запись. Если partial session не получила complete, assemble не создаёт итоговый transcript, даже когда принятые фрагменты done. Прежний DELETE требует ready_for_review и полный source, поэтому такой remote draft нельзя удалить вообще, а не только пока ASR занята. Это воспроизведено тестами без создания summary ради удаления.

## Изменение контракта

Существующий DELETE дополнен **optional/default false** query `discard_unprocessed`:

`DELETE /api/v1/audio-sessions/{id}?confirm=true&discard_unprocessed=true`

Подтверждённый opt-in позволяет owned review recording/transcribing/failed/ready_for_review до принятия Qwen, в том числе без complete/source или с partial ACK. Default false/отсутствие сохраняет прежние ограничения. Без confirm=true422 confirmation_required; неизвестная/чужая404. Completed/ранее обработанный/принятый Qwen/независимый источник не обходятся. Summary, Selection (включая чужую) и внешние зависимости дают409, другие встречи не повреждаются.

Первый/повтор204 с прежней durable deletion receipt. GET404; original create key/body410 audio_session_deleted, changed body409. Повтор после потерянного204 допустим и без opt-in, но с confirm=true. Произвольный404 не является подтверждением удаления. Automatic-ветка не расширялась этим флагом, её cancel/terminal правила прежние.

Точный контракт/ошибки/порядок Flutter: [FLUTTER_REVIEW_DISCARD_HANDOFF.md](FLUTTER_REVIEW_DISCARD_HANDOFF.md), [API_CONTRACT.md](API_CONTRACT.md#явный-discard-незавершённой-review-записи--01112026), [openapi.json](openapi.json). Mobile до deployment сохраняет delete intent в безопасной паузе.

## Файлы и конкуренция

Добавлен session advisory file guard, без новой таблицы/службы. ASR worker получает shared guard, заново проверяет session/chunk/worker generation/attempt, затем создаёт/использует disposable copies. Guard удерживается до закрытия TemporaryDirectory и отпускается до user/row locks в finish_chunk. Модель не удерживает транзакцию PostgreSQL. Существующая обработка вынесена в Coordinator.process_job для этой границы и её воспроизводимой проверки; модель/алгоритм ASR не менялись.

DELETE под user/session/source/chunk locks берёт exclusive try-lock upload guard и ASR-file guard. Пока используется upload или ASR copy, возвращает409 audio_session_busy без DB-удаления. Повтор после текущего fragment cleanup не требует complete/готового source. Queued/stale claims без занятой копии можно удалить: row locks сериализуют claim, а worker после deletion не создаст файлы. Late finish проверяет отсутствие session/chunk и не воскрешает объект.

Cleanup in-use/unsafe path/permission failure409 audio_cleanup_failed откатывает DB и не выдаёт receipt. Disposable files могут быть частично очищены, но authoritative PG payload/text сохраняется. Успешный204 подтверждает cleanup и DB commit. Активные чужие процессы, модели, TEMP и scratch других сессий не трогаются. Общий file guard также защищает существующий automatic cancel→DELETE от удаления ещё используемой ASR copy; допускает временный busy, не ослабляет ограничения.

## Фактические проверки

- **Целевой pytest:47 passed,1 warning,21.27с** — новый test_review_discard.py и существующий test_audio_deletion.py.
- **Полный pytest:471 passed,1 warning,117.90с** —448 прежних и23 новых сценария.
- Новые сценарии: recording без complete/partial ACK; transcribing/incomplete/failed без source; обязательный confirm; stale claimed job/late finish; active file guard409 и успешный retry; cleanup failure rollback; **реальный Windows file handle без share-delete** и повтор после CloseHandle; чужая сессия; Summary/foreign Selection/внешний составной chunk FK; прежние processed/source guards; concurrent upload/delete; настоящий Coordinator.process_job с контролируемым результатом ASR — delete до guard не создаёт файлов/инференса, file-active даёт busy, delete после cleanup до finish не воскрешает объект.
- Использована существующая **yourmettings_test** из прежнего TEST_DATABASE_URL после уточнения координатора, что guarded означало проверенную _test базу, не буквальный новый suffix. Сохранены проверки PostgreSQL/_test и отличия от рабочей DB/URL. Read-only проверка показала отсутствие CREATE DATABASE у тестовой роли; новые базы/роли/права/.env **не создавались и не менялись**.
- Compileall и AST изменённых Python-файлов, git diff --check, exact OpenAPI export/optional query schema, Markdown file links и scan локальных private values выполнены. Единственный warning — прежний Starlette/httpx deprecation. Нет отдельного настроенного Python lint/analyze, Flutter analyze не запускался: mobile не менялся.

Новые real GPU ASR/Qwen или телефонный QA этого opt-in не выполнялись: worker inference в тестах управляемый synthetic result, но PostgreSQL locks, file cleanup и Windows in-use handles реальные. Не приравнивается к runtime-ready нового DELETE. Прежние реальная ASR/Qwen приёмка и448 tests не заменяют эти новые проверки.

## Миграция, публикация и следующий шаг

**Миграция не нужна**, схема остаётся0011; новых служб/зависимостей нет. Commit/hash реализации доступен в истории отчёта и итоговом сообщении после публикации в backend. Перед rollout нужен независимый review. После разрешения проверить отсутствие active jobs/uploads и согласованно обновить **backend и ASR-worker**, сохранив текущий USB expiry21:13:41 и public8000 closed. Новый discard path нельзя включать рядом со старым ASR worker без file guard. Здоровые Ollama/dispatcher перезапускать не требуется, внешний доступ/секреты не продлевать.

Текущий D runtime в рамках правки не останавливался, его состояние не менялось после отдельно опубликованной смены USB-сессии7ba9cdd. Новых подагентов для этой узкой реализации не запускалось; независимое ревью организует координатор. Следующий шаг — review этого конкретного diff, затем разрешённый reload и targeted runtime discard smoke.


## Независимое ревью и whitespace follow-up

Координатор принял независимое review f8b2f18 без существенных находок; проверены try-lock, claim recheck, закрытие scratch до finish и cleanup failure. По замечанию удалена лишняя пустая EOF в тесте отдельным follow-up commit, без force-push. Финальный diff --check выполнен; функциональный471-suite не повторялся ради whitespace. Разрешён совместный USB reload backend/ASR с сохранением21:13:41 МСК; фактический результат будет добавлен после runtime smoke.
