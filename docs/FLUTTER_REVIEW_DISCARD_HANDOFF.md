# Flutter: подтверждённое удаление незавершённого review audio

01.11.2026. **REVIEW DISCARD READY:** функциональный f8b2f18 + whitespace follow-up2932e56 опубликованы и совместно развёрнуты на USB127.0.0.1:8001/schema0011. Новый API и ASR-worker с file guard работают, real busy/retry smoke прошёл;471 tests и независимое review приняты. Миграции не было. USB expiry **01.11.2026 21:13:41 МСК** сохранён; ключ/аккаунт прежние, повторный ввод не требуется. [Итоговый отчёт](WORK_REPORT_2026-11-01_review-discard.md).

## Запрос

После отдельного подтверждения пользователем окончательного удаления черновика:

```http
DELETE /api/v1/audio-sessions/{id}?confirm=true&discard_unprocessed=true
```

Без JSON-тела и Idempotency-Key. Оба query bool: confirm=true обязателен всегда; discard_unprocessed=false/отсутствие сохраняет прежние ограничения удаления. Новый opt-in разрешает удаление **review** сессии в recording/transcribing/failed/ready_for_review до принятия Qwen, в том числе без complete, без source и после partial ACK. Он не меняет режим встречи, не создаёт summary и не требует сначала дозагрузить/завершить ASR.

## Ответы и повторы

- **204** пустое тело: сессия/chunks/payload, только её неиспользуемый transcript и технические данные удалены, disposable файлы очищены. Локальный draft/аудио можно очистить. Повтор этого DELETE204, включая повтор без нового opt-in после потерянного ответа.
- GET удалённой сессии404. Прежний create JSON/key→**410 audio_session_deleted**, другой JSON с тем же key409 idempotency_conflict. Не восстанавливать намеренно удалённую встречу старым POST.
- **409 audio_session_busy**: HTTP upload или ASR сейчас держит рабочую копию. Ничего не удалено в БД. Сохранить локальное намерение и ID/key, повторить DELETE с задержкой; не запускать complete/upload ради удаления. Ждать нужно закрытия текущего фрагмента, а не появления итогового transcript.
- **409 audio_cleanup_failed**: Windows/файловые права/небезопасный scratch path мешают очистке. БД/payload и отсутствие deletion receipt сохраняются, повтор допустим после освобождения файлов; чужие процессы не завершать.
- **409 audio_session_not_deletable**: Qwen уже принималась/успех уже был/состояние completed/исходник используется отдельным текстовым сценарием. Opt-in не обходит правила processed-source. Успешные встречи удаляются через Summary.
- **409 audio_session_in_use**: Summary, Selection (включая чужую), внешний FK или иной зависимый объект не позволяет безопасно удалить источник/сессию/фрагмент. Не терять локальные данные, показать конфликт.
- **404 not_found**: неизвестная или чужая сессия; сам по себе404 не равен подтверждённому удалению. **422 confirmation_required** без confirm=true; неверный bool/UUID422 validation_error. Остальные auth/DB ошибки обрабатывать как раньше.

У automatic этот флаг не расширяет состояния: прежний pipeline/cancel→DELETE остаётся. Защита используемых ASR-файлов теперь общая: после cancel возможен временный409 busy до закрытия файла. Флаг не является разрешением отменить принятую Qwen.

## Гарантии гонок и файлов

User/audio/chunk locks и upload guard сериализуют deletion с upload/complete/retry/confirm. Worker держит shared advisory guard на рабочие файлы, DELETE получает exclusive try-lock; транзакция не держится на время ASR. Если DELETE первым зафиксирован, worker повторно проверит claim после file guard и не создаст файлы. Если worker первым использует файл, DELETE409 busy; повтор после fragment cleanup безопасен. После закрытия файлов поздний finish проверяет существование session/chunk/generation/attempt и не воскрешает удалённый объект.

При cleanup failure БД откатывается и не выдаёт receipt; disposable copies могут быть частично очищены, authoritative BYTEA/ASR text остаётся в PostgreSQL. Успешный204 означает завершённую очистку в session scratch namespace, не обещает отмену чужих процессов. Каталоги других сессий, модели и глобальный TEMP не трогаются.

При сетевой ошибке и любых отказах сохранять local draft/байты. Прежний frozen create body/key и remote session_id оставлять доступными для reconcile; после204 не отправлять create снова.
