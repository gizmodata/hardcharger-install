# Tests of install.ps1 on Windows.
#
# 1. Against the real release: until a release has hardcharger-windows-<arch>.zip, the installer
#    must say Windows builds are coming and fail, both run as a file and piped into iex. Once a
#    release has the zip, it must install it, and the server must answer SELECT 42.
# 2. Against a local mirror of two stand-in builds (tiny .exe files that print a version, compiled
#    here; Hardcharger has no Windows build to use yet): install, switch, switch back without a
#    download, -List, a corrupted zip, a build that doesn't run, uninstall one, uninstall all.
#
#   pwsh -File .github/scripts/windows-tests.ps1         (or powershell -File ... for 5.1)
# Continue: under 5.1 a native command's stderr is an error record, and the installer's own
# error message must reach the checks below instead of stopping this script.
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

# ---- 1. the real release --------------------------------------------------------------------
$prefix = Join-Path $root 'real'
$r = Invoke-Installer @('-Prefix', $prefix)
if ($r.Out -match 'Windows builds are coming in a later release') {
  Check 'real release: no Windows zip -> clear message' ($r.Out -match "has no $asset yet")
  Check 'real release: no Windows zip -> non-zero exit' ($r.Code -ne 0)
  Check 'real release: nothing installed' (-not (Test-Path (Join-Path $prefix 'bin')))
  $iexOut = & $shell -NoProfile -Command "`$env:HARDCHARGER_PREFIX = '$prefix'; Get-Content -Raw '$installer' | Invoke-Expression" 2>&1 | Out-String
  $iexCode = $LASTEXITCODE
  Write-Host ($iexOut -replace '(?m)^', '  | ')
  Check 'irm | iex form: clear message' ($iexOut -match 'Windows builds are coming in a later release')
  Check 'irm | iex form: non-zero exit' ($iexCode -ne 0)
} elseif ($r.Code -ne 0) {
  Check 'real release: installs, or says Windows builds are coming' $false
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

# ---- 2. stand-in builds from a local mirror -----------------------------------------------------
function New-StandIn([string]$ver, [int]$exitCode) {
  $dir = Join-Path $root "build-$ver\hardcharger-windows-$arch\bin"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $cs = Join-Path $root "standin-$ver.cs"
  Set-Content -Path $cs -Encoding ascii -Value "public static class P { public static int Main(string[] a) { System.Console.WriteLine(""Hardcharger $ver""); return $exitCode; } }"
  foreach ($n in 'hardcharger-server.exe', 'hardcharger.exe') {
    # Windows PowerShell's Add-Type can write a console .exe (PowerShell 7's can't). The command
    # goes base64-encoded, so neither shell's argument quoting can mangle it.
    $cmd = "Add-Type -OutputType ConsoleApplication -OutputAssembly '$(Join-Path $dir $n)' -Path '$cs'"
    & powershell -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)))
    if (-not (Test-Path (Join-Path $dir $n))) { throw "couldn't build the stand-in $n for $ver" }
  }
  $m = Join-Path $root "mirror\v$ver"
  New-Item -ItemType Directory -Force -Path $m | Out-Null
  Compress-Archive -Path (Join-Path $root "build-$ver\hardcharger-windows-$arch") -DestinationPath (Join-Path $m $asset) -Force
  $sum = (Get-FileHash -Algorithm SHA256 (Join-Path $m $asset)).Hash.ToLowerInvariant()
  Set-Content -Path (Join-Path $m 'SHA256SUMS') -Value "$sum  $asset" -Encoding ascii
}
New-StandIn '9.9.8' 0
New-StandIn '9.9.9' 0
New-StandIn '9.9.7' 3
$mirror = Join-Path $root 'mirror'
$prefix = Join-Path $root 'hc'
$bin = Join-Path $prefix 'bin'
function Current { $i = Get-Item -LiteralPath $bin -Force -ErrorAction SilentlyContinue; if ($i) { Split-Path -Leaf (Split-Path -Parent @($i.Target)[0]) } else { '' } }

