# Mobile UX validation — 2026-10-19

Worktree: `D:\programming\VSCode\project\YourMettings-mobile`, branch `mobile`.
Backend code, PostgreSQL configuration/migrations and `docs/API_CONTRACT.md` were not changed.

## Delivered behavior

- The result document scrolls beneath pinned Edit and Accept actions. No bottom-of-document trip is required.
- Accept clears finished local tracking/draft and returns to the New meeting methods screen. A real backend GET confirmed the saved summary still existed after acceptance.
- Edit opens the visual editor in one tap. Checkmark flushes serialized autosave and closes the editor to the updated result. Folder summaries return directly to formatted view in place.
- Automatic polling shows a spinner and “Qwen обрабатывает совещание…”, not invented percentages or a manual status button. Network errors keep the accepted ID/key; automatic checking continues beyond four network failures. A manual connection-recovery action remains available only on error. Qwen failure has an explicit generation-retry action.
- Folder deletion has the exact short confirmation requested. Profile has a persistent opt-out, false by default and for legacy preferences. Even with opt-out, an explicit Delete folder action is required. Server errors do not remove the tree optimistically.

## Editor decision and Markdown safety

Implemented with [Flutter Quill 11.6.0](https://pub.dev/packages/flutter_quill) and
[markdown_quill 4.3.0](https://pub.dev/packages/markdown_quill). Flutter Quill supplies
native rich text selection/editing, toolbar controls, undo/redo and Russian
localization. markdown_quill supplies the conversion boundary to the existing
Markdown API; the backend format did not change. The prototype and tests verified
this combination in the installed Flutter SDK. [Fleather](https://pub.dev/packages/fleather)
and [AppFlowy Editor](https://pub.dev/packages/appflowy_editor) were also considered
from their official package documentation, but were not installed or tested.

The converter documents limitations, including image alternative text and
exclusive block attributes. The prototype also demonstrated a hard-line-break
roundtrip difference. The user explicitly chose to keep complex content as
immutable inserts while visually editing supported sections.

The adapter partitions source with the Markdown package's block syntaxes.
An editable section must pass semantic Markdown -> Delta -> Markdown checking.
Protected sections never enter a converter or editable input. Source text, order,
line endings and syntax of those sections are retained exactly. Unchanged editable
sections also return their original source rather than regenerated Markdown.
Changed sections are checked again before autosave and explicit save; an unsafe
conversion blocks both save and exit, retains the edits, and asks the user to undo.
Temporary trailing paragraph spaces from Android IME are treated according to
Markdown whitespace semantics, without weakening checks on code or protected data.

Editable supported cases verified by tests: paragraphs, new paragraphs, H1–H6,
bold, italic, bullet/numbered lists, ordinary inline links; compatible simple
quotes and code blocks also roundtrip. Toolbar offers the required formatting,
links and undo/redo. It scrolls horizontally on narrow screens.

Limitations are visible rather than silently destructive:

- Tables, images, raw HTML, task-list variants, hard Markdown line breaks and
  other non-equivalent constructs are displayed as locked sections. Their content
  cannot be edited or deleted through the visual input; a normal paragraph can be
  added after an insert.
- Reference definitions and raw HTML with cross-block context are kept as a single
  dependency group; in such documents a larger region can be protected.
- Selection/formatting stays within an editable section and does not cross an
  immutable insert. Unsupported newly pasted objects/formatting block saving and
  can be undone; new image insertion is not offered.
- Markdown delimiters and ordinary trailing spaces/blank separators in changed
  sections can be normalized. Original hard breaks and code whitespace are guarded.
  Exact source syntax of locked sections is preserved, rather than claiming a
  universal lossless Markdown converter.

## Automated verification

`flutter analyze`: no issues. `flutter test`: **76 passed**. Android debug APK
builds succeeded for USB and LAN base URLs. Tests cover:

- Formatting using the actual Quill toolbar in both themes at 320 px; rich editor
  replaces the Markdown TextField, checkmark returns to rendered Markdown, and
  formatting survives reopening.
- All required formatting types, normal paragraphs, link retention and imports.
- Exact locked content after edits/reopen: tables and alignment, image alt/title,
  HTML, nested blocks, task lists, hard breaks, CRLF and CR reference definitions,
  Setext headings and fenced code with internal blank lines.
- Inserting a paragraph after a table does not create another table row.
- Every prefix of Android text input, including intermediate trailing spaces.
  This regression reproduced the guard problem seen on the phone and prevented
  suppressing a real conversion loss just to make typing work.
- Unsafe conversion cancels autosave and blocks explicit save, including after a
  title change. Network-save failure retains editor changes. Existing serialized
  saves, debounce and save-on-exit tests remain.
- Long-document pinned actions, acceptance to home, automatic polling recovery
  beyond four failures using GET only, Qwen failure UI, legacy preference migration,
  both explicit deletion modes, short dialog, 409 rollback and preference restart.

The first Quill plugin build added SDK Platform 34 to the already configured
`D:\tools\android-sdk`; no SDK directory was moved.

## Actual HONOR 400 / Android 16 verification

The debug APK was installed with data preserved. No user draft/pending operation
was present before the test. Only fresh own non-confidential fixtures were used.
The real backend was reached through ADB reverse, with no VPN/firewall/Wi-Fi edits.

- Own transcript was submitted through the UI; the spinner and Qwen text appeared.
  Polling displayed a real generated result automatically. Result actions stayed
  pinned after scrolling a long document.
- Cold start without the reverse mapping showed connection loss and retained the
  same accepted ID. Restoring the mapping brought the result back automatically,
  without pressing status/recovery buttons or creating a duplicate operation.
- Visual text insertion, native long-press word selection and Bold toolbar action
  were checked. Backend readback contained `**Edited**`, retained the inline URL
  and the exact table source. Reopening in light theme retained the formatting.
- New paragraph after the locked table was typed on the phone and read back from
  the backend, with the table unchanged. The initial trailing-space guard issue
  was fixed, regression-tested and retested successfully on the device.
- Removing the reverse mapping after the existing HTTP keepalive expired caused
  an actual visual-editor save failure. The editor kept the input; restoring the
  mapping and confirming saved it and returned directly to the result.
- Accept returned to the creation-methods home, cleared tracking, and retained the
  server summary. Both light and dark editor views were inspected on the phone.
- Short deletion dialog and Cancel were checked. Opt-out was enabled via Profile,
  survived a cold restart, and an explicit Delete folder removed the own folder
  and summary without another dialog. Backend summary/processing returned 404.
- Original preferences were restored: dark/green and deletion confirmation on.
  The local test draft/tracking is empty. Unrelated server objects were preserved.

Own cleanup IDs: folder `56a3f833-5560-4506-821e-c70fa4d39bdb`, transcript
`dfd3ecfa-d731-433d-bebd-2ad59d878fcf`, summary
`49c65b52-e5e8-4c50-8003-395697365a0d`.

Qwen failure and long repeated network-failure behavior are automated/mock checks;
no production Qwen failure was artificially triggered. Only Android debug was
built. iOS, release signing/distribution and direct LAN connectivity were not verified.

## Commits and APKs

- `8a3e321` — result actions, navigation and polling.
- `257a97c` — short confirmation and persistent opt-out.
- `fa1ceff` — visual editor and locked Markdown safety.
- `52f452f` — Android IME trailing-space fix and regression test.

All implementation commits were pushed to `origin/mobile` after checks.

Artifacts in ignored `mobile/build/device-check/`:

- `YourMettings-2026-10-19-USB-debug.apk` and `YourMettings-USB-debug.apk` — tested
  phone build, `http://127.0.0.1:8000/api/v1`, requires `adb reverse tcp:8000 tcp:8000`.
- `YourMettings-LAN-debug.apk` — `http://192.168.1.100:8000/api/v1`.
  The ordinary `mobile/build/app/outputs/flutter-apk/app-debug.apk` is also LAN.

The phone is left with the tested USB build, without diagnostic mode. Direct LAN
transport is a separate unverified environment path, not an API failure claim.
