# Offline B: очередь и обработка — 01.11.2026

## Результат

Реализация B и проверки на ПК завершены. Ветка **mobile**; исходное wiring опубликовано в **e33cdea**, дальнейшие исправления входят в коммит этой финальной редакции. Backend-код, схема БД и конфигурация серверных процессов Flutter-агентом не менялись; merge/force-push не выполнялись.

По прямому решению пользователя дальнейшие USB-проверки и установка на HONOR400 перенесены на потом. В B телефон не использовался после этого указания, новый эмулятор/SDK/образы не устанавливались. Последняя подтверждённая основная версия телефона в A —0.1.5+6; результаты A не выдаются за проверку новой B очереди.

## Что работает

- Независимые audio/text manifests с отдельным editable input и frozen method/path/query/точным JSON/key. Неизвестный результат повторяется с прежними параметрами. Серверные IDs и receipts фиксируются до следующего шага; старые запросы и привязки сохраняются в истории.
- Audio create → отдельный PUT исправленных automatic-настроек после replay create → immutable WAV по серверным limits → ACK номера/sha256/byte_count → complete → ASR/pipeline polling. Text automatic использует transcripts/process без processing_mode.
- Review по умолчанию включён. Настройки можно сохранить до/во время записи через текущую FGS-службу и scoped RPC с durable ACK. Выключенный review ведёт к автоматически сохранённому Summary в выбранных папках, без дополнительного Start/Accept; затем открывается обычный просмотр Summary. Новый offline draft не стартует при возвращении сети без отдельного opt-in или явного запроса пользователя. Одноразовая проверка online-finish не превращается в постоянное согласие на отложенный старт.
- Review показывает полный текст. SHA берётся после фактической проверки/правки; предупреждения стыков требуют отдельного согласия. Automatic confirm остаётся automatic, не создаёт ручную selection. Review/manual использует прежние WYSIWYG, переключение вариантов, цвет и atomic accept; receipt+summary_id сохраняются до закрытия выбора/очистки checkpoint. После галочки ручного выбора — главная страница.
- Native cooperative yield прерывает зависший HTTP и освобождает scope после drain; нет TTL stealing. Хеширование/планирование PCM проверяет остановку порциями. Launch ticket защищает передачу от UI к FGS от перехвата worker. Поздний ответ не публикуется под утраченным token.
- Сохраняются attempt/next_attempt_at, exponential backoff+jitter/Retry-After. Auth, конфликт, пропавший существующий ресурс и неверный ввод останавливают автоматические запросы до явного действия. Workmanager0.10.10 использует scoped unique one-off, due scheduling, periodic15min fallback и foreground/resume wake. JobData содержит только scope_id; worker не включает микрофон. USB не зависит от NetworkType.connected. Перед отправкой проверяются immutable binding, активный profile/account/origin, SecureStorage-key и auth/me.
- Automatic cancel и подтверждённое удаление используют существующий API. Review DELETE передаёт confirm=true&discard_unprocessed=true, без тела/Idempotency-Key; busy повторяется с задержкой. Локальные bytes очищаются только после подтверждённого204 или проверенного сохранённого Summary.404 сам по себе удалением не считается. У review нет отдельной серверной отмены ASR: UI предлагает паузу передачи и удаление. Незавершённая локальная очистка завершается worker после restart по durable marker.
- Новые локальные правки, не вошедшие в принятые параметры, остаются как saved_with_changes. Краткие delivery notices ограничены20 и не содержат summary; локальная библиотека результатов не создаётся. Legacy bridges не отправляются как новые источники.

## Исправленные причины сбоев

1. Upload response содержит **chunk.sha256**, тогда как входной query называется content_sha256. Исправлены decoder, размер/номер ACK и fixtures по фактической схеме.
2. Раздельные freeze complete и input_at_boundary оставляли crash window, где новый ввод можно было принять за отправленный. Они фиксируются одним repository.update; снимок строится из принятых параметров. Старый missing boundary консервативно сохраняет draft. Поздние правки не удаляются.
3. Manual-ready скрывал незавершённый accept. Теперь accept_pending/result_pending сохраняются вместе с намерением/receipt. Lost callback/ACK восстанавливает тот же вариант и атомарные правки.
4. Audio selection source не передавал **confirm:true**. Он добавляется только после сохранённого пользовательского review; без согласия selection не отправляется. Доказанно отклонённое старое намерение архивируется перед явной новой попыткой; неизвестное не переписывается.
5. ProcessingOut.error/Candidate.error — объект code/message. Поля нормализуются; экран также принимает старые object checkpoints без TypeError, включая повторное открытие и обе темы.
6. Подтверждённая отмена selection теперь оставляет receipt/history и открывает новую namespaced попытку. Старые immutable IDs сохранены; активная привязка берётся из receipt конкретной попытки. Audio/заимствованный источник используется повторно. Собственный временный text-source backend удаляет при отмене по контракту; последующий явный выбор использует сохранённый локальный ввод, не неизвестную старую операцию.
7. CandidateInput не принимает expected_template_version. Локальная версия проверяется **до freeze нового candidate**, поле не отправляется в его JSON. Frozen replay не перепроверяет изменившийся каталог. Атомарная проверка версии кандидата контрактом не предоставляется; фактический snapshot возвращает backend. Automatic ProcessInput проверяется сервером по его контракту.