$r = Invoke-Installer @('-Prefix', $prefix, '-Version', '9.9.9') @{ HARDCHARGER_INSTALL_MIRROR = $mirror }
Check 'mirror: install 9.9.9' ($r.Code -eq 0 -and $r.Out -match 'Checksum OK \(SHA256SUMS\)' -and (Current) -eq '9.9.9')
$v = try { & (Join-Path $bin 'hardcharger-server.exe') --version } catch { "$_" }
Check 'mirror: bin\hardcharger-server.exe runs 9.9.9' ($v -eq 'Hardcharger 9.9.9')
$r = Invoke-Installer @('-Prefix', $prefix, '-Version', 'v9.9.8') @{ HARDCHARGER_INSTALL_MIRROR = $mirror }
Check 'mirror: downgrade to 9.9.8' ($r.Code -eq 0 -and $r.Out -match 'Installed Hardcharger 9.9.8' -and $r.Out -match '\(was 9.9.9\)' -and (Current) -eq '9.9.8')
$r = Invoke-Installer @('-Prefix', $prefix) @{ HARDCHARGER_VERSION = '9.9.9'; HARDCHARGER_INSTALL_TOKEN = 'none'; HARDCHARGER_INSTALL_MIRROR = '' }
Check 'switch back to 9.9.9 without a download (env version)' ($r.Code -eq 0 -and $r.Out -match 'nothing downloaded' -and $r.Out -notmatch 'Downloading' -and (Current) -eq '9.9.9')
$r = Invoke-Installer @('-Prefix', $prefix, '-List')
Check '-List' ($r.Out -match '\* 9\.9\.9 \(current\)' -and $r.Out -match '    9\.9\.8')

$bad = Join-Path $root 'mirror-bad\v9.9.6'
New-Item -ItemType Directory -Force -Path $bad | Out-Null
Copy-Item (Join-Path $mirror "v9.9.8\$asset") (Join-Path $bad $asset)
$bytes = [IO.File]::ReadAllBytes((Join-Path $bad $asset)); $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 0xFF
[IO.File]::WriteAllBytes((Join-Path $bad $asset), $bytes)
Copy-Item (Join-Path $mirror 'v9.9.8\SHA256SUMS') (Join-Path $bad 'SHA256SUMS')
$r = Invoke-Installer @('-Prefix', $prefix, '-Version', '9.9.6') @{ HARDCHARGER_INSTALL_MIRROR = (Join-Path $root 'mirror-bad') }
Check 'corrupted zip refused' ($r.Code -ne 0 -and $r.Out -match "checksum mismatch for ${asset}: SHA256SUMS says" -and (Current) -eq '9.9.9' -and -not (Test-Path (Join-Path $prefix 'versions\9.9.6')))
$r = Invoke-Installer @('-Prefix', $prefix, '-Version', '9.9.7') @{ HARDCHARGER_INSTALL_MIRROR = $mirror }
Check 'a build that does not run is refused' ($r.Code -ne 0 -and $r.Out -match "doesn't run on this system, so it wasn't installed; 9.9.9 is still current" -and (Current) -eq '9.9.9')

# The documented `irm ... | iex` form: settings come from the environment, a failure must make
# the shell exit non-zero (and not close it, so iex throws instead of calling exit).
$iexPrefix = Join-Path $root 'iex'
$iexOut = & $shell -NoProfile -Command "`$env:HARDCHARGER_PREFIX = '$iexPrefix'; `$env:HARDCHARGER_VERSION = '9.9.8'; `$env:HARDCHARGER_INSTALL_MIRROR = '$mirror'; Get-Content -Raw '$installer' | Invoke-Expression" 2>&1 | Out-String
$iexCode = $LASTEXITCODE
Write-Host ($iexOut -replace '(?m)^', '  | ')
Check 'iex form: installs from the environment' ($iexCode -eq 0 -and $iexOut -match 'Installed Hardcharger 9.9.8' -and (Test-Path (Join-Path $iexPrefix 'bin\hardcharger-server.exe')))
$iexOut = & $shell -NoProfile -Command "`$env:HARDCHARGER_PREFIX = '$iexPrefix'; `$env:HARDCHARGER_VERSION = '9.9.7'; `$env:HARDCHARGER_INSTALL_MIRROR = '$mirror'; Get-Content -Raw '$installer' | Invoke-Expression; 'after-iex'" 2>&1 | Out-String
$iexCode = $LASTEXITCODE
Write-Host ($iexOut -replace '(?m)^', '  | ')
Check 'iex form: a failure is an error, with the message, and exits non-zero' ($iexCode -ne 0 -and $iexOut -match "doesn't run on this system" -and $iexOut -notmatch 'after-iex')

$r = Invoke-Installer @('-Prefix', $prefix, '-Uninstall', '-Version', '9.9.8')
Check 'uninstall 9.9.8' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $prefix 'versions\9.9.8')) -and (Current) -eq '9.9.9')
$r = Invoke-Installer @('-Prefix', $prefix, '-Uninstall')
Check 'uninstall everything' ($r.Code -eq 0 -and -not (Test-Path $prefix) -and (Test-Path (Join-Path $root 'build-9.9.9')))

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
if ($failures) { Write-Host "$failures Windows test(s) failed"; exit 1 }
Write-Host "all Windows tests passed ($shell)"
