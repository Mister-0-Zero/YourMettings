# Flutter: offline и automatic — контракт следующей реализации

01.11.2026. **BACKEND AUTOMATIC READY:** код **faf09db**, branch backend,448 тестов, USB runtime127.0.0.1:8001/schema0011 обновлён и real synthetic ASR/Qwen/restart проверен. Срок USB доступа прежний: **01.11.2026 17:07:46 МСК**, public8000 закрыт. [Deployment checkpoint](WORK_REPORT_2026-11-01_offline-deploy.md). Рабочий runtime D:/programming/VSCode/project/YourMettings; изолированный development clone C:/Users/Алексей/Documents/Codex/work/YourMettings-backend-offline.

## Создание и polling

`POST /api/v1/audio-sessions`, Idempotency-Key обязателен для надёжной отправки Flutter:

```json
{
  "title": "Встреча 01.11.2026 16:00",
  "folder_ids": ["60f04cf2-6047-4405-a008-a63544d4f357"],
  "processing_mode": "automatic",
  "template_id": "019a0120-0000-7000-8000-000000000001",
  "detail_level": "normal",
  "focus_areas": [],
  "additional_instructions": ""
}
```

template_id брать из каталога, пример UUID не является обещанием установленного шаблона. Опциональный expected_template_version — 64 lowercase hex из нового TemplateOut.version. Сервер фиксирует разрешённый snapshot до ASR. Несовпадение →409 template_version_conflict; недоступная папка/шаблон →404. Default processing_mode=review допускает folder_ids=[] и сохраняет ручной flow. У automatic нужны 1–100 доступных папок. Отсутствие/default новых полей не меняет legacy hash. Точный повтор старого create ключа+JSON →200 той же сессии; другой JSON→409 idempotency_conflict; намеренно удалённая→410 audio_session_deleted.

Загрузка chunks и complete не меняются. GET /api/v1/audio-sessions/{id} добавляет nullable/default pipeline, не скрытые поля в parameters:

```json
{"pipeline":{"mode":"automatic","phase":"queued_qwen","error_code":null,"summary_id":null}}
```

Phases: receiving, asr, queued_qwen, generating_qwen, completed, needs_input, review_required, error, cancelled. Существующий status enum сохраняется; для готовности automatic использовать pipeline.phase и summary_id. completed означает сохранённый Summary в папках без дополнительного accept. Далее GET /api/v1/summaries/{summary_id}. ProcessingOut остаётся совместимым.

## Ошибка Qwen / восстановление папок и параметров

`POST /api/v1/audio-sessions/{id}/pipeline/retry`, обязательный Idempotency-Key, сначала без переопределения:

```json
{}
```

Использует сохранённые snapshot/options; шаблон не подменяется его новой редакцией. Для исправления удалённой папки/явной смены настроек:

```json
{"parameters":{"title":"Исправленное размещение","folder_ids":["60f04cf2-6047-4405-a008-a63544d4f357"],"detail_level":"normal","focus_areas":[],"additional_instructions":""}}
```

parameters — полный ProcessInput, optional expected_template_version внутри. Наличие parameters означает явный новый серверный snapshot, его отсутствие — прежний snapshot. Первый принятый запрос202, точный повтор200 с сохранённой квитанцией принятия; GET показывает актуальный прогресс. Изменённое тело с тем же ключом409 idempotency_conflict. Новый ключ — новая пользовательская попытка только после terminal/error/needs_input/cancelled с готовым источником. Если предыдущая попытка активна→409 pipeline_busy. Если Summary уже сохранён, новый retry→409 summary_exists; точный старый retry по квитанции безопасен. ASR не повторяется. До первой успешной генерации исходник можно поправить PATCH /transcripts/{id} при неактивном Qwen.

Boundary warnings требуют реального просмотра и существующего POST /audio-sessions/{id}/confirm с актуальным SHA и boundaries_reviewed:true. У automatic confirm продолжает до сохранённого Summary, без candidate/галочки. POST /summary-selections с этим audio_session_id→409 automatic_confirmation_required (использовать confirm), а варианты сохранённого Summary по summary_id разрешены. Неверный SHA→409 review_outdated; retry без подтверждения границ→409 boundary_review_required. Неизменённые options сохраняют upfront snapshot, явные новые options разрешаются заново; expected_template_version проверяет выбранный snapshot. Нет готового источника→409 transcript_not_ready. Missing folder после ASR→needs_input/error_code folders_unavailable, источник сохраняется. После enqueue существующие folder guards защищают принятые папки.

## Отмена и удаление

`POST /api/v1/audio-sessions/{id}/pipeline/cancel`:

```json
{"confirm":true}
```

