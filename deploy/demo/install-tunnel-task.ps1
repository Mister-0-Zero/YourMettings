[CmdletBinding()]
param([switch]$StartNow)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'start-tunnel.ps1') -FunctionsOnly
$context = Get-TunnelContext
if (-not (Test-Path -LiteralPath $context.Ssh)) { throw 'Windows OpenSSH client is not installed.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$existing = Get-OwnedTask $context
$action = New-ScheduledTaskAction -Execute $context.PowerShell -Argument (Get-TunnelArguments $context) -WorkingDirectory $context.Repo
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
# InteractiveToken intentionally runs only while this user is logged on; no password is saved.
Register-ScheduledTask -TaskName $context.Task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'YourMettings local outbound SSH tunnel; existing SSH config; current interactive user.' -Force | Out-Null
if ($StartNow) { Start-ScheduledTask -TaskName $context.Task }
Write-Output "Installed task: $($context.Task)"
Write-Output "Start manually: Start-ScheduledTask -TaskName '$($context.Task)'"
Write-Output "Logs: $($context.Directory)"
