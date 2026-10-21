#Requires -Version 5.1
# Starts/checks PostgreSQL, Ollama, persistent GigaAM/VAD worker and FastAPI.
# ASR resource home and limits are read from backend/.env by dev_launcher.py.
[CmdletBinding()]
param(
    [string]$LanHost = '192.168.1.100',
    [string]$PostgresService = '',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$env:PYTHONIOENCODING = 'utf-8'
$taskBackend = Join-Path $PSScriptRoot 'backend'
$taskPython = Join-Path $taskBackend '.venv\Scripts\python.exe'
$taskLauncher = Join-Path $taskBackend 'scripts\dev_launcher.py'

try {
    if (-not (Test-Path -LiteralPath $taskPython)) {
        throw 'Не найден backend/.venv/Scripts/python.exe. Настройте окружение по backend/README.md.'
    }
    $taskArguments = @('-u', $taskLauncher, '--lan-host', $LanHost)
    if ($PostgresService) { $taskArguments += @('--postgres-service', $PostgresService) }
    if ($CheckOnly) { $taskArguments += '--check-only' }
    Push-Location -LiteralPath $taskBackend
    try {
        & $taskPython @taskArguments
        $taskResult = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $global:LASTEXITCODE = $taskResult
    if ($taskResult -ne 0) {
        Write-Host 'Запуск не завершён. Исправьте указанную причину и повторите запуск.' -ForegroundColor Red
    }
} catch {
    Write-Host ('Ошибка запуска: ' + $_.Exception.Message) -ForegroundColor Red
    $global:LASTEXITCODE = 1
}
# No explicit exit: a shortcut using -NoExit keeps diagnostics on screen.
