# Temporary Java sockets use an ASCII path on this Windows development machine.
# All process environment changes are restored when Flutter exits.
$ErrorActionPreference = 'Stop'
$flutterCommand = Get-Command flutter.bat -ErrorAction Stop
$androidSdk = $env:ANDROID_HOME
if (-not $androidSdk) {
    $androidSdk = [Environment]::GetEnvironmentVariable('ANDROID_HOME', 'User')
}
if (-not $androidSdk -or -not (Test-Path -LiteralPath $androidSdk)) {
    throw 'ANDROID_HOME must point to the installed Android SDK.'
}
$socketDirectory = Join-Path $androidSdk 'tmp'
New-Item -ItemType Directory -Path $socketDirectory -Force | Out-Null
$previousJavaOptions = $env:JAVA_TOOL_OPTIONS
$flutterExitCode = 1
try {
    $socketOption = '-Djdk.net.unixdomain.tmpdir=' + $socketDirectory.Replace('\', '/')
    $env:JAVA_TOOL_OPTIONS = (@($previousJavaOptions, $socketOption) | Where-Object { $_ }) -join ' '
    & $flutterCommand.Source @args
    $flutterExitCode = $LASTEXITCODE
}
finally {
    $env:JAVA_TOOL_OPTIONS = $previousJavaOptions
}
exit $flutterExitCode
