$ErrorActionPreference = "Stop"

$appRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFile = Join-Path $appRoot ".env"
if ((Get-Content $envFile -Raw) -notmatch "(?m)^HOST=127\.0\.0\.1\s*$") {
    throw "The app must listen only on 127.0.0.1 before publishing it through the private VPN."
}

$ready = Invoke-RestMethod -Uri "http://127.0.0.1:5000/api/health/ready" -TimeoutSec 5
if ($ready.status -ne "ready") {
    throw "The attendance app is not ready."
}

$tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
if (-not $tailscale) {
    throw "Install Tailscale, sign the host into your organization tailnet, and enable HTTPS certificates first."
}

& $tailscale.Source "serve" "--bg" "localhost:5000"
if ($LASTEXITCODE -ne 0) {
    throw "Tailscale Serve could not be configured. Check HTTPS certificate settings and device access policy."
}
& $tailscale.Source "serve" "status"
if ($LASTEXITCODE -ne 0) {
    throw "Could not read Tailscale Serve status."
}

Write-Host "Open the HTTPS tailnet URL above from an authorized employee device."
Write-Host "Do not use Tailscale Funnel; it would expose the app publicly."
