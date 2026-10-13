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

## Remaining physical-device checks

No Android phone was detected by ADB during development. LAN health timed out
from this agent session; this is not evidence of a backend API defect, and the
owner previously confirmed phone connectivity with VPN disabled.

1. Connect the phone with USB debugging and authorize this PC.
2. Run from mobile: `./scripts/flutter.ps1 run --dart-define=API_BASE_URL=http://192.168.1.100:8000/api/v1`.
3. Verify all four sections, native UTF-8 TXT import and paste/edit.
4. Start generation, navigate away, reopen and verify processing continues.
5. Close/restart before submission: check draft restoration.
6. Close/restart after acceptance: check state/summary restoration by transcript ID.
7. Verify Markdown, source view, autosave/back navigation, folder changes and
   cancel/confirm deletion. Network loss must preserve pending input/edits.

Only debug Android was built. iOS platform files exist but no iOS build/run was
performed; release signing/distribution and production backend are not validated.
