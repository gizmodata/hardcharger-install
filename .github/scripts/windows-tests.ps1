# Tests of install.ps1 on Windows, with fixtures only (no credentials, no real release):
#
# 2. A local mirror of stand-in builds (tiny .exe files that print a version, compiled here;
#    no real release needed): install, switch, switch back without a download, the Get started
#    lines, -List, a corrupted zip, a build that doesn't run, the irm | iex form, uninstall one
#    and all.
# 3. The GitHub API path against fake_github.py: internal releases with and without a token,
#    latest, SHA256SUMS and GitHub's digest, a release without a Windows zip ("Windows builds start
#    with 0.3.0", as a file and through iex), the token kept off the storage host, anonymous public.
#
# The real releases are tested by windows-real-release.ps1, from public launch on.
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
# The server runs without TLS by default and the client defaults to TLS: the client line needs --tls=false.
Check 'Get started: the client line connects without TLS (--tls=false)' ($r.Out.Contains("\hardcharger.exe' --tls=false --username hardcharger"))
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

# ---- 3. the GitHub API path, against a local stand-in for GitHub (fake_github.py) ----------------
# Fixture releases: v9.9.8 (zip + SHA256SUMS), v9.9.9 (zip, GitHub's digest only; the latest) and
# v9.9.5 (no Windows zip, as every real release has so far). One server is "internal" (token
# required), one "public".
$gh = Join-Path $root 'gh'
foreach ($v in '9.9.8', '9.9.9') {
  New-Item -ItemType Directory -Force -Path (Join-Path $gh "v$v") | Out-Null
  Copy-Item (Join-Path $mirror "v$v\$asset") (Join-Path $gh "v$v\$asset")
}
Copy-Item (Join-Path $mirror 'v9.9.8\SHA256SUMS') (Join-Path $gh 'v9.9.8\SHA256SUMS')
New-Item -ItemType Directory -Force -Path (Join-Path $gh 'v9.9.5') | Out-Null
Set-Content -Path (Join-Path $gh 'v9.9.5\hardcharger-linux-amd64.tar.gz') -Value 'not windows'
$token = "fixture-token-$PID-not-a-secret"
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
$servers = @{}
foreach ($kind in 'internal', 'public') {
  $pf = Join-Path $root "$kind.port"
  $a = @((Join-Path $PSScriptRoot 'fake_github.py'), '--root', $gh, '--port', '0', '--port-file', $pf, '--log', (Join-Path $root "$kind.log"), '--token', $token)
  if ($kind -eq 'internal') { $a += '--private' }
  $proc = Start-Process -FilePath $py -ArgumentList $a -PassThru -WindowStyle Hidden
  foreach ($i in 1..100) { if ((Test-Path $pf) -and (Get-Content $pf -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
  $servers[$kind] = @{ Proc = $proc; Api = "http://127.0.0.1:$((Get-Content $pf).Trim())/api" }
}
try {
  $p3 = Join-Path $root 'hc-gh'
  $int = @{ HARDCHARGER_INSTALL_GITHUB_API = $servers.internal.Api; HARDCHARGER_INSTALL_TOKEN = 'none'; HARDCHARGER_VERSION = '' }
  $r = Invoke-Installer @('-Prefix', $p3) $int
  Check 'internal, no token: clear message, non-zero' ($r.Code -ne 0 -and $r.Out -match "couldn't find Hardcharger release 'latest'" -and $r.Out -match 'HARDCHARGER_INSTALL_TOKEN')

  $int.HARDCHARGER_INSTALL_TOKEN = $token
  $r = Invoke-Installer @('-Prefix', $p3) $int
  Check 'internal, token: latest installs 9.9.9 (GitHub digest)' ($r.Code -eq 0 -and $r.Out -match 'Installed Hardcharger 9.9.9' -and $r.Out -match "Checksum OK \(GitHub's asset digest\)")
  $r = Invoke-Installer @('-Prefix', $p3, '-Version', '9.9.8') $int
  Check 'internal, token: 9.9.8 (SHA256SUMS and digest)' ($r.Code -eq 0 -and $r.Out -match "Checksum OK \(SHA256SUMS and GitHub's asset digest\)")
  $r = Invoke-Installer @('-Prefix', $p3, '-Version', '9.9.5') $int
  Check 'no Windows zip: "Windows builds start with 0.3.0", non-zero' ($r.Code -ne 0 -and $r.Out.Contains("Windows builds start with 0.3.0: Hardcharger 9.9.5 has no $asset."))
  $env:HC_T = $token
  $iexOut = & $shell -NoProfile -Command "`$env:HARDCHARGER_PREFIX = '$p3'; `$env:HARDCHARGER_VERSION = '9.9.5'; `$env:HARDCHARGER_INSTALL_TOKEN = `$env:HC_T; `$env:HARDCHARGER_INSTALL_GITHUB_API = '$($servers.internal.Api)'; Get-Content -Raw '$installer' | Invoke-Expression; 'after-iex'" 2>&1 | Out-String
  $iexCode = $LASTEXITCODE
  Remove-Item Env:\HC_T
  Write-Host ($iexOut -replace '(?m)^', '  | ')
  Check 'no Windows zip, iex form: message and non-zero' ($iexCode -ne 0 -and $iexOut -match 'Windows builds start with 0\.3\.0' -and $iexOut -notmatch 'after-iex')
  Check 'the token never appears in the output' (-not ($r.Out.Contains($token)) -and -not ($iexOut.Contains($token)))
  $log = Get-Content (Join-Path $root 'internal.log')
  Check 'the token went to the API, never to the storage host' ((@($log | Where-Object { $_ -match '^/api/.* auth=yes$' }).Count -gt 0) -and (@($log | Where-Object { $_ -match '^/storage/' }).Count -gt 0) -and (@($log | Where-Object { $_ -match '^/storage/.* auth=yes$' }).Count -eq 0))

  $r = Invoke-Installer @('-Prefix', (Join-Path $root 'hc-anon')) @{ HARDCHARGER_INSTALL_GITHUB_API = $servers.public.Api; HARDCHARGER_INSTALL_TOKEN = 'none'; HARDCHARGER_VERSION = '' }
  Check 'public, anonymous: latest installs 9.9.9' ($r.Code -eq 0 -and $r.Out -match 'Installed Hardcharger 9.9.9' -and -not (Get-Content (Join-Path $root 'public.log') | Where-Object { $_ -match 'auth=yes' }))
} finally {
  foreach ($s in $servers.Values) { Stop-Process -Id $s.Proc.Id -Force -ErrorAction SilentlyContinue }
}

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
if ($failures) { Write-Host "$failures Windows test(s) failed"; exit 1 }
Write-Host "all Windows tests passed ($shell)"
