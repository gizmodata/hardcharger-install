# The real-release check for install.ps1: install the latest gizmodata/hardcharger release on
# this Windows machine and query the server, or, for a release without a Windows zip (before 0.3.0),
# check that the installer says Windows builds start with 0.3.0 (as a file and through iex).
#
# It runs only once the releases are public. While they are internal (an anonymous request to
# github.com gets 404), it says so and passes: that pass is NOT coverage of the real releases.
#
#   pwsh -File .github/scripts/windows-real-release.ps1
$ErrorActionPreference = 'Continue'
$installer = (Resolve-Path (Join-Path $PSScriptRoot '..\..\install.ps1')).Path
$shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
$root = Join-Path ([IO.Path]::GetTempPath()) "hc-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
$failures = 0

function Invoke-Installer([string[]]$installerArgs, [hashtable]$envs = @{}) {
  $saved = @{}
  foreach ($k in $envs.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
  try {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $installer @installerArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
  Write-Host ($out -replace '(?m)^', '  | ')
  return @{ Out = $out; Code = $code }
}
function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "ok   $name" -ForegroundColor Green } else { Write-Host "FAIL $name" -ForegroundColor Red; $script:failures++ }
}

$cpu = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
$arch = if ($cpu -eq 'ARM64') { 'arm64' } else { 'amd64' }
$asset = "hardcharger-windows-$arch.zip"
Write-Host "shell: $shell $($PSVersionTable.PSVersion); arch: $arch"

# Public or internal, by an anonymous request to github.com (not the rate-limited API): 200 means
# public, 404 internal; anything else is an error, so a GitHub hiccup can't pass as "internal".
$code = 0
try {
  $resp = Invoke-WebRequest -Uri 'https://github.com/gizmodata/hardcharger/releases/latest' -Method Head -UseBasicParsing
  $code = [int]$resp.StatusCode
} catch {
  if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = -1 }
}
if ($code -ne 200 -and $code -ne 404) { Write-Host "error: couldn't tell whether the releases are public (HTTP $code)"; exit 1 }
$public = ($code -eq 200)
if (-not $public) {
  Write-Host '::notice title=Real-release check not run::gizmodata/hardcharger releases are internal; the real-release check runs at public launch.'
  Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
  exit 0
}
Write-Host 'gizmodata/hardcharger releases are public: running the real-release check'

# ---- 1. the real release --------------------------------------------------------------------
$prefix = Join-Path $root 'real'
$r = Invoke-Installer @('-Prefix', $prefix)
if ($r.Out -match 'Windows builds start with 0\.3\.0') {
  Check 'real release: no Windows zip -> clear message' ($r.Out.Contains("has no $asset."))
  Check 'real release: no Windows zip -> non-zero exit' ($r.Code -ne 0)
  Check 'real release: nothing installed' (-not (Test-Path (Join-Path $prefix 'bin')))
  $iexOut = & $shell -NoProfile -Command "`$env:HARDCHARGER_PREFIX = '$prefix'; Get-Content -Raw '$installer' | Invoke-Expression" 2>&1 | Out-String
  $iexCode = $LASTEXITCODE
  Write-Host ($iexOut -replace '(?m)^', '  | ')
  Check 'irm | iex form: clear message' ($iexOut -match 'Windows builds start with 0\.3\.0')
  Check 'irm | iex form: non-zero exit' ($iexCode -ne 0)
} elseif ($r.Code -ne 0) {
  Check 'real release: installs, or says Windows builds start with 0.3.0' $false
} else {
  Check 'real release: installs' $true
  $srv = Join-Path $prefix 'bin\hardcharger-server.exe'
  $pw = "e2e-$PID"
  $env:HARDCHARGER_ADMIN_PASSWORD = $pw
  $p = Start-Process -FilePath $srv -ArgumentList @('--host', '127.0.0.1', '--port', '31471', '--health-port', '31472', '--database', ':memory:') -PassThru -WindowStyle Hidden
  try {
    $healthy = $false
    foreach ($i in 1..120) { try { Invoke-RestMethod 'http://127.0.0.1:31472/health' | Out-Null; $healthy = $true; break } catch { Start-Sleep -Milliseconds 500 } }
    Check 'real release: server healthy' $healthy
    $tok = (Invoke-RestMethod -Method Post 'http://127.0.0.1:31471/warp/v1/auth/token' -ContentType 'application/json' -Body (@{ grant_type = 'password'; username = 'hardcharger'; password = $pw } | ConvertTo-Json)).access_token
    $h = @{ Authorization = "Bearer $tok" }
    $sid = (Invoke-RestMethod -Method Post 'http://127.0.0.1:31471/warp/v1/sessions' -Headers $h -ContentType 'application/json' -Body '{}').session_id
    $res = Invoke-RestMethod -Method Post "http://127.0.0.1:31471/warp/v1/sessions/$sid/statements" -Headers $h -ContentType 'application/json' -Body '{"sql": "SELECT CASE WHEN 6 * 7 = 42 THEN 42 ELSE error(''wrong'') END"}'
    Check 'real release: SELECT 42' ($res.state -eq 'succeeded')
  } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}


Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
if ($failures) { Write-Host "$failures real-release check(s) failed"; exit 1 }
Write-Host "real-release check passed ($shell)"
