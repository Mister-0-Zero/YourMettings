$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
function Check-Exit { if ($LASTEXITCODE -ne 0) { throw "Installation failed: $LASTEXITCODE" } }
if (-not (Test-Path '.venv/Scripts/python.exe')) { python -m venv .venv; Check-Exit }
$python = Join-Path $PSScriptRoot '.venv/Scripts/python.exe'
& $python -m pip install torch==2.10.0 torchaudio==2.10.0 --index-url https://download.pytorch.org/whl/cu126
Check-Exit
& $python -m pip install -r requirements.txt
Check-Exit
& $python -m pip check
Check-Exit
