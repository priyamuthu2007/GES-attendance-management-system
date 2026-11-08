$ErrorActionPreference = "Stop"

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this setup from PowerShell as Administrator."
}

$appRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFile = Join-Path $appRoot ".env"
if (-not (Test-Path $envFile)) {
    throw "Copy .env.example to .env and configure MySQL credentials and FLASK_SECRET_KEY first."
}
$envText = Get-Content $envFile -Raw
foreach ($key in @(
    "MYSQL_USER",
    "MYSQL_PASSWORD",
    "MYSQL_MIGRATION_USER",
    "MYSQL_MIGRATION_PASSWORD",
    "FLASK_SECRET_KEY"
)) {
    if ($envText -notmatch "(?m)^$key=\S.+$") {
        throw "Set $key in .env before installing the host."
    }
}
if ($envText -notmatch "(?m)^HOST=127\.0\.0\.1\s*$") {
    throw "Set HOST=127.0.0.1; the app must remain bound to loopback behind the private VPN."
}

$mysqlService = Get-Service -Name "MySQL*" -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $mysqlService) {
    $mysqlService = Get-Service -Name "MariaDB*" -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
if (-not $mysqlService) {
    throw "A MySQL or MariaDB Windows service was not found. Install and configure MySQL Community Server first."
}
if ($mysqlService.StartType -ne "Automatic") {
    Set-Service -Name $mysqlService.Name -StartupType Automatic
}
if ($mysqlService.Status -ne "Running") {
    Start-Service -Name $mysqlService.Name
    (Get-Service -Name $mysqlService.Name).WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds(60)
    )
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) {
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if (-not $launcher) {
        throw "Install Python 3.11+ and make python.exe or py.exe available in PATH."
    }
    Push-Location $appRoot
    try {
        & $launcher.Source "-3" "-m" "venv" ".venv"
        if ($LASTEXITCODE -ne 0) { throw "Python virtual environment creation failed." }
    } finally {
        Pop-Location
    }
} else {
    Push-Location $appRoot
    try {
        & $python.Source "-m" "venv" ".venv"
        if ($LASTEXITCODE -ne 0) { throw "Python virtual environment creation failed." }
    } finally {
        Pop-Location
    }
}

$venvPython = Join-Path $appRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    throw "Could not create the Python virtual environment."
}

Push-Location $appRoot
try {
    & $venvPython "-m" "pip" "install" "--upgrade" "pip"
    if ($LASTEXITCODE -ne 0) { throw "pip update failed." }
    & $venvPython "-m" "pip" "install" "-r" "requirements.txt"
    if ($LASTEXITCODE -ne 0) { throw "Python dependency installation failed." }
    & $venvPython "-m" "unittest" "discover" "-s" "tests" "-v"
    if ($LASTEXITCODE -ne 0) { throw "Tests failed; the host was not installed." }
    & $venvPython "manage.py" "init-db"
    if ($LASTEXITCODE -ne 0) { throw "MySQL schema setup failed; the host was not installed." }
} finally {
    Pop-Location
}

$taskName = "GES Smart Attendance Host"
$runnerPath = Join-Path $appRoot "scripts\run-windows-host.ps1"
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`" -PythonPath `"$venvPython`"" `
    -WorkingDirectory $appRoot
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$serviceAccount = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $serviceAccount `
    -Description "Starts the GES attendance Flask app when the office host boots." `
    -Force | Out-Null

Start-ScheduledTask -TaskName $taskName
$ready = $false
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:5000/api/health/ready" -TimeoutSec 2
        if ($response.status -eq "ready") {
            $ready = $true
            break
        }
    } catch {
        Start-Sleep -Seconds 2
    }
}

if (-not $ready) {
    $logPath = Join-Path $appRoot "logs\attendance.log"
    throw "The host did not become ready. Check $logPath and the Scheduled Task '$taskName'."
}

Write-Host "Attendance host is ready and will start automatically at boot."
Write-Host "The app listens on 127.0.0.1:5000; it is not exposed directly to the LAN."
Write-Host "Sign in to Tailscale and enable tailnet HTTPS certificates, then run scripts\publish-windows-host.ps1."
