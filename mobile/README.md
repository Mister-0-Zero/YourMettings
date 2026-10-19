# YourMettings mobile

Flutter Android application; iOS platform files are provided for future macOS
builds. Russian Material 3 interface. Backend API: `../docs/API_CONTRACT.md`.

## Windows development

Tool locations on this machine:
- Flutter: `D:\tools\flutter`
- Android SDK: `D:\tools\android-sdk`
- Android Studio / bundled JDK: `D:\tools\android-studio`

Open this worktree in VS Code. Run commands from `mobile/`:

```powershell
flutter doctor -v
flutter devices
flutter pub get
flutter analyze
flutter test
./scripts/flutter.ps1 build apk --debug --dart-define=API_BASE_URL=http://192.168.1.100:8000/api/v1
./scripts/flutter.ps1 run --dart-define=API_BASE_URL=http://192.168.1.100:8000/api/v1
```

Enable USB debugging on the physical phone and authorize the connected PC.
If multiple devices are available, pass `-d <device-id>` to `flutter run`.
For Android Emulator, use `http://10.0.2.2:8000/api/v1` when the backend listens
on the PC loopback interface. No emulator is installed for the first test.

Implemented MVP: four sections, UTF-8 TXT import/paste/edit, folder selection,
atomic local draft recovery, idempotent submission, polling/restart recovery,
Markdown summary, nested folders, paginated lists, transcript view, title/content
editor with 800 ms autosave and save-on-exit, folder links and confirmed deletion.
Tools remains a placeholder; Profile provides persisted system/light/dark theme and blue/green accent settings. One active processing operation is tracked
at a time; navigation remains available during generation.

## Explicit real-backend verification

Run from `mobile/` only when the backend is available:

```powershell
dart run tool/backend_smoke.dart http://127.0.0.1:8000/api/v1
```

This opt-in check uses the mobile API client and creates fresh, uniquely named
non-confidential test folders and a transcript. It verifies Qwen options, stable
replay, changed-payload rejection, polling, Markdown edits, shared folder links,
folder tree deletion and server-side cleanup of unused transcripts. All objects
created by a successful run are deleted. It never replays a key after intentional
deletion. On failure, own fixture IDs remain in ignored
`build/mobile-smoke-<run>.json` for inspection; do not blindly resubmit deleted
operations. No existing user folders are deleted.

The real backend check passed through PC loopback. The complete transcript flow
and native TXT selection also passed on a physical HONOR 400 through USB.

## Data and development limits

Only non-confidential test data is allowed during this MVP. The local
recovery store keeps a single unfinished form and pending operation metadata,
not a library of completed meetings. Remove draft text after confirmed server
acceptance and retain transcript_id for restart recovery.

HTTP access is for development only. Release configuration must use HTTPS.
No backend secrets belong in Flutter or in Git. iOS is not verified on Windows.

On this Windows/JDK setup, use `scripts/flutter.ps1` for build/run commands.
It assigns Java's Unix-domain socket temporary directory to the SDK's ASCII
`tmp/` path for that process only. This avoids the observed loopback connection
failure without changing global Java options or security settings. Refresh the
terminal PATH after installation before using the script.

The debug manifest allows HTTP only for the development hosts listed in
`android/app/src/debug/res/xml/development_network_security.xml`. Release
cleartext is disabled and application configuration rejects a non-HTTPS URL.
Android backup is disabled to keep the temporary local transcript out of backups.

Kotlin incremental compilation is disabled in this project because the standard
Windows pub cache is on C: and this worktree is on D:. This prevents the confirmed
cross-drive cache failure; regular compilation remains enabled.

## Tested physical phone over USB

HONOR 400 / Android 16 passed the actual import, draft/operation recovery,
processing, Markdown, autosave, transcript, folder-link and deletion checks.
The installed USB test build reaches PC loopback through ADB reverse:

```powershell
adb reverse tcp:8000 tcp:8000
./scripts/flutter.ps1 run --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
```

The cable/ADB connection and running backend are required for this test setup.
Reapply `adb reverse` after reconnecting the phone. The LAN build still uses
`192.168.1.100` as documented above; direct LAN connectivity timed out during
this check and remains to be verified when that network path is available.
No VPN/Wi-Fi/Firewall configuration was changed.

Wide Markdown tables scroll horizontally. Lower page actions include the system
navigation inset so they remain reachable on phones with three-button navigation.


## MVP refinement (2026-10-14)

- New meeting header and wrapped navigation label use semantic centering.
- The transcript form has a collapsed processing-options block: brief/normal/
  detailed, six focus chips, and optional instructions (2000 characters).
  Options persist with drafts and accepted-operation metadata. Network replay
  retains the original payload and key; explicit generation retry uses the known ID.
- One Edit action opens the visual editor; the top checkmark flushes pending
  autosave and returns to formatted view. Failed saves keep the editor open.
- Folder deletion requires confirmation and uses `mode=with_contents&confirm=true`.
  Active-generation conflicts keep the tree intact and explain when to retry.
- The backend decides transcript cleanup. Confirmed deletion clears operation
  tracking; a missing accepted ID is checked via GET and never recreated via POST.
- Profile has one shared Material 3 UI for theme mode and blue/green accents.

See `../docs/MOBILE_VALIDATION.md` for the distinction between automated, real API
and actual HONOR checks, including the USB transport limitation.


## Visual editing and result UX (2026-10-19)

Summary editing uses Flutter Quill with a guarded Markdown conversion adapter.
Select text and use the compact pinned toolbar for bold/italic, headings, lists,
links and undo/redo. The checkmark saves and returns directly to the formatted
result. Long results keep Edit/Accept above the scrolling document; Accept returns
to the New meeting methods screen without deleting the server summary.

Tables and unsupported constructs appear as locked inserts and preserve their
original source. Supported surrounding text is visually editable. Ordinary
paragraphs, headings, lists, hard line breaks, task lists and horizontal rules
remain in a single editor. Images and some combined HTML/reference constructs
remain protected. New unsupported rich content
blocks saving rather than being silently removed. Ordinary whitespace/delimiters
in changed sections can be normalized to Markdown.

Profile also persists “Не спрашивать подтверждение при удалении папок”, default
off. This skips only the dialog after an explicit Delete folder action.

See [the 2026-10-19 validation report](../docs/MOBILE_UX_VALIDATION_2026-10-19.md)
for supported constructs, safety boundaries, tests, physical-phone checks and APKs.


## Editor correction (2026-10-19)

The conversion guard now compares adjacent Markdown text nodes by their joined
content: escaped punctuation must not make an ordinary paragraph read-only.
Standard horizontal rules render inside the editor instead of splitting it into
locked sections. Checkmark waits for a successful PATCH; Back returns to the
formatted view and asks Save / Discard when changes are still unsaved. Discard
restores the latest successfully saved snapshot (autosave remains enabled).
The meeting management menu is available only in the formatted view.

See [the editor-fix validation](../docs/MOBILE_EDITOR_FIX_VALIDATION_2026-10-19.md).


## Save/link/transcript correction (2026-10-20)

Common paragraph edits and overlapping inline styles now survive Markdown export
and reopening. Save progress/errors stay above the scrolling editor. Markdown
links open through the system handler; Quill's Open link action uses the same
handler. A down-arrow over long transcripts jumps to folders and processing
settings, dismisses the keyboard and hides after reaching that area.

See [the 2026-10-20 validation](../docs/MOBILE_SAVE_FIX_2026-10-20.md) for the
106 tests, real API and HONOR checks, normalization boundaries and the tested APK.
