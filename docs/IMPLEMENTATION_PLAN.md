# IMPLEMENTATION_PLAN.md

# План первой тестовой реализации

## Этап 0. Репозиторий

Предлагаемая структура:

```text
project/
  backend/
  mobile/
  docs/
  docker-compose.yml
  .env.example
  README.md
```

## Этап 1. Backend + PostgreSQL без AI

Цель:
- запустить FastAPI;
- подключить PostgreSQL;
- настроить SQLAlchemy/Alembic;
- создать users;
- registration/login;
- CRUD folders;
- CRUD templates;
- минимальный CRUD summaries/transcripts для тестов.

## Этап 2. Processing jobs

Добавить:
- upload source;
- processing_jobs;
- статусы;
- polling endpoint;
- обработку ошибок.

Сначала ASR/LLM можно заменить fake adapters.

## Этап 3. Local ASR

Подключить локальный ASR через адаптер.

Сценарий:
audio -> transcript -> PostgreSQL.

Проверить:
- короткое аудио;
- среднее аудио;
- ошибочный файл;
- временный файл удаляется после обработки.

Отдельно позже проверить длительные записи 60+ минут.

## Этап 4. Local LLM

Подключить локальную LLM через адаптер.

Сценарий:
transcript + template -> summary.

Проверить:
- базовый шаблон;
- пользовательский шаблон;
- title suggestion;
- folder suggestion.

## Этап 5. Полный backend flow

Собрать:
audio -> ASR -> transcript -> optional review -> LLM -> summary -> folders.

После этого backend считается готовым к первой мобильной интеграции.

## Этап 6. Flutter skeleton

Сделать:
- навигацию по 4 разделам;
- API client;
- login screen;
- New Meeting screen;
- Meetings screen;
- Tools/Templates screen;
- Profile screen.

Пока допускается простой UI.

## Этап 7. Flutter -> backend

Подключить:
- login;
- upload/record audio;
- статус processing job;
- transcript review;
- summary view/edit;
- folders;
- templates.

## Этап 8. Sharing

Реализовать:
- поиск пользователя по email;
- create share request;
- inbox/pending request UX;
- accept/reject;
- создание собственного summary получателем.

## Этап 9. Notifications

Для локального прототипа достаточно внутриприкладных уведомлений/обновления статусов.

Push можно подключить после подтверждения основной логики.

## Этап 10. Hardening

После работающего вертикального среза:
- тесты;
- логирование;
- обработка сетевых ошибок;
- retry;
- таймауты;
- ограничения размеров файлов;
- cleanup временных файлов.

## Порядок приоритетов

1. backend + PostgreSQL;
2. fake AI pipeline;
3. real local ASR;
4. real local LLM;
5. Flutter;
6. sharing;
7. notifications;
8. UI polish;
9. внешние видеоконференции.
