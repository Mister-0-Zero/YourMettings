Latest save/link/transcript verification: [2026-10-20](MOBILE_SAVE_FIX_2026-10-20.md).

Latest editor correction: [2026-10-19](MOBILE_EDITOR_FIX_VALIDATION_2026-10-19.md).

Latest UX/editor verification: [2026-10-19](MOBILE_UX_VALIDATION_2026-10-19.md).

# Mobile refinement validation

Completed: 2026-10-14. Branch `mobile`, existing separate worktree
`D:\programming\VSCode\project\YourMettings-mobile`.
The API contract was copied from `origin/backend` at `5ecb749`; the backend branch
was not merged. Backend code, PostgreSQL configuration and migrations were not edited.
The original verification record below predates the new cleanup semantics.

## Automated checks

- Flutter analyzer: no issues. All 41 tests passed.
- Theme preferences persist through real file storage; navigation alignment tested
  at 320/390/800 px, both themes, increased text scaling and system insets.
- Legacy recovery files load default processing options. Draft, pending request
  and accepted operation preserve options. Lost-response replay keeps payload/key;
  corrected validation rejection permits a new operation key. Retry uses known ID.
- Direct Edit -> checkmark -> updated Markdown, save failure retention, autosave,
  serialized saves and save-on-exit passed.
- Folder cancellation sends no DELETE; successful response refreshes the tree;
  folder_processing 409 preserves it. The request has the exact query and no body.
- Intentional deletion cancels ambiguous replay; accepted-ID 404 clears tracking
  with no creation POST. Source text/settings are preserved for editable drafts.
- Structured Markdown plus an oversized table renders at 320 px in both themes.
  The test drags the horizontal scrollable and verifies its scroll extent/offset.
- Android debug builds succeeded for both USB and LAN base URLs.

## Real backend (2026-10-13)

The updated Dart smoke client passed against the running backend using only fresh
agent-owned fixtures. Actual Qwen generation accepted detailed processing, four
focus areas and additional instructions. Identical key/payload returned the same
transcript ID; changed options with the same key returned 409. Polling reached ready.
Deletion during active generation returned 409 folder_processing. PATCH/readback,
source reading, shared summary outside a deleted tree, tree removal, final summary
deletion and 404 for the unused transcript/processing passed. Own fixtures were
removed after success. No user-owned folder was deleted.

## Actual HONOR 400 / Android 16 (2026-10-14)

The updated debug APK was installed preserving app data, and tested through actual
Android UI over USB with `adb reverse tcp:8000 tcp:8000`.

- Centered header and two-line New meeting navigation label visually checked.
  Light/dark and blue/green selections checked; light/blue survived cold restart.
  Original user preference dark/green was restored and verified after restart.
- Own draft text, detailed mode, tasks/owners/deadlines/risks and additional
  instruction were entered through the form. Cold restart restored visible input
  and options. Accepted recovery retained transcript_id/options and zero draft text.
- A real operation was submitted from the phone, the app was stopped while
  processing, and restart restored the ID and obtained ready/actual Qwen summary.
- One Edit tap entered the editor with a top checkmark. Temporarily removing only
  the agent's ADB reverse mapping caused a save failure. Both checkmark and Back
  kept the editor and unsaved text. Restoring reverse and confirming saved the title,
  verified by reading backend, and returned to formatted Markdown.
- Headings, paragraphs, bold task blocks and bullet lists were readable in light
  and dark. A wide Markdown table added to this own result scrolled horizontally;
  second-column text became visible after the swipe, without layout overflow.
  Numbered lists also passed the automated layout test.
- Summary deletion dialog used the new neutral cleanup explanation. Cancel kept
  the object. Confirm updated the folder list to empty and cleared local tracking.
  Backend GET summary, transcript and processing each returned 404.
- Folder dialog explained recursive deletion and externally linked summaries.
  Cancel retained the tree; confirm removed the own parent and child and returned
  to the refreshed folder tree. The phone folder tree was empty of summaries at
  this point; deletion with shared content and generation 409 was covered above
  by real API verification and by widget tests.
- Current app-process log contained no FATAL EXCEPTION, unhandled exception or
  RenderFlex overflow matching the checked patterns. Temporary phone screenshots
  and hierarchy were removed after verification; local evidence stays ignored.

Own phone test transcript: `ae7a3c3a-88ca-4fc7-a930-be51960e5bbc`;
summary: `e9b7f8cf-e021-4576-937e-31b3e380cc69`. Both were deleted deliberately.
Own root `c5bedd5f-3280-49a6-86f0-aa6d8b798ce1` and its new child were deleted.
The phone is left with the tested USB build, an empty test draft and dark/green
preferences. Unrelated server objects were preserved.

## Artifacts and limits

`mobile/build/device-check/YourMettings-USB-debug.apk` is the tested USB build.
`mobile/build/device-check/YourMettings-LAN-debug.apk` and ordinary `app-debug.apk`
use `http://192.168.1.100:8000/api/v1`. These artifacts are ignored by Git.
LAN connectivity was not verified in this refinement; USB requires the connected
PC, reverse mapping and running backend. No VPN, Wi-Fi or firewall changes.
Only Android debug was built; iOS, signed release and production were not tested.

