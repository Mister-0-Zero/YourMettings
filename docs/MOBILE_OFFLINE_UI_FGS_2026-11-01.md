# Checkpoint A: локальные черновики, UI и foreground-запись

**01.11.2026. Подэтап A реализован и проверен.** Коммит [`7f27a6c`](https://github.com/Mister-0-Zero/YourMettings/commit/7f27a6c826df76431d13bc0c0852ab7e2985a190), ветка `mobile`. Продолжение основы [`af84e48`](https://github.com/Mister-0-Zero/YourMettings/commit/af84e48). Общая задача offline → ASR → Qwen → сохранённый Summary **ещё не завершена**: dispatcher/pipeline/WorkManager подключаются следующим подэтапом B.

Основная YourMettings на HONOR сохранена как **0.1.5+6**. Новая основная APK **0.1.6+7 не устанавливалась**; физические проверки выполнены отдельным приложением с production bootstrap/UI/foreground-кодом. Backend, БД, публичный доступ и ключи Flutter-агент не менял.

## Реализованное поведение

- Холодный запуск прежде проверенного scope открывает локальные данные без обязательного чтения ключа/auth/HTTP. ConnectionSettings сохраняет подтверждённую identity даже при пустом/истёкшем доступе; новый неизвестный аккаунт требует обычной проверки. Сеть используется отдельно, для обновления каталогов. Поздняя ошибка авторизации прежнего scope не меняет состояние нового аккаунта.
- Главный экран создаёт независимые текстовые черновики и открывает локальный диктофон. В «Пространство → Черновики» можно вернуться к каждому источнику. Manifest конкретной встречи авторитетен, local UUID стабилен; source.pcm каждой записи находится в её собственной директории, без переиспользования active-audio новой встречей.
- Текст/название/настройки сохраняются после durable commit. Есть autosave, flush при уходе приложения в фон, явная галочка и выход с сохранением. Ошибка оставляет ввод доступным и показывает повтор сохранения над прокручиваемой формой. Программный переход к продолжению записи ждёт текущего save; при ошибке экран не закрывается.
- Сохраняются папки, template ID/version/options, title, mode и отдельный opt-in. «Показать транскрипт» по умолчанию ON=`review`; OFF=`automatic`. `auto_start_when_online` отдельно и по умолчанию false. В A это **сохранённые настройки, ещё не запущенная автоматическая обработка**.
- Кэш папок/шаблонов scoped, с возрастом. Вложенные папки имеют отступы; отсутствующие в текущем кэше выбранные IDs остаются видимыми и не сбрасываются после ошибки обновления. Перед сохранением свежих каталогов серверная identity проверяется на том же origin. Кэш не считается сетевой авторизацией.
- Новая Android foreground microphone service получает native lease после durable draft/launch intent. Запуск PCM16 mono/16kHz не требует POST, server ID или прежнего caps cache. До открытия микрофона проверяются разрешение и свободное место; pause/resume/stop последовательно дренируют доступный буфер. Source восстановлен по фактической длине после смерти процесса; микрофон сам не запускается.
- Команды содержат scope, stable local ID, service instance; старый протокол не принимает новое владение и наоборот. Native token/engine/kernel lock защищают запись. UI-инициализация/закрытие дренируют текущие foreground/restore проверки; закрытие Activity не останавливает FGS. Новая встреча после stop получает собственный source.
- Чисто локальный черновик удаляется после подтверждения. Наличие frozen request/server IDs блокирует локальное удаление до reconciliation; изменение input не меняет прежние key/body/receipts/IDs. Действие серверного удаления без сверки результата здесь не имитируется.

Основные изменения: `services/drafts/draft_workspace.dart`, `draft_access.dart`, `legacy_draft_handoff.dart`, `features/drafts/local_draft_pages.dart`, `features/recording/draft_recorder_coordinator.dart`, main/app/workspace wiring и расширение `packages/queue_owner/`.

## Legacy: сохранность и граница владения

Обычный прежний локальный текст без pending operation переносится только до создания старых UI-контроллеров: committed mapping/prepared manifest → проверка digest → очистка старого источника → activation. Crash до/после очистки восстанавливается тем же local ID; изменившийся позже источник превращается в legacy bridge, не очищается старым snapshot. Незавершённый handoff не позволяет старому контроллеру записать поверх его источника.

PendingRequest, принятый transcript ID, selection/accept receipts и прежние audio journal/WAV/ACK сохраняют **прежнего авторитетного владельца** и отдельные доступные legacy routes. Новый manifest для них — dispatch-blocked мост, не новый submit. Аудио не перемещается/не удаляется; snapshot/mapping создаётся только при доказанно остановленном старом writer. Живой audio FGS запрещает audio adoption. Поздние старые и новые snapshots не подменяют owner/scope/instance другого протокола.

Это безопасное подключение миграции, а не разрешение B безусловно запускать legacy snapshots. `legacy_bridge`, `migration_pending`, `migration_prepared` нельзя отправлять как новые задания. Источники и OperationStore остаются на прежних маршрутах до отдельного доказанного handoff/reconciliation. Переносить чужие/unscoped файлы в текущий аккаунт нельзя.

## Найденные причины ошибок и исправления

1. **Resume обходил отложенное сохранение.** pushReplacement отменял debounce и терял быстрые правки title/options, особенно после disk error. Теперь переход ждёт `_save()`/текущий save, защищён `_transitioning`, при ошибке остаётся редактор. Два widget regression: быстрые правки → сразу Resume, и отказ диска.
2. **Live-FGS Activity recreation возвращала на подключение.** Реальный HONOR выявил ArgumentError на новом local-recorder initialize. Безопасный стек показал `shared_preferences_android` NativeInterop → SharedPreferences.getInstance → FlutterForegroundTask.getData → localCaptureServiceRunning. Причина — служебное чтение плагина после смены UI engine при живом FGS; это не был доказанный отказ API/ключа и не предположение о legacy handshake.

Указатель microphone launch перенесён в существующий native broker: приватный `capture-ticket.v1`, только scope/local UUID/nonce, без ключа/транскрипта. Native write/clear проверяют engine/token, manifest, scope и nonce под общим mutex; запись flush+rename, stale callback не может удалить новый ticket. FGS проверяет scoped binding и consumed intent. Новый диктофон больше не использует FlutterForegroundTask.getData/saveData. Отдельные queue jobs должны читать **свой immutable scoped queue-binding.json**, а не этот глобальный microphone pointer.

Ошибки локального восстановления больше не требуют повторного подключения известного аккаунта. Старый recorder failure остаётся в его потоке, новый restore failure показывает локальную ошибку; частично не загруженный RecoveryStore не сохраняется как пустой поверх исходника. У известного scope при общей ошибке открытия есть локальный экран повтора, у неизвестного остаётся обычное подключение. Для диагностики оставлен только безопасный stage/type без содержимого исключения, ключей или встреч.

Независимые проверки координатора подтвердили исправление Resume P2 и Native ticket/bootstrap delta; сам Flutter-агент дополнительных подагентов на этом этапе не запускал.

## Автоматические проверки на окончательном коде

| Проверка | Результат |
|---|---|
| `flutter analyze` | No issues found |
| Полный `flutter test` | **343 passed** |
| Native queue-owner JUnit | **11 passed**, assertions включены |
| Android debug ARM64 build | Успешен |
| Apksigner verify | Успешен, v2 true |
| `git diff --check` | Успешен |

В 343 входят 27 новых A-проверок: workspace11, legacy handoff7, widget8, дополнительный protocol/legacy restore1. Проверены отсутствие HTTP/чтения vault при локальном startup, два audio+два text, режим/opt-in/options/version, scope isolation/stale commands/late auth error, storage failure/low disk, frozen request preservation/delete guard, source clear/activation crash и legacy operation/WAV/ACK preservation. Widget-проверки включают cold local home, autosave/background flush, retry после disk error, cached nested folders, быстрый Resume и свежий UI с живым FGS/ошибкой ticket-хранилища без auth gate.

Native11 проверяют прежний owner/publish/PCM/wire-plan и новый ticket: междвижковый handoff, stale clear, nonce fencing, malformed/missing source. Gradle compile tasks успешны; JUnit запущен напрямую на тех же compiled classes/classpath из-за ранее установленной проблемы Gradle test launcher с Unicode classpath на этой Windows. Штатный testDebugUnitTest целиком успешным не объявляется. Замечания/проверки не отключались. Workmanager_android сохраняет предупреждение о будущей миграции Kotlin plugin при обновлении Flutter; текущая сборка успешна.

Локальные ignored logs: `mobile/build/offline-ui-full-tests.log`, `offline-ui-analyze.log`, `offline-ui-build.log`, `offline-ui-native-compile.log`, `offline-ui-native-tests.log`, `offline-live-fgs-regression.log`. Промежуточные неуспешные прогоны не выдаются за результат: лишний startup await старого handshake убран, legacy tests восстановлены; fake-clock widget teardown дренирует IO до удаления Windows temp-dir.

## Реальный HONOR: что проверено

Отдельный пакет **dev.yourmettings.offline_ui_probe** запускает production bootstrap и экраны с synthetic известным аккаунтом, **пустым vault** и заведомо недоступным backend **127.0.0.1:65531**. Сеть/VPN/Firewall телефона и ПК для этого не отключались; проверялась недоступность нашего сервера, не глобальный авиарежим.

- Cold home открылся, микрофон стартовал без key/HTTP/server ID/caps cache. Первая запись сохранена: **1920000 PCM bytes /60 секунд**.
- Pause: **1673600 bytes**, через2сек тот же размер; после Resume и Home Activity — **1814400 bytes**, затем stop→ready/editor.
- Вторая запись получила другой local UUID/source. Force-stop **только probe** → cold restart восстановил тот же source/ID: **195200 bytes**, state interrupted, микрофон выключен. После явного Resume source дописывался, а исходный префикс сохранил прежний SHA256.
- После root fix настоящий Activity recreation с Intent flags0x10008000 при живом FGS вернул главную с «Открыть запись». ActivityRecord изменился, process/service instance остались теми же, PCM продолжал расти. Stop подтвердил ready. Вторая запись после контрольного продолжения — **832000 bytes**. Первая PCM сохранила полный SHA256.
- Через настоящий UI созданы и явно сохранены **QA_TEXT_A/QA_TEXT_B** с разными телами. После перезапусков в списке ровно **2 audio+2 text**, четыре разных local ID, правильные тексты; requests/server IDs отсутствуют. Первая PCM после текстовых правок не изменилась.
- Просмотрен dark UI реального HONOR с крупным шрифтом; widget renders покрывают light/default и cached settings. Итоговый SafeArea/close-drain delta дополнительно проверен анализатором/полным suite/build; отдельной установкой основного APK не выдаётся.

Первоначальная неподдерживаемая am option не считается recreation-проверкой; итог подтверждён только успешным правильным Intent запуском. При каждом диагностическом repro микрофон останавливался в finally через force-stop только probe, PCM сохранялись. Небольшие паузы USB потребовали обычной разблокировки и одного restart собственного ADB; защита/PIN/драйверы не менялись.

После сверки установленного package/hash probe удалён, его приватные тестовые данные очищены uninstall. SHA установленного финального probe: `5C89A5C066E68E22BE72F9451B5199487D781978927AEB83A21F2E297DBF6FF4`. Основная YourMettings подтверждена **0.1.5+6**, **10 JSON до/после совпали по SHA256**, uninstall/clear-data основной не выполнялись. Восстановлен и проверен **adb reverse tcp:8000→tcp:8001**, основное приложение снова открыто. Его vault/ключи не извлекались и не переписывались.

Evidence только локально `mobile/build/device-check/offline-ui-20261101/`: first-capture, second-capture-recovery, four-drafts-result, final-preservation JSON и screenshots01–06. Raw PCM не публиковался/не отправлялся backend; screenshots и сырые пользовательские файлы не включены в Git. Screen-off/Doze/reboot/ASR/Qwen/сетевая досылка этой новой версии **не считаются выполненными в A** — это общая финальная приёмка после B.

## Основной APK: сборка, не установка

**0.1.6+7**, package dev.yourmettings.your_mettings, debug ARM64. Файл локально: `D:/programming/VSCode/project/YourMettings-mobile/mobile/build/app/outputs/flutter-apk/app-debug.apk`, **125910322 bytes**.

SHA256: `F0265720F17A550803596CA81AF79633C55D092DEAE427EA21812098E4E7FDD0`.

Signer SHA256: `79977dbf53974bd6f768f78e0b4b46c25a63fec6e7dd925e0b8413ab33f993f5`; подпись v2 проверена. Этот промежуточный APK пользователю как готовая offline/pipeline версия не выдавался и на основной пакет HONOR не устанавливался.

## Граница готовности и следующий обязательный B

**UI/FGS и локальная сохранность подключены; очередь и автоматическая отправка ещё не подключены.** Workmanager0.10.10 уже закреплён в core, но production dispatcher/callback/schedule пока отсутствуют. Сохранённый opt-in не запускает обработку сам по себе на A-коде.

B: один authority/dispatcher, frozen exact replay до изменений параметров/новых keys, immutable wire uploads/ACK→complete→poll; auth/scope pause, Retry-After/backoff/jitter, durable Worker schedule+foreground/resume, manual retry/cancel/delete/reconciliation. Обычное online automatic finish обязано без дополнительного Start/candidate/галочки получить **сохранённый** Summary в выбранных папках. Review по умолчанию сохраняет ручную проверку/редактирование. Новые offline задания запускаются при связи только по сохранённому per-draft opt-in/явной команде, уже отправленные неизвестные операции сначала сверяются старыми keys. Нужны сохранённые настройки до automatic finish и полный пользовательский маршрут; чтение legacy bridges как новых submit запрещено.

Контракт — [API_CONTRACT.md](API_CONTRACT.md), [backend handoff](FLUTTER_OFFLINE_PIPELINE_HANDOFF.md), backend faf09db/schema0011. По сообщению координатора локальный USB доступ обновлён до **01.11.2026 19:09:47 МСК**, тот же ключ/account/origin; публичный expired .env не изменён. Backend 448 tests/реальный automatic smoke — проверки backend-агента, не результаты этого Flutter checkpoint. Следующий runtime rollout координируется отдельно.

Актуальный план: [MOBILE_OFFLINE_QUEUE_PLAN_2026-11-01.md](MOBILE_OFFLINE_QUEUE_PLAN_2026-11-01.md). Итог A не заменяет завершение всей offline/automatic задачи.
