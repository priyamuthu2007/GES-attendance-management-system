<# Registers a daily 02:00 backup as a Windows scheduled task. Run once in an Administrator PowerShell. #>
param([string]$Time = "02:00", [string]$OffsiteDir = "")

$script = Join-Path $PSScriptRoot "backup-mysql.ps1"
$argList = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
if ($OffsiteDir) { $argList += " -OffsiteDir `"$OffsiteDir`"" }

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argList
$trigger   = New-ScheduledTaskTrigger -Daily -At $Time
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName "GES MySQL Backup" -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Registered 'GES MySQL Backup' to run daily at $Time."
