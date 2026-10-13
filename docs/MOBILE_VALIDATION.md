# Mobile validation

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
