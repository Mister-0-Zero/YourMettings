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

Current milestone: transcript form, UTF-8 TXT import, folder selection/creation,
atomic local draft recovery, idempotent submission, polling, restart recovery
and Markdown result display. Summary browsing/editing follows in the next step.
Tools and Profile remain MVP placeholders.

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
