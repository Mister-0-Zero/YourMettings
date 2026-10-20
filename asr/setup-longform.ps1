$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
& ./setup.ps1
if ($LASTEXITCODE -ne 0) { throw 'Base setup failed' }
$python = Join-Path $PSScriptRoot '.venv/Scripts/python.exe'
$asrRequirements = 'gigaam[longform] @ git+https://github.com/salute-developers/GigaAM.git@7447938d791c4f3e643386ee22c33777004293a5'
if (Test-Path 'requirements-longform-lock.txt') {
    & $python -m pip install $asrRequirements -c requirements-longform-lock.txt
} else {
    & $python -m pip install $asrRequirements
}
if ($LASTEXITCODE -ne 0) { throw 'Longform dependencies failed' }

# TorchCodec on Windows needs FFmpeg DLLs; a standalone ffmpeg.exe is insufficient.
$asrArchive = Join-Path $PSScriptRoot '.cache/ffmpeg-8.1.2-github.7z'
$asrExpectedHash = 'cba748035c21ce1431d0823c7a3a711f38616f89f87a265dceddf9b7f6749d2d'
New-Item -ItemType Directory -Force '.cache', 'tools/ffmpeg-shared' | Out-Null
if (-not (Test-Path $asrArchive)) {
    curl.exe -L --fail --retry 2 --connect-timeout 20 -o $asrArchive 'https://github.com/GyanD/codexffmpeg/releases/download/8.1.2/ffmpeg-8.1.2-full_build-shared.7z'
    if ($LASTEXITCODE -ne 0) { throw 'FFmpeg download failed' }
}
if ((Get-FileHash -LiteralPath $asrArchive -Algorithm SHA256).Hash -ne $asrExpectedHash) {
    throw "FFmpeg checksum mismatch. Remove the incomplete archive and retry: $asrArchive"
}
$asrEntries = @(tar -tf $asrArchive)
if ($LASTEXITCODE -ne 0) { throw 'Cannot list FFmpeg archive' }
foreach ($asrEntry in $asrEntries) {
    if (-not $asrEntry.StartsWith('ffmpeg-8.1.2-full_build-shared/') -or $asrEntry -match '(^|/)\.\.(/|$)') {
        throw 'Unsafe archive path'
    }
}
$asrUnpacked = Join-Path $PSScriptRoot '.cache/ffmpeg-unpacked'
New-Item -ItemType Directory -Force $asrUnpacked | Out-Null
tar -xf $asrArchive -C $asrUnpacked
if ($LASTEXITCODE -ne 0) { throw 'FFmpeg extraction failed' }
Copy-Item -LiteralPath (Join-Path $asrUnpacked 'ffmpeg-8.1.2-full_build-shared/bin') -Destination 'tools/ffmpeg-shared' -Recurse -Force
& $python -m pip check
if ($LASTEXITCODE -ne 0) { throw 'Dependency check failed' }
Write-Output 'Longform dependencies ready. Accept pyannote/segmentation-3.0 conditions and set HF_TOKEN before first use.'