---

# Initial MVP validation — historical (2026-10-13)

Date: 2026-10-13. Branch: `mobile`, separate worktree
`D:\programming\VSCode\project\YourMettings-mobile`.
Primary checkout remains on `backend`; server code, migrations and API contract
were not changed by the mobile implementation.

## Verified

- Flutter stable 3.47.7, Dart 3.13.5; Android SDK platforms 36 and 35;
  build-tools 36; NDK 28.2.13676358; CMake 3.22.1.
- Official downloaded archive SHA256 checks passed. Android Studio Rabbit 1,
  bundled JDK 25.0.3; Flutter doctor passes with refreshed PATH.
- Flutter analyzer: no issues.
- All 25 automated tests passed. Tests cover navigation, disabled future actions, atomic submission,
  stable idempotency key/payload, processing statuses and errors, network timeout,
  nested folder mapping/listing/creation, draft persistence and restart recovery,
  accepted draft removal, save failures, serialized summary autosave, debounce,
  save-on-exit, deletion confirmation and the complete transcript form scenario.
- Android debug APK builds successfully with native file picker/path provider.
- Real backend check using the same Dart API client passed at
  `http://127.0.0.1:8000/api/v1`: folder create/rename, one-request processing,
  real LLM-generated summary, idempotent replay returning the same IDs, folder
  listing, original locked transcript, title/content edit and readback, multiple
  folder links, summary deletion and retained transcript.

The real test left two test folders and transcript
`2e662627-e79f-4a84-9cd8-3cc3b4be7714` on the server. Its generated summary was
removed after validation. These are non-confidential smoke-test objects.

## Windows build adjustments

`scripts/flutter.ps1` temporarily sets the JDK Unix-domain socket directory to
an ASCII path under ANDROID_HOME. This resolved the observed loopback socket
failure without global Java/network/security changes. Kotlin incremental
compilation is disabled locally in the project because Kotlin cache paths cannot
span the C: pub cache and D: source tree in this setup. Full compilation works.

## Physical-device verification

HONOR 400 (Android 16) was attached, authorized in ADB and tested with the debug
application. Installation and cold launch succeeded. The following were checked
through the actual Android UI:

- All four tabs; unavailable audio/video actions remain disabled.
- Native system document picker selects the agent-created UTF-8 TXT; Russian
  text appears intact in the editor.
- Draft survives force-stop/restart and APK update.
- Folder tree and folder selection load from the real backend.
- One operation is submitted from the phone; its accepted transcript ID is
  `6132d24d-3dfc-42f0-bf32-c755ecafb673`. The device recovery file retains this ID
  and has zero source-draft text after acceptance.
- Force-stop while processing followed by restart restores the operation and
  retrieves a real LLM summary. Markdown renders on the phone.
- Title autosave from the phone is confirmed by reading the backend; original
  transcript view works; changing folder links is confirmed by backend readback.
- Cancellation keeps the summary; confirmed deletion removes only the generated
  smoke summary and retains the locked transcript. Test tracking state is cleared.
- Final buttons are above the system navigation bar; wide Markdown tables use
  horizontal scrolling instead of breaking words into narrow columns.
- No FATAL EXCEPTION, unhandled Flutter exception or RenderFlex overflow was
  found in the checked runtime log.

The phone check used `adb reverse tcp:8000 tcp:8000` and
`API_BASE_URL=http://127.0.0.1:8000/api/v1`. Direct HTTP to the LAN address
`192.168.1.100:8000` timed out from the phone during this run. USB transport does
not verify LAN connectivity, and no VPN, Wi-Fi or Firewall settings were changed.

The phone is left with the tested USB build. The ordinary `app-debug.apk` is built
for LAN (`192.168.1.100`). Both USB and LAN debug APKs are available in ignored
`mobile/build/device-check/`. The agent-created TXT and temporary device screenshot
and hierarchy files were removed. The test transcript remains according to API.

Only debug Android was built. iOS platform files exist but no iOS build/run was
performed; release signing/distribution and production backend are not validated.

Проверка диктофона/GigaAM 21.10.2026: [MOBILE_AUDIO_VALIDATION_2026-10-21.md](MOBILE_AUDIO_VALIDATION_2026-10-21.md). Реальная запись HONOR — 30:26,5; транскрипт оставлен для явной проверки пользователем. Физический Qwen-этап и iOS не объявляются проверенными.


Исправления интерфейса 21–22.10.2026: [MOBILE_UI_VALIDATION_2026-10-22.md](MOBILE_UI_VALIDATION_2026-10-22.md). 130 Flutter-тестов; на HONOR проверены записи 26,2 с (с Qwen) и 19,4 с (новая волна, оставлен черновик), редактор над русской клавиатурой и возврат к транскрипту. iOS не проверен.
