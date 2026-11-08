param(
    [Parameter(Mandatory = $true)]
    [string]$PythonPath
)

$ErrorActionPreference = "Stop"
$appRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$logRoot = Join-Path $appRoot "logs"
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
Set-Location $appRoot

if (-not (Test-Path $PythonPath)) {
    throw "Python virtual environment was not found: $PythonPath"
}

$logPath = Join-Path $logRoot "attendance.log"
& $PythonPath "-m" "waitress" "--listen=127.0.0.1:5000" "wsgi:app" *>> $logPath
exit $LASTEXITCODE
