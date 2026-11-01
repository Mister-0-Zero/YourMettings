# Отчёт: USB rollout durable Qwen и automatic

**Последний runtime update:** по отдельному разрешению координатора истёкшая USB-сессия заменена следующей; текущий срок **01.11.2026 19:09:47 МСК**, прежние ключ/аккаунт, schema0011. Подробности в checkpoint в конце. Первоначальные сроки ниже сохранены как история rollout.

**01.11.2026, Москва. BACKEND AUTOMATIC READY для USB приёмки Flutter.** Реализация **faf09db** опубликована в origin/backend и fast-forward установлена в D:/programming/VSCode/project/YourMettings. Код прошёл независимое основное и delta review координатора, после **448 passed** разрешены migration/rollout. [Отчёт реализации](WORK_REPORT_2026-11-01_offline-pipeline.md), [API](API_CONTRACT.md#durable-qwen-и-opt-in-automatic--01112026), [Flutter handoff](FLUTTER_OFFLINE_PIPELINE_HANDOFF.md).

## Сохранность и миграция

До остановки под транзакционными user locks проверены отсутствие active ASR/Qwen и активных upload advisory locks. Остановлены только проверенные собственные idle USB app.run и ASR coordinator по PID/команде/времени создания, с учётом реального Python child Windows venv. Дочерняя ASR-модель завершилась по наблюдению за родителем; чужие GPU/процессы/службы не завершались.

Создан приватный PostgreSQL custom dump **pre-offline-pipeline-20261101-124739.dump**, 306214 байт, вне Git в локальном private-backups, ACL только владельцу. Проверены TOC и полное декодирование архива через pg_restore в NUL без восстановления поверх данных. SHA-256 и исходные отпечатки таблиц сохранены в приватном JSON, содержимое/секреты не выводились.

Применена аддитивная **0011**; `alembic upgrade head` и `alembic check` успешны. До запуска все прежние таблицы сохранили свои отпечатки (audio_sessions сравнивается без добавленной nullable pipeline_config). После synthetic smoke дополнительно совпали бизнес-таблицы users/folders/summaries/summary_folders/transcripts/audio_sessions/audio_chunks/summary_templates. Пользовательские встречи не изменены. Служебные worker heartbeat/generation обновлены ожидаемо; минимальная квитанция намеренного удаления synthetic-сессии сохранена по контракту.

## Что фактически работает

- USB backend **127.0.0.1:8001**, один реальный listener PID **35768**.
- Новый ASR-worker PID **14152**, модель/VAD готовы.
- Один durable Qwen dispatcher PID **10784**, heartbeat готов.
- PostgreSQL/schema **0011**, health/auth-me **200**, runtime OpenAPI содержит pipeline parameters/retry/cancel.
- Активных Qwen/ASR jobs после очистки **0**.
- Process-only USB expiry **01.11.2026 17:07:46 МСК** (14:07:46 UTC) сохранён **точно прежним**, не продлевался во время обоих рестартов.
- Публичный порт **8000 без listener**. .env, внешний ключ/expiry, HTTPS, VPN/Firewall/маршруты не менялись.

Локальный operator helper start-summary-usb-session.py дополнен preserve-expiry и проверкой/запуском нового dispatcher. Это локальный артефакт вне Git. Повтор после готовности сохранил те же PID backend и expiry, не создал дубль. Прежний desktop launcher/start-dev не использовался для обхода истёкшей публичной demo-конфигурации.

## Реальные synthetic проверки

1. Штатный Windows Russian TTS → WAV → настоящий GigaAM → durable исходник **242 символа**. До complete удалена только synthetic целевая папка; после ASR — needs_input/folders_unavailable. Explicit pipeline retry/repair в другую synthetic папку → реальная Qwen → автоматически сохранённый Summary **1751 символ** без candidate/галочки. Сохранились source ID/text, ASR attempts не изменились, summary один. Exact retry вернул200 прежнюю receipt. Summary, source, аудиосессия, chunks/jobs и synthetic папки удалены штатным API. [Результат](examples/automatic-deployment-2026-11-01.json).
2. Остановлен только свой idle dispatcher при отсутствии чужих задач. Реальный ASR создал durable queued job. Перезапущен только собственный USB backend с разрешённым именно этим известным synthetic queued source; новый dispatcher продолжил **тот же job/source**, одна delivery, один автоматически сохранённый Summary, без повторной ASR. Повтор create ключа не дублировал встречу. Synthetic встреча очищена. [Результат](examples/automatic-restart-deployment-2026-11-01.json).
3. Отдельная synthetic automatic-сессия отменена до ASR: без confirm422, явный cancel200/повтор200, DELETE204/повтор204, GET404, прежний create ключ410 audio_session_deleted. Квитанция удаления намеренно остаётся минимальной, без source/audio/title/options.
4. Итоговый read-only checkpoint: schema/готовность/собственные PID, закрытый8000, неизменный expiry и исходные бизнес-отпечатки. [Метрики](examples/automatic-runtime-ready-2026-11-01.json).

Review_required→реальный SHA/boundaries confirm→автоматически сохранённый Summary проверен воспроизводимым интеграционным тестом в448-suite; отдельный новый real-audio boundary-warning smoke не выполнялся. Проверки реального USB в этом отчёте не выдаются за приёмку мобильного UI или устойчивость произвольной сети. Late-result/lease/crash fencing и concurrent PUT/complete покрыты PostgreSQL tests; process singleton/crash дополнительно проверен реальными test children на _test.

## Безопасный fixture для Flutter

Сохранён **только синтетический** локальный файл:

`C:/Users/Алексей/Documents/ChatGPT/YourMettings/offline-synthetic.wav`

Формат **WAV PCM, mono, 16000 Hz, 16-bit**, **21.630с**, **692206 байт**. Создан стандартной установленной русской Windows TTS, ничего не скачивалось. Файл вне рабочего репозитория и не добавлен в Git; мобильный агент может использовать его для проверки своей upload/recovery очереди. Исходные пользовательские встречи/аудио для тестов не использовались.

## Передача и ограничения

Flutter следует использовать backend commit **faf09db** или более свежий docs checkpoint этой ветки, schema0011 и актуальный handoff. Новые JSON теперь поддерживаются USB runtime; телефонный origin остаётся по существующему ADB reverse (обычно http://127.0.0.1:8000/api/v1 на телефоне → host8001), ключ вводится защищённым прежним способом, в отчёт не включён. Backend-агент не изменял mobile или mobile-worktree и не заявляет его QA выполненным.

После указанного USB expiry доступ закончится штатно; этот rollout его не продлевает и не открывает внешний HTTPS. Код/schema уже обновлены, дополнительных миграций для текущей приёмки не требуется. После crash dispatcher его требуется заново запустить штатным разрешённым способом, lease восстановит задания; Windows-служба автоперезапуска не добавлена. Новых модельных загрузок/пакетов/системных настроек нет.

Отчёт и несекретные метрики публикуются отдельным документационным commit; его hash доступен в истории файла. Дополнительный pytest после этого commit не запускался: исполняемый код faf09db не менялся. Markdown/file links, diff и отсутствие secret значений проверены.


## Runtime checkpoint: следующая bounded USB-сессия

**01.11.2026, 17:10 МСК.** По отдельному разрешению координатора после окончания предыдущего срока17:07:46 запущен существующий локальный helper `start-summary-usb-session.py --restart-expired`. Новое окно process-only рассчитано на2часа от старта helper: **до01.11.2026 19:09:47.335114 МСК** (16:09:47.335114 UTC). Публичный expiry не продлён.

Перед заменой подтверждены owned API PID35768/команда/время создания по сохранённой записи; непосредственно перед остановкой проверка повторена. Под user locks проверены отсутствие summarizing transcripts, queued/generating candidates, queued/transcribing ASR и queued/running dispatch jobs. Upload advisory locks проверены и удержаны до остановки idle expired API; активных загрузок не было. Локальный helper дополнен только этими safety checks, код репозитория/миграции не менялись. Чужие процессы не завершались.

Новый единственный USB listener **127.0.0.1:8001, PID6784**. Здоровые ASR **PID14152** и Qwen dispatcher **PID10784** переиспользованы; их PID совпали с предыдущим deployment checkpoint. Ollama отвечает, выбранная установленная модель доступна, новых моделей не скачивали. PostgreSQL/schema **0011**, ASR и dispatcher ready.

Read-only smoke: прежним локально прочитанным ключом health/auth-me200, тот же demo-аккаунт; без ключа health/auth-me401. Runtime OpenAPI200 содержит актуальный pipeline API. Порт8000 без listener; .env, внешний HTTPS/ключ/expiry и сети не менялись. Ключи/токены не выводились, повторный ввод пользователем не требуется — мобильный USB vault сохранён.

Полный448-suite и новые synthetic ASR/Qwen генерации не повторялись: код/schema не изменены, проверялась готовность процесса и доступа. Существующий smoke и fixture остаются действительными. Mobile может продолжить приёмку в новом ограниченном окне. Этот документационный commit публикует только runtime update; рабочий код **faf09db**, исходный deployment report **4708232**.
