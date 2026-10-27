[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'start-tunnel.ps1') -FunctionsOnly
$context = Get-TunnelContext
$task = Get-OwnedTask $context
& (Join-Path $PSScriptRoot 'stop-tunnel.ps1')
if ($task) { Unregister-ScheduledTask -TaskName $context.Task -Confirm:$false }
Write-Output "Removed autostart task: $($context.Task). Logs were preserved."
