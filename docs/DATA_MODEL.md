# DATA_MODEL.md

# Предварительная модель данных

Это продуктовая модель для первой реализации. Конкретные SQL-типы, индексы и дополнительные технические поля агент может подобрать самостоятельно.

## 1. users
- `user_id` — PK;
- `email` — unique, not null;
- `password_hash` — not null.

Допустимо добавить технические поля `is_active`, `created_at`, `updated_at`, если они реально нужны реализации.

## 2. folders
- `folder_id` — PK;
- `user_id` — FK -> users;
- `folder_name`;
- `parent_folder_id` — nullable FK -> folders.

Правила:
- папка принадлежит одному пользователю;
- parent_folder_id должен ссылаться на папку того же пользователя;
- циклы в дереве недопустимы.

## 3. transcripts
- `transcript_id` — PK;
- `owner_user_id` — FK -> users;
- `text`;
- `created_at`.

Один transcript = одна исходная встреча.

Отдельная таблица meetings в MVP не нужна, пока нет свойств встречи, независимых от transcript.

## 4. summaries
- `summary_id` — PK;
- `user_id` — FK -> users;
- `transcript_id` — FK -> transcripts;
- `title`;
- `content`;
- `created_at`;
- `updated_at`.

Ограничение:
- unique `(user_id, transcript_id)`.

`content` в первой версии можно хранить как TEXT. Если выбран структурированный ответ LLM, допустимо JSONB.

Не разносить задачи/решения/сроки по отдельным таблицам до появления реальной потребности в аналитике по этим сущностям.

## 5. summary_folders
- `summary_id` — FK;
- `folder_id` — FK.

Composite PK или unique `(summary_id, folder_id)`.

Backend обязан проверять, что summary и folder принадлежат одному user_id.

## 6. share_requests
- `share_id` — PK;
- `from_user_id` — FK -> users;
- `to_user_id` — FK -> users;
- `transcript_id` — FK -> transcripts;
- `status`;
- `created_at`.

Статусы:
- `pending`;
- `accepted`;
- `rejected`.

После `accepted` не нужно физически копировать transcript.

## 7. templates
- `template_id`;
- `owner_user_id` — nullable для системных;
- `name`;
- `description`;
- `prompt_template` или структурированная конфигурация;
- `is_system`;
- `created_at`;
- `updated_at`.

Правила:
- системный шаблон нельзя редактировать напрямую;
- пользователь может его скопировать и изменить;
- пользовательские шаблоны доступны только владельцу.

## 8. user_settings

Предпочтительно отдельная таблица.

Пример полей:
- `user_id`;
- `default_template_id`;
- `review_transcript_before_llm`;
- `anonymize_before_llm`;
- `summary_detail_level`;
- `auto_accept_ai_title_and_folders`;
- `notifications_enabled`;
- `notify_transcript_ready`;
- `notify_summary_ready`;
- `notify_share_received`;
- `notify_processing_error`.

## 9. processing_jobs

Рекомендуется добавить для устойчивого пайплайна.

Поля:
- `job_id`;
- `user_id`;
- `status`;
- `source_type`;
- `transcript_id` nullable;
- `summary_id` nullable;
- `error_message` nullable;
- `created_at`;
- `updated_at`.

Статусы:
- `uploaded`;
- `transcribing`;
- `transcript_ready`;
- `summarizing`;
- `ready`;
- `error`.

Это техническая сущность, а не отдельная бизнес-сущность продукта.

## 10. Доступ к transcript

В первой версии доступ к transcript определяется backend-логикой:
- owner_user_id имеет доступ;
- получатель принятого share_request имеет доступ.

Если модель доступа станет сложнее, позднее можно добавить ACL-таблицу `transcript_access`.

## 11. Удаление

При удалении summary:
- удалить связи summary_folders;
- удалить summary.

Transcript:
- не удалять, если он нужен владельцу или другим пользователям;
- физическое удаление делать только после проверки зависимостей.

## 12. Индексы

Как минимум:
- unique index users.email;
- index folders.user_id;
- index summaries.user_id;
- index summaries.transcript_id;
- unique summaries(user_id, transcript_id);
- index share_requests.to_user_id + status;
- index processing_jobs.user_id + status.
