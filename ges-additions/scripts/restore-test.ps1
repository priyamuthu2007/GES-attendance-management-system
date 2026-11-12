<#
 Proves the newest backup actually restores. Loads it into a throwaway database, counts rows, drops it.
 Run monthly. Needs a MySQL account that can CREATE and DROP the scratch database (e.g. root), supplied via
 an options file like .backup.my.cnf but for that account.
#>
param(
  [Parameter(Mandatory)][string]$AdminDefaultsFile,
  [string]$BackupDir  = "D:\ges-backups",
  [string]$Database   = "ges_attendance",
  [string]$Scratch    = "ges_restore_test",
  [string]$Table      = "attendance_records",
  [string]$Mysql      = "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
)
$ErrorActionPreference = "Stop"

$zip = Get-ChildItem $BackupDir -Filter "$Database-*.sql.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $zip) { throw "No backups found in $BackupDir" }

$expected = (Get-Content "$($zip.FullName).sha256" -ErrorAction Stop).Trim()
if ((Get-FileHash $zip.FullName -Algorithm SHA256).Hash -ne $expected) { throw "Checksum mismatch for $($zip.Name). The backup is corrupt." }

$tmp = Join-Path $env:TEMP "ges-restore-$([guid]::NewGuid())"
Expand-Archive $zip.FullName -DestinationPath $tmp
$sql = (Get-ChildItem $tmp -Filter *.sql | Select-Object -First 1).FullName

try {
  & $Mysql "--defaults-extra-file=$AdminDefaultsFile" -e "DROP DATABASE IF EXISTS $Scratch; CREATE DATABASE $Scratch CHARACTER SET utf8mb4;"
  if ($LASTEXITCODE -ne 0) { throw "Could not create $Scratch" }
  cmd /c "`"$Mysql`" --defaults-extra-file=`"$AdminDefaultsFile`" $Scratch < `"$sql`""
  if ($LASTEXITCODE -ne 0) { throw "Restore failed" }
  & $Mysql "--defaults-extra-file=$AdminDefaultsFile" -N -e "SELECT COUNT(*) AS rows_in_$Table FROM $Scratch.$Table;"
  Write-Host "Restore test passed using $($zip.Name)"
} finally {
  & $Mysql "--defaults-extra-file=$AdminDefaultsFile" -e "DROP DATABASE IF EXISTS $Scratch;" | Out-Null
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
