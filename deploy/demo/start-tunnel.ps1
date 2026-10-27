[CmdletBinding()]
param([string]$OwnerId, [switch]$FunctionsOnly)
$ErrorActionPreference = 'Stop'

function Get-TunnelContext {
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($repo.ToLowerInvariant())))).Replace('-', '').Substring(0, 20) }
    finally { $sha.Dispose() }
    $directory = Join-Path $env:LOCALAPPDATA 'YourMettings\logs'
    [pscustomobject]@{
        Id = $id; Repo = $repo; Directory = $directory
        State = Join-Path $directory "tunnel-$id.json"
        Log = Join-Path $directory "tunnel-$id.log"
        SshLog = Join-Path $directory "tunnel-$id-ssh.log"
        Mutex = "Local\YourMettings.Tunnel.$id"
        Event = "Local\YourMettings.Tunnel.Stop.$id"
        Task = "YourMettings-Tunnel-$id"
        Start = Join-Path $PSScriptRoot 'start-tunnel.ps1'
        PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    }
}
function Get-TunnelArguments($Context) {
    '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -OwnerId {1}' -f $Context.Start, $Context.Id
}
function Get-OwnedTask($Context) {
    $task = Get-ScheduledTask -TaskName $Context.Task -ErrorAction SilentlyContinue
    if ($task) {
        $actions = @($task.Actions)
        if ($actions.Count -ne 1 -or $actions[0].Execute -ine $Context.PowerShell -or $actions[0].Arguments -cne (Get-TunnelArguments $Context)) {
            throw "Task name collision: $($Context.Task). Refusing to modify it."
        }
    }
    $task
}
function Get-TunnelProcessRecord([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $info = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    if (-not $info -or -not $info.CommandLine) { throw 'Cannot verify process command line.' }
    [pscustomobject]@{ Pid = $ProcessId; StartTicks = $process.StartTime.ToUniversalTime().Ticks.ToString(); CommandLine = $info.CommandLine; Executable = $info.ExecutablePath }
}
function Stop-OwnedTunnelProcess($Record, $Context, [ValidateSet('Supervisor','Ssh')]$Kind) {
    if (-not $Record) { return }
    try {
        $live = Get-TunnelProcessRecord ([int]$Record.Pid)
        if ($live.StartTicks -cne [string]$Record.StartTicks -or $live.CommandLine -cne [string]$Record.CommandLine -or $live.Executable -ine [string]$Record.Executable) { return }
        if ($Kind -eq 'Supervisor') {
            if ($live.Executable -ine $Context.PowerShell -or -not $live.CommandLine.Contains($Context.Start) -or -not $live.CommandLine.Contains($Context.Id)) { return }
        } else {
            if ($live.Executable -ine $Context.Ssh -or -not $live.CommandLine.Contains('127.0.0.1:18000:127.0.0.1:8000') -or -not $live.CommandLine.Contains('alexey@194.117.80.169')) { return }
        }
        $process = Get-Process -Id $live.Pid -ErrorAction Stop
        if ($process.StartTime.ToUniversalTime().Ticks.ToString() -ceq $live.StartTicks) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
    } catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
        # Already exited.
    } catch {
        Write-Warning "Could not safely stop $Kind process: $($_.Exception.Message)"
    }
}
if ($FunctionsOnly) { return }
$context = Get-TunnelContext
if ($OwnerId -and $OwnerId -cne $context.Id) { throw 'OwnerId does not match this repository.' }
# Include OwnerId in the command line for verifiable ownership, even on manual launch.
if (-not $OwnerId) {
    & $context.PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $context.Start -OwnerId $context.Id
    exit $LASTEXITCODE
}
$mutex = New-Object Threading.Mutex($false, $context.Mutex)
$locked = $false
$stopEvent = $null
$sshProcess = $null
$sshRecord = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { Write-Output 'Tunnel supervisor is already running.'; return }
    New-Item -ItemType Directory -Path $context.Directory -Force | Out-Null
    if (-not (Test-Path -LiteralPath $context.Ssh)) { throw 'Windows OpenSSH client is not installed.' }
    $stopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $context.Event)
    $stopEvent.Reset() | Out-Null
    $supervisor = Get-TunnelProcessRecord $PID
    function Write-TunnelLog([string]$Message) {
        if ((Test-Path -LiteralPath $context.Log) -and (Get-Item -LiteralPath $context.Log).Length -gt 2MB) { Move-Item -LiteralPath $context.Log -Destination ($context.Log + '.previous') -Force }
        Add-Content -LiteralPath $context.Log -Value ('{0} {1}' -f [DateTime]::UtcNow.ToString('o'), $Message) -Encoding UTF8
    }
    function Save-TunnelState {
        $state = @{ Version = 1; OwnerId = $context.Id; Repo = $context.Repo; Supervisor = $supervisor; Ssh = $sshRecord }
        $temporary = $context.State + '.tmp'
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $context.State -Force
    }
    Save-TunnelState
    Write-TunnelLog 'Supervisor started. Authentication uses existing Windows OpenSSH configuration.'
    $delay = 3
    while (-not $stopEvent.WaitOne(0)) {
        if ((Test-Path -LiteralPath $context.SshLog) -and (Get-Item -LiteralPath $context.SshLog).Length -gt 2MB) { Move-Item -LiteralPath $context.SshLog -Destination ($context.SshLog + '.previous') -Force }
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $context.Ssh
        $startInfo.Arguments = '-N -T -p 22 -o IPQoS=none -o BatchMode=yes -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=15 -o ConnectionAttempts=1 -E "{0}" -R 127.0.0.1:18000:127.0.0.1:8000 alexey@194.117.80.169' -f $context.SshLog
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WorkingDirectory = $context.Repo
        $started = [DateTime]::UtcNow
        try {
            $sshProcess = [Diagnostics.Process]::Start($startInfo)
            try { $sshRecord = Get-TunnelProcessRecord $sshProcess.Id } catch { if (-not $sshProcess.HasExited) { $sshProcess.Kill() }; throw }
            Save-TunnelState
            Write-TunnelLog "SSH process started (PID $($sshProcess.Id)). See SSH log for connection failures."
            while (-not $sshProcess.WaitForExit(1000)) {
                if ($stopEvent.WaitOne(0)) { Stop-OwnedTunnelProcess $sshRecord $context Ssh; break }
            }
            $sshProcess.WaitForExit()
            Write-TunnelLog "SSH exited with code $($sshProcess.ExitCode)."
        } catch { Write-TunnelLog "SSH launch failed: $($_.Exception.Message)" }
        finally {
            if ($sshProcess) { if (-not $sshProcess.HasExited) { Stop-OwnedTunnelProcess $sshRecord $context Ssh }; $sshProcess.Dispose() }
            $sshProcess = $null; $sshRecord = $null
            Save-TunnelState
        }
        if (([DateTime]::UtcNow - $started).TotalSeconds -ge 60) { $delay = 3 }
        if ($stopEvent.WaitOne(0)) { break }
        Write-TunnelLog "Reconnecting in $delay seconds."
        if ($stopEvent.WaitOne($delay * 1000)) { break }
        $delay = [Math]::Min(30, $delay * 2)
    }
} finally {
    if ($locked) {
        Stop-OwnedTunnelProcess $sshRecord $context Ssh
        Remove-Item -LiteralPath $context.State -ErrorAction SilentlyContinue
        $mutex.ReleaseMutex()
    }
    if ($stopEvent) { $stopEvent.Dispose() }
    $mutex.Dispose()
}
