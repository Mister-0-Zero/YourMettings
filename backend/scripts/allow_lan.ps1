# Run explicitly in an Administrator PowerShell. Changes only a scoped inbound rule.
param(
    [string]$LanAddress = '192.168.1.100',
    [string]$RemoteSubnet = '192.168.1.0/24',
    [int]$Port = 8000
)
$ErrorActionPreference = 'Stop'
$taskPrincipal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $taskPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator to add this LAN-only firewall rule.'
}
if (Get-NetFirewallRule -Name 'YourMettingsBackendLAN' -ErrorAction SilentlyContinue) {
    throw 'Rule already exists; inspect it rather than overwriting it.'
}
New-NetFirewallRule -Name 'YourMettingsBackendLAN' -DisplayName 'YourMettings backend (LAN only)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -LocalAddress $LanAddress -RemoteAddress $RemoteSubnet -Profile Any
