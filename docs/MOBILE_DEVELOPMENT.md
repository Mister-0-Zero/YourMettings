# Mobile development

## Repository

The Flutter application lives in `mobile/` in the shared YourMettings repository.
Develop on branch `mobile` in a separate worktree. Keep the primary checkout on
`backend`. Do not modify backend code or migrations, or merge into `main`.

The sole source of backend API requirements is `docs/API_CONTRACT.md`.
The initial backend revision is `6564d8e`.

## First test version

- Russian Material 3 UI with four sections: New meeting, Meetings, Tools, Profile.
- New meeting opens first. Only transcript upload/paste is enabled.
- Import UTF-8 `.txt`, edit text, enter a title, select/create folders.
- Submit one `POST /transcripts/process` request with a stable Idempotency-Key.
- Poll processing, open Markdown summary, support explicit retry after errors.
- Browse nested folders, create/rename folders, paginate their summaries.
- Read original transcript; edit summary title/content; replace folder links;
  delete summary with confirmation. Folder deletion is excluded.
- Tools and Profile are placeholders. Authentication, audio, sharing, search,
  notifications and custom templates are excluded.

## Minimal local recovery (approved 2026-10-13)

Only non-confidential test data is used in this version.
Persist the unfinished form (text, title, selected folder IDs) and the pending
request identity. Persist the exact submitted payload and Idempotency-Key until
server acceptance is confirmed: after an ambiguous timeout, retry that same
operation without changing its payload.

After confirmed server acceptance, persist `transcript_id` before removing the
original draft. Recover via the existing processing endpoint on app restart.
Keep operation metadata until a terminal result has been shown or dismissed;
do not build a local meeting library or cache completed transcript/summary text.

Network errors retain user input. A network retry and an explicit generation
retry are different operations according to the API contract.

Summary autosave uses an approximately 800 ms debounce and flushes on exit.
Serialize saves to prevent an older response overwriting newer edits. Retain
unsaved edits in memory and expose save errors and retry.

## Configuration

Pass API_BASE_URL via Flutter --dart-define. Physical phone:
`http://192.168.1.100:8000/api/v1`. Android Emulator with backend listening on
host loopback: `http://10.0.2.2:8000/api/v1`.
Allow local HTTP only in development platform configuration, not globally in
production. Do not change firewall or VPN configuration as part of this task.

## Small implementation steps

1. Create mobile branch/worktree; discover and configure Flutter/Android tooling.
2. Generate Flutter Android/iOS project; implement four-section navigation/theme.
3. Add API models/client and meaningful request/response/error tests.
4. Add transcript form/file import/folder selection and draft persistence.
5. Add submission, polling, restart recovery and end-to-end summary retrieval.
6. Add folder tree, create/rename, paginated summary lists.
7. Add Markdown view/editor, autosave, transcript view, folder links and deletion.
8. Run final Android and end-to-end checks.

For each completed step: run relevant checks, commit and push to `mobile`, then
report the result. Flutter checks: `flutter analyze`, `flutter test`, successful
Android build. Integrations require an available running backend; absence of
connectivity from the agent is not evidence of an API defect. Do not claim iOS
verification without actually building/running it on macOS.

## Environment discovery

On 2026-10-13 Flutter, Dart and adb were not found in PATH. No installations
were found in the inspected tool/program/download directories or Windows
uninstall records. Android SDK/Studio were absent from standard locations.
Tool installation destinations must be agreed before downloading large assets.

Official setup references:
- [Flutter manual installation](https://docs.flutter.dev/install/manual)
- [Flutter Android setup](https://docs.flutter.dev/platform-integration/android/setup)
- [Android Emulator networking](https://developer.android.com/studio/run/emulator-networking)