200 AudioSessionOut с phase cancelled; точный повтор200. Без подтверждения422 confirmation_required. Отмена доступна только automatic без сохранённого Summary, fence-ит Qwen/ASR, сохраняет источник/черновик; активная загрузка→409 audio_session_busy. Завершённая встреча→409 summary_exists, удаляется через Summary. Неизвестная/чужая сессия404. Отмена не означает удаление: Flutter может сохранить локальный черновик или явно вызвать DELETE /audio-sessions/{id}?confirm=true. Для automatic cancelled/error/needs_input/review_required удаление до успешного Summary безопасно расширяется с сохранением tombstone; активные ASR/Qwen без cancel→409. GET удалённой404, повтор DELETE204, старый create ключ410.

## Гарантии локального черновика

Отдельные editable draft и frozen submit operation (body/key/profile/origin). При lost ACK повторять точный старый create, не отредактированный body и не новый ключ вслепую. Opt-in auto_start_when_online отдельно сохранён, default false. Смена профиля/сервера и отказ авторизации приостанавливают отправку. Локальные данные не очищать по сетевой ошибке; WAV/chunks только после durable ACK, отмена сервера не равна удалению локального черновика. Не восстанавливать намеренно удалённую сессию старым POST.

Точный реализованный контракт: [API_CONTRACT.md](API_CONTRACT.md#durable-qwen-и-opt-in-automatic--01112026). Публикация/миграция0011/dispatcher restart и фактические тесты фиксируются в [отчёте](WORK_REPORT_2026-11-01_offline-pipeline.md). Этот файл до того — handoff для параллельной разработки, не заявление runtime readiness.


## Уточнения реализации для интеграции

- Retry с прежним ключом возвращает сохранённый acceptance response, а не текущий GET; порядок списков в retry body не переставлять. Первое202/повтор200, актуальность только polling.
- Repair обновляет публичные parameters без внутренних snapshot/job полей. `{}` при исчезнувшей папке сохраняет needs_input/folders_unavailable с202 без генерации; явное исправление — новый ключ/parameters. Нет capacity→429 generation_busy.
- Cancel до ASR сохраняет payload, но закрывает дозагрузку/complete/ASR retry (409 pipeline_cancelled); можно DELETE и начать новую запись новым ключом. Cancel после готового source допускает явный pipeline retry без повторной ASR.
- Automatic text: существующий POST /transcripts/process, без processing_mode; optional expected_template_version в ProcessInput предотвращает незаметную замену кешированного шаблона. Review text остаётся через прежний selection flow.
- USB runtime уже на schema0011 и поддерживает новые поля/endpoints; работает один dispatcher. Внешний HTTPS не продлён, сверять ограниченный срок USB доступа.


## Потерянный create ACK и новые правки — закрытый контракт

1. Сохранить новый editable draft отдельно; exact replay **исходного** create body/key узнаёт существующий session_id.
2. **До complete** вызвать `PUT /api/v1/audio-sessions/{id}/pipeline/parameters` с новым Idempotency-Key и полным AudioAutomaticParameters (title, folder_ids1–100, template_id/options, optional expected_template_version). Пример: `{"title":"Исправленное название","folder_ids":["60f04cf2-6047-4405-a008-a63544d4f357"],"detail_level":"brief"}`.
3. Первый/точный повтор200 AudioSessionOut acceptance receipt. После lost PUT ACK сначала exact repeat PUT; даже если complete уже принят, квитанция200 не переписывает текущий результат. После ACK использовать GET для актуальности, затем complete.
4. Новая операция после complete/cancel→409 **pipeline_parameters_locked**. Не отправлять незаметно старые настройки и не создавать второй неизвестный create; сохранить новое намерение и предложить пользователю явное решение. Update и complete сериализованы одним lock; победивший update попадёт в job/Summary, иначе update409.
5. Snapshot обновляется сервером, chunks и их ASR не переписываются. Create hash/ID прежние. Отсутствующая папка/шаблон404, template_version_conflict409; rejected validation ключ не занимает. Режим automatic/review этот PUT не меняет.
6. PUT parameters и POST retry используют одну область pipeline-ключей, но fingerprint включает operation name: переиспользование ключа в другом endpoint409 **idempotency_conflict**. Разным операциям — разные ключи.

Эта операция опубликована в faf09db и поддерживается обновлённым USB runtime schema0011.


## Fixture для мобильной приёмки

Локальный synthetic Windows Russian TTS: `C:/Users/Алексей/Documents/ChatGPT/YourMettings/offline-synthetic.wav`, WAV PCM mono16000Hz/16-bit,21.630с,692206байт. В Git не добавлен. Проверен реальными GigaAM/Qwen; использовать только этот синтетический материал, не пользовательские встречи.


## Дополнение: удаление review draft до ASR (USB READY)

Точный opt-in контракт и rollout-граница: [FLUTTER_REVIEW_DISCARD_HANDOFF.md](FLUTTER_REVIEW_DISCARD_HANDOFF.md). DELETE с confirm=true&discard_unprocessed=true поддерживается обновлённым USB runtime2932e56 до21:13:41 МСК; позволяет отказ от незавершённой review-сессии без complete. Busy409 сохраняет намерение для повтора после текущего fragment cleanup. API и ASR-worker обновлены вместе, миграции нет.
