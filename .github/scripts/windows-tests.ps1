# Tests of install.ps1 on Windows, with fixtures only (no credentials, no real release):
#
# 2. A local mirror of stand-in builds (tiny .exe files that print a version, compiled here;
#    no real release needed): install, switch, switch back without a download, the Get started
#    lines, -List, a corrupted zip, a build that doesn't run, the irm | iex form, uninstall one
#    and all. The mirror's checksums come from a stand-in for github.com's release downloads
#    (fake_github.py over the mirror folder), never from the mirror: a mirror's own build with its
#    own SHA256SUMS is refused, a release with no checksum anywhere is refused unless
#    HARDCHARGER_INSTALL_SHA256 gives one, and an http mirror needs HARDCHARGER_INSTALL_ALLOW_HTTP.
#    Also: versions with a line break or a non-ASCII digit, the https-only test overrides, and the
#    CPU target (baseline refused: Windows has one build; auto and optimized install it).
# 3. The GitHub API path against fake_github.py: internal releases with and without a token,
#    latest, SHA256SUMS and GitHub's digest, a release without a Windows zip ("Windows builds start
#    with 0.3.0", as a file and through iex), the token kept off the storage host, anonymous public.
#
# The real releases are tested by windows-real-release.ps1.
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
# github.com's release downloads, for the SHA256SUMS the installer checks a mirror's zip against.
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
$pfw = Join-Path $root 'web.port'
$webProc = Start-Process -FilePath $py -ArgumentList @((Join-Path $PSScriptRoot 'fake_github.py'), '--root', $mirror, '--port', '0', '--port-file', $pfw, '--log', (Join-Path $root 'web.log')) -PassThru -WindowStyle Hidden
foreach ($i in 1..100) { if ((Test-Path $pfw) -and (Get-Content $pfw -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
# Every installer run below inherits these (the stand-ins are plain http: the test flag allows that).
$env:HARDCHARGER_INSTALL_GITHUB_WEB = "http://127.0.0.1:$((Get-Content $pfw).Trim())/web"
$env:HARDCHARGER_INSTALL_TEST_INSECURE = '1'
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
# The CPU target: Windows has one build, so baseline (Linux x86-64 only) is refused, before anything changes.
$r = Invoke-Installer @('-Prefix', $prefix, '-Version', '9.9.8') @{ HARDCHARGER_CPU_TARGET = 'baseline'; HARDCHARGER_INSTALL_MIRROR = $mirror }
Check 'HARDCHARGER_CPU_TARGET=baseline: Windows has one build' ($r.Code -ne 0 -and $r.Out.Contains('the baseline build is for Linux on x86-64 only, and Windows has one build for every CPU') -and $r.Out -notmatch 'Downloading' -and (Current) -eq '9.9.9')
$r = Invoke-Installer @('-Prefix', $prefix, '-CpuTarget', 'fastest')
Check 'a wrong -CpuTarget is refused' ($r.Code -ne 0 -and $r.Out.Contains("HARDCHARGER_CPU_TARGET/-CpuTarget must be one of auto, optimized, baseline, not 'fastest'"))
$r = Invoke-Installer @('-Prefix', $prefix, '-Version', '9.9.8', '-CpuTarget', 'Optimized') @{ HARDCHARGER_INSTALL_TOKEN = 'none'; HARDCHARGER_INSTALL_MIRROR = '' }
Check '-CpuTarget optimized: the one build, switched to without a download' ($r.Code -eq 0 -and $r.Out -match 'nothing downloaded' -and (Current) -eq '9.9.8')
$r = Invoke-Installer @('-Prefix', $prefix, '-Version', '9.9.9') @{ HARDCHARGER_CPU_TARGET = 'auto'; HARDCHARGER_INSTALL_TOKEN = 'none'; HARDCHARGER_INSTALL_MIRROR = '' }
Check 'HARDCHARGER_CPU_TARGET=auto: switched back to 9.9.9' ($r.Code -eq 0 -and (Current) -eq '9.9.9')

# A prefix with nothing installed, so these downloads aren't skipped as "installed already".
$sp = Join-Path $root 'hc-mirror'
$bad = Join-Path $root 'mirror-bad\v9.9.8'
New-Item -ItemType Directory -Force -Path $bad | Out-Null
Copy-Item (Join-Path $mirror "v9.9.8\$asset") (Join-Path $bad $asset)
$bytes = [IO.File]::ReadAllBytes((Join-Path $bad $asset)); $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 0xFF
[IO.File]::WriteAllBytes((Join-Path $bad $asset), $bytes)
Copy-Item (Join-Path $mirror 'v9.9.8\SHA256SUMS') (Join-Path $bad 'SHA256SUMS')
$r = Invoke-Installer @('-Prefix', $sp, '-Version', '9.9.8') @{ HARDCHARGER_INSTALL_MIRROR = (Join-Path $root 'mirror-bad') }
Check 'corrupted zip refused' ($r.Code -ne 0 -and $r.Out -match "checksum mismatch for ${asset}: SHA256SUMS says" -and -not (Test-Path (Join-Path $sp 'versions\9.9.8')))
# A mirror's own, valid build of 9.9.8 (one file more), with a SHA256SUMS that matches it: the
# checksums come from GitHub's release, so it is refused.
$evilBuild = Join-Path $root 'evil-build'
Copy-Item -Recurse (Join-Path $root "build-9.9.8\hardcharger-windows-$arch") (Join-Path $evilBuild "hardcharger-windows-$arch")
Set-Content -Path (Join-Path $evilBuild "hardcharger-windows-$arch\NOT-THE-REAL-BUILD.txt") -Value 'x' -Encoding ascii
$evil = Join-Path $root 'mirror-evil\v9.9.8'
New-Item -ItemType Directory -Force -Path $evil | Out-Null
Compress-Archive -Path (Join-Path $evilBuild "hardcharger-windows-$arch") -DestinationPath (Join-Path $evil $asset) -Force
Set-Content -Path (Join-Path $evil 'SHA256SUMS') -Value "$((Get-FileHash -Algorithm SHA256 (Join-Path $evil $asset)).Hash.ToLowerInvariant())  $asset" -Encoding ascii
$r = Invoke-Installer @('-Prefix', $sp, '-Version', '9.9.8') @{ HARDCHARGER_INSTALL_MIRROR = (Join-Path $root 'mirror-evil') }
$good98 = (Get-FileHash -Algorithm SHA256 (Join-Path $mirror "v9.9.8\$asset")).Hash.ToLowerInvariant()
Check "a mirror's own SHA256SUMS is not trusted" ($r.Code -ne 0 -and $r.Out.Contains("checksum mismatch for ${asset}: SHA256SUMS says $good98") -and -not (Test-Path (Join-Path $sp 'versions\9.9.8')))
# A version GitHub has no SHA256SUMS for: refused, unless HARDCHARGER_INSTALL_SHA256 gives it.
$only = Join-Path $root 'mirror-only\v9.9.4'
New-Item -ItemType Directory -Force -Path $only | Out-Null
Copy-Item (Join-Path $mirror "v9.9.8\$asset") (Join-Path $only $asset)
$r = Invoke-Installer @('-Prefix', $sp, '-Version', '9.9.4') @{ HARDCHARGER_INSTALL_MIRROR = (Join-Path $root 'mirror-only') }
Check 'no checksum anywhere: refused (no "relying on HTTPS alone")' ($r.Code -ne 0 -and $r.Out -match "no checksum for $([regex]::Escape($asset)) could be found" -and -not (Test-Path (Join-Path $sp 'versions\9.9.4')))
$r = Invoke-Installer @('-Prefix', $sp, '-Version', '9.9.4') @{ HARDCHARGER_INSTALL_MIRROR = (Join-Path $root 'mirror-only'); HARDCHARGER_INSTALL_SHA256 = $good98 }
Check 'HARDCHARGER_INSTALL_SHA256 checks it' ($r.Code -eq 0 -and $r.Out -match 'Checksum OK \(HARDCHARGER_INSTALL_SHA256\)')
$r = Invoke-Installer @('-Prefix', $sp, '-Version', '9.9.8') @{ HARDCHARGER_INSTALL_MIRROR = 'http://127.0.0.1:9/m'; HARDCHARGER_INSTALL_TEST_INSECURE = ''; HARDCHARGER_INSTALL_GITHUB_WEB = ''; HARDCHARGER_INSTALL_GITHUB_API = '' }
Check 'an http mirror needs HARDCHARGER_INSTALL_ALLOW_HTTP' ($r.Code -ne 0 -and $r.Out -match 'is plain http: set .env:HARDCHARGER_INSTALL_ALLOW_HTTP')
$r = Invoke-Installer @('-Prefix', $prefix) @{ HARDCHARGER_INSTALL_GITHUB_API = 'http://127.0.0.1:9'; HARDCHARGER_INSTALL_TEST_INSECURE = '' }
Check 'the test-only overrides must be https without the test flag' ($r.Code -ne 0 -and $r.Out -match 'are test settings and must be https://')
foreach ($bv in @("9.9.8`n", ([string][char]0x0661 + '.2.3'))) {
  $r = Invoke-Installer @('-Prefix', $prefix) @{ HARDCHARGER_VERSION = $bv }
  Check "a version with a line break or a non-ASCII digit is refused ($([Uri]::EscapeDataString($bv)))" ($r.Code -ne 0 -and $r.Out -match 'must be latest, X.Y.Z or vX.Y.Z' -and (Current) -eq '9.9.9')
}
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
  Check 'no token and no answer from the API: clear message, non-zero' ($r.Code -ne 0 -and $r.Out -match "couldn't find Hardcharger release 'latest'" -and $r.Out -match 'its API did not answer' -and $r.Out -match 'HARDCHARGER_INSTALL_TOKEN' -and $r.Out -notmatch 'releases are internal')
  $r = Invoke-Installer @('-Prefix', $p3, '-Version', '7.7.7') $int
  Check 'no token, a version GitHub does not describe: says there may be no such release' ($r.Code -ne 0 -and $r.Out -match "couldn't find Hardcharger release '7.7.7'" -and $r.Out -match 'there is no such release' -and $r.Out -notmatch 'releases are internal')

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
  Stop-Process -Id $webProc.Id -Force -ErrorAction SilentlyContinue
}

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
if ($failures) { Write-Host "$failures Windows test(s) failed"; exit 1 }
Write-Host "all Windows tests passed ($shell)"
# Explicitly: GitHub's pwsh step exits with $LASTEXITCODE, the last (expected) installer failure's.
exit 0
