<#
 GES MySQL backup. Run daily on the Anna Nagar host (see register-backup-task.ps1).

 One-time setup (MySQL admin session):
   CREATE USER 'ges_backup'@'localhost' IDENTIFIED BY 'REPLACE_WITH_A_UNIQUE_PASSWORD';
   GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER, EVENT ON ges_attendance.* TO 'ges_backup'@'localhost';
   -- if mysqldump complains about PROCESS: GRANT PROCESS ON *.* TO 'ges_backup'@'localhost';

 Then create .backup.my.cnf in the project root (it is NOT committed; add it to .gitignore):
   [client]
   user=ges_backup
   password=REPLACE_WITH_A_UNIQUE_PASSWORD
 and restrict it:  icacls .backup.my.cnf /inheritance:r /grant:r "SYSTEM:R" "Administrators:R"
#>
param(
  [string]$Database      = "ges_attendance",
  [string]$BackupDir     = "D:\ges-backups",
  [string]$OffsiteDir    = "",        # a second disk, NAS share or synced cloud folder; strongly recommended
  [int]   $KeepDays      = 30,
  [string]$DefaultsFile  = (Join-Path $PSScriptRoot "..\.backup.my.cnf"),
  [string]$MysqlDump     = "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqldump.exe"
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path $MysqlDump))     { throw "mysqldump not found at $MysqlDump. Pass -MysqlDump." }
if (-not (Test-Path $DefaultsFile))  { throw "Missing $DefaultsFile. See the header of this script." }
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$sql   = Join-Path $BackupDir "$Database-$stamp.sql"
$zip   = "$sql.zip"

# --result-file avoids PowerShell's UTF-16 redirection. --defaults-extra-file must be the first argument.
& $MysqlDump "--defaults-extra-file=$DefaultsFile" --single-transaction --routines --triggers `
  --default-character-set=utf8mb4 "--result-file=$sql" $Database
if ($LASTEXITCODE -ne 0) { throw "mysqldump failed with exit code $LASTEXITCODE" }

# A complete dump ends with this marker; a truncated one does not.
if (-not (Get-Content $sql -Tail 5 | Select-String -SimpleMatch "Dump completed")) {
  Remove-Item $sql -Force
  throw "Dump looks incomplete (no 'Dump completed' marker). Nothing was kept."
}

Compress-Archive -Path $sql -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $sql -Force
(Get-FileHash $zip -Algorithm SHA256).Hash | Set-Content "$zip.sha256" -Encoding ascii

if ($OffsiteDir) {
  New-Item -ItemType Directory -Force -Path $OffsiteDir | Out-Null
  Copy-Item $zip, "$zip.sha256" -Destination $OffsiteDir -Force
}

# Retention: delete backups older than $KeepDays in both locations.
foreach ($dir in @($BackupDir, $OffsiteDir) | Where-Object { $_ }) {
  Get-ChildItem $dir -Filter "$Database-*.sql.zip*" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } | Remove-Item -Force
}
Write-Host "Backup OK: $zip"