Независимый core/final wiring review принял исправления; security review не сообщил существенных находок. Эти независимые проверки организовал координатор; Flutter-агент подагентов не запускал.

## Собственные проверки

- **flutter analyze: No issues found.**
- **Полный flutter test:389 passed** —343 прежних +46 новых B проверок. Проверены frozen replay, atomic boundary/missing boundary, поздние правки, два независимых источника, зависший HTTP+новый audio draft<3s, lateACK, opt-in, auth/404/410/409/422, Retry-After/date/backoff, scope guards, cancel/delete/restart, отдельные ASR/Qwen retry, реальный error object, восстановление manual accept/cancel и обычный Summary viewer.
- **12 native JVM JUnit passed**, включая cooperative yield/no-steal/stale-token rejection; соответствующие Gradle compile/runtime-jar tasks успешны. Штатный Gradle test launcher на этой Windows имеет ранее установленную Unicode-classpath проблему. JUnit запущен напрямую с assertions из скомпилированных классов; весь Gradle test task успешным не объявляется.
- **Реальный host E2E: passed,1м31с.** Production Dart repository/journal/planner/transport/runner/SelectionController, собственная синтетическая Windows TTS запись21.630с и синтетический текст; вместо Android-native authority используется host test authority. Каждый цикл создаёт новый runner из файлов: это восстановление состояния на ПК, не проверка Android process death.

Host E2E на готовом localhost8001 проверил:

1. Параллельные automatic audio→GigaAM→Qwen→saved Summary и text→saved Summary без accept.
2. Потерю ответа **после реального server commit** для audio-create, text-create, PUT parameters, chunk, complete, candidate, accept, cancel и pipeline-retry. Сравнивались прежние method/URI/body hash/ключ; frozen replay совпал. Это управляемая потеря HTTP ACK, не испытание радиоканала телефона.
3. Правку title после неизвестного create → replay старого create → отдельный PUT → сохранение нового title. Ручной text candidate → изменение title/Markdown → потерянный accept ACK → сохранённые правки.
4. Настоящий audio review с явным confirm → отмена выбора с потерей204 → новый шаблон → atomic edited accept на **том же transcript/audio-session и с теми же ASR attempts**.
5. Удалённую до complete собственную целевую папку → needs_input/folders_unavailable с готовым источником → явный pipeline retry/repair в другую собственную папку → Qwen и saved Summary без повторной ASR; квитанция retry также терялась/повторялась.
6. Confirmed discard незавершённой review-сессии без complete/Qwen. В тестовой папке ровно **5 уникальных Summary**, соответствующих принятым операциям; дублей нет. Все собственные Summary/папки и локальные QA roots очищены; удаление Summary сверено404.

Санитизированный результат: [examples/mobile-offline-pipeline-2026-11-01.json](examples/mobile-offline-pipeline-2026-11-01.json). Воспроизведение: mobile/tool/queue_backend_smoke_test.dart, отдельно от обычного suite; нужны пути YM_QUEUE_QA_KEY_FILE/YM_QUEUE_QA_WAV. Ключ читается только из приватного файла и не сохраняется в repo/JobData/logs. Пользовательские встречи для тестов не читались/не менялись. Backend471tests и его deployment/restart проверки — результаты другого агента, не собственный Flutter suite.

## Итоговый APK

**0.1.6+7**, Android arm64 debug; пакет dev.yourmettings.your_mettings, minSdk24. Пересобран **после всех B fixes**; промежуточный e33cdea APK не является итоговым.

- Постоянный файл: `D:/programming/VSCode/project/YourMettings-mobile/mobile/build/releases/YourMettings-0.1.6+7-offline-8a6bdfcb.apk`.
- Обычный build output: `mobile/build/app/outputs/flutter-apk/app-debug.apk`.
- Размер: **126163996 bytes**.
- SHA256: **8A6BDFCB43FF1D5260FC9C80F89224EF5EE7630CB9CFE9B0DAF941732CF8BB17**.
- apksigner verify успешен, **v2=true**, один Android Debug signer. Certificate SHA256: **79977dbf53974bd6f768f78e0b4b46c25a63fec6e7dd925e0b8413ab33f993f5**. Версия/пакет прочитаны aapt; checksum постоянной копии совпадает.

## Отложенная проверка

Реальные Android WorkManager delivery/stop, foreground→headless contention, screen-off/reboot/Doze/OEM policy, новая B очередь после Android process death и установка этой APK на HONOR **не проверялись**. Это следующий согласованный этап после возвращения пользователя к тестированию телефона. Готового emulator.exe в согласованном SDK нет; новые компоненты не устанавливались. Не запрашивать сейчас USB/unlock/ключ и не подменять эту проверку прежним A probe.

Использован [API_CONTRACT.md](API_CONTRACT.md) backend READY **ffbb98e** (functional f8b2f18/2932e56), схема0011 и [review-discard handoff](FLUTTER_REVIEW_DISCARD_HANDOFF.md). По сообщению координатора локальный8001-сеанс действовал до01.11.2026 **21:13:41МСК**, ключ/account не менялись. Публичный доступ Flutter-агент не перенастраивал.
