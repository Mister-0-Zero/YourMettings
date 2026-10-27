[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'start-tunnel.ps1') -FunctionsOnly
$context = Get-TunnelContext
$task = Get-OwnedTask $context
$state = $null
if (Test-Path -LiteralPath $context.State) {
    $state = Get-Content -LiteralPath $context.State -Raw | ConvertFrom-Json
    if ($state.OwnerId -cne $context.Id -or $state.Repo -ine $context.Repo) { throw 'State ownership mismatch. Refusing to stop processes.' }
}
try {
    $event = [Threading.EventWaitHandle]::OpenExisting($context.Event)
    try { $event.Set() | Out-Null } finally { $event.Dispose() }
} catch [Threading.WaitHandleCannotBeOpenedException] {
    # No running supervisor in this logon session.
}
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ((Test-Path -LiteralPath $context.State) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
if ($state) {
    Stop-OwnedTunnelProcess $state.Ssh $context Ssh
    Stop-OwnedTunnelProcess $state.Supervisor $context Supervisor
}
# Stop only an action verified to belong to this repository. This does not disable the logon trigger.
if ($task) { Stop-ScheduledTask -TaskName $context.Task }
Write-Output 'Tunnel stopped. The logon task remains installed; use remove-tunnel-task.ps1 to disable autostart.'
