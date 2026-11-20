<#
.SYNOPSIS
    Hardcharger installer for Windows (PowerShell 5.1 and 7+).

.DESCRIPTION
    Installs hardcharger-server and the hardcharger client from
    https://github.com/gizmodata/hardcharger/releases into %USERPROFILE%\.hardcharger:

        versions\<version>\   one directory per installed version (bin\, ...)
        bin\                  a junction to the current version's bin\ (put this on PATH)

    Switching to an installed version downloads nothing. A failed download, checksum or
    check of the new binaries leaves the current version as it was.

        irm https://install.hardcharger.gizmodata.com/install.ps1 | iex
        $env:HARDCHARGER_VERSION = '0.3.0'; irm https://install.hardcharger.gizmodata.com/install.ps1 | iex

    Windows builds (hardcharger-windows-<arch>.zip) start with 0.3.0; for an older release this
    script says so and fails.

.PARAMETER Version
    latest (the default), X.Y.Z or vX.Y.Z. Also $env:HARDCHARGER_VERSION.

.PARAMETER Prefix
    Install root. Default %USERPROFILE%\.hardcharger. Also $env:HARDCHARGER_PREFIX.

.PARAMETER CpuTarget
    auto (the default) or optimized: Windows has one build for every CPU. baseline (Linux x86-64
    only, through install.sh) is refused. Also $env:HARDCHARGER_CPU_TARGET.

.PARAMETER List
    List the installed versions.

.PARAMETER Uninstall
    Remove -Version <v> if given, otherwise everything under the prefix.

.PARAMETER ModifyPath
    Add <prefix>\bin to the user's PATH.

.NOTES
    $env:HARDCHARGER_INSTALL_TOKEN  GitHub token that can read gizmodata/hardcharger's releases
                                    (falls back to $env:GH_TOKEN, then `gh auth token`; "none" = anonymous)
    $env:HARDCHARGER_INSTALL_MIRROR directory or https:// URL laid out like the releases (vX.Y.Z\<asset>);
                                    the zip is still checked against the GitHub release's SHA256SUMS
    $env:HARDCHARGER_INSTALL_SHA256 the zip's SHA-256, for a machine that can't reach github.com
    $env:HARDCHARGER_INSTALL_ALLOW_HTTP = '1'  let HARDCHARGER_INSTALL_MIRROR be a plain http:// URL
    $env:HARDCHARGER_INSTALL_GITHUB_API, $env:HARDCHARGER_INSTALL_GITHUB_WEB
                                    for tests: GitHub's API and web base URLs; plain http needs
                                    $env:HARDCHARGER_INSTALL_TEST_INSECURE = '1' as well

.LINK
    https://github.com/gizmodata/hardcharger-install
#>
[CmdletBinding()]
param(
  [string]$Version = '',
  [string]$Prefix = '',
  [string]$CpuTarget = '',
  [switch]$List,
  [switch]$Uninstall,
  [switch]$ModifyPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar is very slow on 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'gizmodata/hardcharger'
# For tests only: another GitHub API base (fake_github.py); the default is the real one.
$GhApi = if ($env:HARDCHARGER_INSTALL_GITHUB_API) { $env:HARDCHARGER_INSTALL_GITHUB_API.TrimEnd('/') } else { 'https://api.github.com' }
$Api = "$GhApi/repos/$Repo"
$GhWeb = if ($env:HARDCHARGER_INSTALL_GITHUB_WEB) { $env:HARDCHARGER_INSTALL_GITHUB_WEB.TrimEnd('/') } else { 'https://github.com' }
$InstallUrl = 'https://install.hardcharger.gizmodata.com'
# Run as a file, a failure exits non-zero; piped into iex, it throws (exit would close the window).
$RunAsFile = [bool]$PSCommandPath

function Info([string]$m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Fail([string]$m) { $e = New-Object System.Exception $m; $e.Data['hardcharger'] = $true; throw $e }

function Get-NormalVersion([string]$v) {
  if (-not $v -or $v -eq 'latest') { return 'latest' }
  $n = $v -creplace '^v', ''
  # ASCII digits ([0-9], not \d) and \z (not $, which also matches before a final line break).
  if ($n -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?\z') {
    Fail "HARDCHARGER_VERSION/-Version must be latest, X.Y.Z or vX.Y.Z (got '$v')"
  }
  return $n
}

# Downloads $url to $file. Windows PowerShell 5.1 follows a redirect from https to http, so an https
# download must also end on https (5.1 has BaseResponse.ResponseUri, PowerShell 7 the request's URI).
function Save-Url([string]$url, [string]$file, [hashtable]$headers = @{}) {
  $r = Invoke-WebRequest -Uri $url -Headers $headers -OutFile $file -UseBasicParsing -PassThru
  $final = $null
  try { $final = $r.BaseResponse.ResponseUri } catch {}
  if (-not $final) { try { $final = $r.BaseResponse.RequestMessage.RequestUri } catch {} }
  if ($url -like 'https://*' -and $final -and $final.Scheme -ne 'https') {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Fail "the download of $url was redirected to plain http ($final); not using it"
  }
}

function Get-CurrentVersion([string]$bin) {
  $item = Get-Item -LiteralPath $bin -Force -ErrorAction SilentlyContinue
  if (-not $item -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return '' }
  $target = @($item.Target)[0]
  if (-not $target) { return '' }
  return Split-Path -Leaf (Split-Path -Parent $target)
}

function Get-InstalledVersions([string]$versions) {
  if (-not (Test-Path -LiteralPath $versions)) { return @() }
  @(Get-ChildItem -LiteralPath $versions -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\hardcharger-server.exe') } |
    ForEach-Object { $_.Name } |
    Sort-Object { try { [version](($_ -split '[-+]')[0]) } catch { [version]'0.0.0' } })
}

# Removes a junction without touching what it points at.
function Remove-Junction([string]$path) {
  $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if (-not $item) { return }
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($path) }
  else { Fail "$path is a real directory, not the installer's junction; move it away and run again" }
}

function Switch-Version([string]$prefixDir, [string]$ver) {
  $bin = Join-Path $prefixDir 'bin'
  $new = Join-Path $prefixDir "bin.new-$PID"
  Remove-Junction $new
  New-Item -ItemType Junction -Path $new -Target (Join-Path $prefixDir "versions\$ver\bin") | Out-Null
  Remove-Junction $bin
  [IO.Directory]::Move($new, $bin)
}

function Get-Token {
  $t = if ($env:HARDCHARGER_INSTALL_TOKEN) { $env:HARDCHARGER_INSTALL_TOKEN } else { $env:GH_TOKEN }
  if ($t -eq 'none') { return '' }
  if (-not $t -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    try { $t = (& gh auth token 2>$null | Select-Object -First 1) } catch { $t = '' }
  }
  return [string]$t
}

function Get-Arch {
  # The registry has the hardware's architecture even when this PowerShell runs emulated.
  $cpu = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE
  if (-not $cpu) { $cpu = $env:PROCESSOR_ARCHITECTURE }
  switch ($cpu) {
    'AMD64' { return 'amd64' }
    'ARM64' { return 'arm64' }
    default { Fail "Hardcharger needs 64-bit Windows (x64 or ARM64); this is '$cpu'" }
  }
}

function Test-Build([string]$dir, [string]$ver) {
  $ErrorActionPreference = 'Continue'   # a native command's stderr must not throw under 5.1
  foreach ($exe in Get-ChildItem -LiteralPath (Join-Path $dir 'bin') -Filter '*.exe') {
    $out = ''
    try {
      $out = (& $exe.FullName --version 2>&1 | Out-String).Trim()
      $ok = ($LASTEXITCODE -eq 0)
    } catch { $ok = $false; $out = $_.Exception.Message }
    if (-not $ok) {
      Write-Host "  $($exe.Name) --version failed:" -ForegroundColor Red
      Write-Host ($out -replace '(?m)^', '    ')
      return $false
    }
    if ($out -notlike "*$ver*") { Warn "$($exe.Name) reports '$out', not $ver" }
  }
  return $true
}

function Invoke-Install([string]$prefixDir, [string]$want, [bool]$modifyPath) {
  foreach ($u in @($GhApi, $GhWeb)) {
    if ($u -like 'http://*') {
      if ($env:HARDCHARGER_INSTALL_TEST_INSECURE -ne '1') { Fail "HARDCHARGER_INSTALL_GITHUB_API and _WEB are test settings and must be https:// (got $u)" }
    } elseif ($u -notlike 'https://*') { Fail "HARDCHARGER_INSTALL_GITHUB_API and _WEB must be https:// URLs (got $u)" }
  }
  $versions = Join-Path $prefixDir 'versions'
  $bin = Join-Path $prefixDir 'bin'
  $arch = Get-Arch
  $platform = "windows-$arch"
  $asset = "hardcharger-$platform.zip"
  New-Item -ItemType Directory -Force -Path $versions | Out-Null
  $prev = Get-CurrentVersion $bin

  $headers = @{ 'User-Agent' = 'hardcharger-install'; 'Accept' = 'application/vnd.github+json' }
  $token = Get-Token
  if ($token) { $headers['Authorization'] = "Bearer $token" }
  $token = $null
  $mirror = $env:HARDCHARGER_INSTALL_MIRROR
  $release = $null

  if ($want -ne 'latest' -and (Test-Path -LiteralPath (Join-Path $versions "$want\bin\hardcharger-server.exe"))) {
    $ver = $want                                   # installed already: no network needed
  } elseif ($mirror) {
    if ($want -eq 'latest') { Fail 'with HARDCHARGER_INSTALL_MIRROR, pass the version ($env:HARDCHARGER_VERSION = ''X.Y.Z'')' }
    $ver = $want
  } else {
    $url = if ($want -eq 'latest') { "$Api/releases/latest" } else { "$Api/releases/tags/v$want" }
    try { $release = Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing }
    catch {
      $hint = if ($headers.ContainsKey('Authorization')) { 'this token can''t read it' }
        elseif ($want -eq 'latest') { 'its API did not answer; anonymous requests are rate-limited per address, and a GitHub token in $env:HARDCHARGER_INSTALL_TOKEN (or `gh auth login`) gets past that' }
        else { 'there is no such release, or its API is rate-limiting this address; a GitHub token in $env:HARDCHARGER_INSTALL_TOKEN (or `gh auth login`) gets past the rate limit' }
      Fail "couldn't find Hardcharger release '$want' on GitHub ($hint). See https://github.com/$Repo/releases"
    }
    $ver = Get-NormalVersion $release.tag_name
  }
  $tag = "v$ver"

  $installed = Join-Path $versions $ver
  if ((Test-Path -LiteralPath (Join-Path $installed 'bin\hardcharger-server.exe')) -and (Test-Build $installed $ver)) {
    if ($prev -eq $ver) { Info "Hardcharger $ver is installed and current" }
    else {
      Switch-Version $prefixDir $ver
      $from = if ($prev) { ", from $prev" } else { '' }
      Info "Switched to Hardcharger $ver (already installed; nothing downloaded)$from"
    }
  } else {
    $work = Join-Path $prefixDir ".install-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
      $zip = Join-Path $work $asset
      $sums = Join-Path $work 'SHA256SUMS'
      $haveSums = $false
      $digest = ''
      if ($mirror) {
        Info "Downloading Hardcharger $ver for $platform ($asset) from the mirror"
        $base = $mirror.TrimEnd('/', '\')
        if ($base -like 'http://*') {
          if ($env:HARDCHARGER_INSTALL_ALLOW_HTTP -ne '1' -and $env:HARDCHARGER_INSTALL_TEST_INSECURE -ne '1') {
            Fail "HARDCHARGER_INSTALL_MIRROR $base is plain http: set `$env:HARDCHARGER_INSTALL_ALLOW_HTTP = '1' to download from it (the zip is still checked against the GitHub release's SHA256SUMS)"
          }
        } elseif ($base -match '^[a-z]+://' -and $base -notlike 'https://*') {
          Fail "HARDCHARGER_INSTALL_MIRROR must be a directory or an https:// URL (got $base)"
        }
        if ($base -match '^[a-z]+://') {
          try { Save-Url "$base/$tag/$asset" $zip } catch { if ($_.Exception.Data['hardcharger']) { throw }; Fail "the mirror has no $tag/$asset" }
        } else {
          if (-not (Test-Path -LiteralPath (Join-Path $base "$tag\$asset"))) { Fail "the mirror has no $tag\$asset" }
          Copy-Item -LiteralPath (Join-Path $base "$tag\$asset") -Destination $zip
        }
        # The checksums come from the GitHub release, never from the mirror, which must not vouch
        # for its own files.
        if (-not $env:HARDCHARGER_INSTALL_SHA256) {
          try { Save-Url "$GhWeb/$Repo/releases/download/$tag/SHA256SUMS" $sums; $haveSums = $true }
          catch { if ($_.Exception.Data['hardcharger']) { throw }; $haveSums = $false }
        }
      } else {
        if (-not $release) {
          try { $release = Invoke-RestMethod -Uri "$Api/releases/tags/$tag" -Headers $headers -UseBasicParsing }
          catch { Fail "couldn't read Hardcharger release $tag on GitHub" }
        }
        $a = @($release.assets | Where-Object { $_.name -eq $asset })[0]
        if (-not $a) {
          Fail "Windows builds start with 0.3.0: Hardcharger $ver has no $asset. Install 0.3.0 or later (the latest is the default), or run Hardcharger in WSL 2 (curl $InstallUrl | sh) or with Docker (docker run -p 31337:31337 -e HARDCHARGER_ADMIN_PASSWORD=change-me gizmodata/hardcharger)."
        }
        $digest = [string]$a.digest
        $dl = @{ 'User-Agent' = 'hardcharger-install'; 'Accept' = 'application/octet-stream' }
        if ($headers.ContainsKey('Authorization')) { $dl['Authorization'] = $headers['Authorization'] }
        Info "Downloading Hardcharger $ver for $platform ($asset)"
        # Both PowerShells drop the Authorization header when the API redirects to the storage host.
        Save-Url $a.url $zip $dl
        $s = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS' })[0]
        if ($s) { Save-Url $s.url $sums $dl; $haveSums = $true }
      }

      $have = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
      $checked = @()
      if ($env:HARDCHARGER_INSTALL_SHA256) {
        $wantSum = $env:HARDCHARGER_INSTALL_SHA256.ToLowerInvariant()
        if ($wantSum -cnotmatch '^[0-9a-f]{64}\z') { Fail 'HARDCHARGER_INSTALL_SHA256 must be 64 hexadecimal digits' }
        if ($have -ne $wantSum) { Fail "checksum mismatch for ${asset}: HARDCHARGER_INSTALL_SHA256 says $wantSum, the download is $have. Nothing was changed." }
        $checked += 'HARDCHARGER_INSTALL_SHA256'
        $haveSums = $false; $digest = ''
      }
      if ($haveSums) {
        $line = Get-Content -LiteralPath $sums | Where-Object { ($_ -split '\s+', 2)[1] -replace '^\*', '' -eq $asset } | Select-Object -First 1
        if (-not $line) { Fail "the release's SHA256SUMS has no line for $asset; not installing it" }
        $wantSum = ($line -split '\s+')[0].ToLowerInvariant()
        if ($have -ne $wantSum) { Fail "checksum mismatch for ${asset}: SHA256SUMS says $wantSum, the download is $have. Nothing was changed; run again, and report it if it repeats." }
        $checked += 'SHA256SUMS'
      }
      if ($digest -like 'sha256:*') {
        if ($have -ne $digest.Substring(7).ToLowerInvariant()) { Fail "checksum mismatch for ${asset}: GitHub says $($digest.Substring(7)), the download is $have. Nothing was changed." }
        $checked += "GitHub's asset digest"
      }
      if ($checked.Count) { Info "Checksum OK ($($checked -join ' and ')): $have" }
      else { Fail "no checksum for $asset could be found (no SHA256SUMS in the GitHub release, and no digest from its API), so it wasn't installed. Set `$env:HARDCHARGER_INSTALL_SHA256 to the zip's SHA-256, or try again later." }

      $x = Join-Path $work 'x'
      Expand-Archive -LiteralPath $zip -DestinationPath $x
      # Only regular files and folders: no links (reparse points).
      $odd = @(Get-ChildItem -LiteralPath $x -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) | Select-Object -First 1
      if ($odd) { Fail "$asset holds $($odd.FullName.Substring($x.Length + 1)), which is a link; not installing it" }
      $top = Join-Path $x "hardcharger-$platform"
      if (-not (Test-Path -LiteralPath $top)) { $top = $x }
      if (-not (Test-Path -LiteralPath (Join-Path $top 'bin\hardcharger-server.exe'))) { Fail "$asset has no bin\hardcharger-server.exe; not installing it" }
      Get-ChildItem -LiteralPath $top -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
      if (-not (Test-Build $top $ver)) {
        $still = if ($prev) { "; $prev is still current" } else { '' }
        Fail "Hardcharger $ver doesn't run on this system, so it wasn't installed$still."
      }
      if (Test-Path -LiteralPath $installed) {
        # A broken copy of this version: its files may be in use, so move it aside first.
        Move-Item -LiteralPath $installed -Destination (Join-Path $work 'old')
      }
      Move-Item -LiteralPath $top -Destination $installed
      Switch-Version $prefixDir $ver
      $was = if ($prev) { " (was $prev)" } else { '' }
      Info "Installed Hardcharger $ver in $installed$was"
    } finally {
      Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Get-ChildItem -LiteralPath $bin -Filter '*.exe' | ForEach-Object { Write-Host "    $(Join-Path $bin $_.Name)" }

  $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
  $onUserPath = @($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') }) -contains $bin.TrimEnd('\')
  if ($modifyPath) {
    if ($onUserPath) { Info "$bin is already on your user PATH" }
    else {
      [Environment]::SetEnvironmentVariable('PATH', ($bin + ';' + $userPath).TrimEnd(';'), 'User')
      Info "Added $bin to your user PATH (new terminals get it)"
    }
    $env:PATH = "$bin;$env:PATH"
  } elseif (-not $onUserPath) {
    Write-Host ''
    Write-Host 'Add Hardcharger to your PATH:' -ForegroundColor Cyan
    Write-Host "    [Environment]::SetEnvironmentVariable('PATH', '$bin;' + [Environment]::GetEnvironmentVariable('PATH', 'User'), 'User')"
    Write-Host "  (for this session only: `$env:PATH = '$bin;' + `$env:PATH), or run the installer again with -ModifyPath"
  }
  Write-Host ''
  Write-Host 'Get started:'
  Write-Host "    `$env:HARDCHARGER_ADMIN_PASSWORD = 'change-me'; & '$bin\hardcharger-server.exe' --database my.duckdb"
  if (Test-Path -LiteralPath (Join-Path $bin 'hardcharger.exe')) {
    # The server above runs without TLS, and the client uses TLS unless told not to. Every release
    # with a client (0.3.0 on) takes --tls=false (--no-tls is newer than 2.0.0-rc.1).
    Write-Host "    `$env:HARDCHARGER_PASSWORD = 'change-me'; & '$bin\hardcharger.exe' --tls=false --username hardcharger   # in another terminal"
  }
  Write-Host "Docs: https://github.com/$Repo#readme"
}

function Invoke-List([string]$prefixDir) {
  $cur = Get-CurrentVersion (Join-Path $prefixDir 'bin')
  $vs = Get-InstalledVersions (Join-Path $prefixDir 'versions')
  if (-not $vs.Count) { Write-Host "No Hardcharger versions installed in $prefixDir"; return }
  Write-Host "Hardcharger versions in $(Join-Path $prefixDir 'versions'):"
  foreach ($v in $vs) { if ($v -eq $cur) { Write-Host "  * $v (current)" } else { Write-Host "    $v" } }
}

function Invoke-Uninstall([string]$prefixDir, [string]$one) {
  $versions = Join-Path $prefixDir 'versions'
  $bin = Join-Path $prefixDir 'bin'
  if ($one) {
    if ($one -eq 'latest') { Fail '-Uninstall takes -Version <X.Y.Z>, or nothing to remove everything' }
    $dir = Join-Path $versions $one
    if (-not (Test-Path -LiteralPath $dir)) { Fail "Hardcharger $one is not installed in $prefixDir (see -List)" }
    $cur = Get-CurrentVersion $bin
    if ($cur -eq $one) { Remove-Junction $bin }
    Remove-Item -LiteralPath $dir -Recurse -Force
    Info "Removed Hardcharger $one"
    if ($cur -eq $one) {
      $rest = Get-InstalledVersions $versions
      if ($rest.Count) { Warn "$one was the current version, so no version is current now. Installed: $($rest -join ' ')" }
    }
    return
  }
  if (-not (Test-Path -LiteralPath $prefixDir)) { Info "Nothing to remove: $prefixDir does not exist"; return }
  if ($prefixDir.TrimEnd('\') -eq $HOME.TrimEnd('\')) { Fail "refusing to remove $prefixDir" }
  if (-not (Test-Path -LiteralPath $versions) -and -not (Test-Path -LiteralPath $bin)) {
    Fail "$prefixDir does not look like a Hardcharger install (no versions\ or bin\); not removing it"
  }
  Remove-Junction $bin
  Remove-Item -LiteralPath $prefixDir -Recurse -Force
  Info "Removed $prefixDir"
  $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
  if (@($userPath -split ';') -contains $bin) {
    [Environment]::SetEnvironmentVariable('PATH', (@($userPath -split ';' | Where-Object { $_ -and $_ -ne $bin }) -join ';'), 'User')
    Info "Removed $bin from your user PATH"
  }
}

try {
  if (-not $Version) { $Version = if ($env:HARDCHARGER_VERSION) { $env:HARDCHARGER_VERSION } else { 'latest' } }
  if (-not $Prefix) { $Prefix = if ($env:HARDCHARGER_PREFIX) { $env:HARDCHARGER_PREFIX } else { Join-Path $HOME '.hardcharger' } }
  $Prefix = [IO.Path]::GetFullPath($Prefix).TrimEnd('\')
  $want = Get-NormalVersion $Version
  # Taken as install.sh and the Python package take it, to say clearly that Windows has no baseline build.
  if (-not $CpuTarget) { $CpuTarget = [string]$env:HARDCHARGER_CPU_TARGET }
  $CpuTarget = $CpuTarget.ToLowerInvariant()
  if (-not $CpuTarget) { $CpuTarget = 'auto' }
  if (@('auto', 'optimized', 'baseline') -cnotcontains $CpuTarget) {
    Fail "HARDCHARGER_CPU_TARGET/-CpuTarget must be one of auto, optimized, baseline, not '$CpuTarget'"
  }
  if ($List) { Invoke-List $Prefix }
  elseif ($Uninstall) { Invoke-Uninstall $Prefix ($(if ($want -eq 'latest') { '' } else { $want })) }
  elseif ($CpuTarget -eq 'baseline') {
    Fail "-CpuTarget baseline (HARDCHARGER_CPU_TARGET=baseline): the baseline build is for Linux on x86-64 only, and Windows has one build for every CPU. Run again without it."
  }
  else { Invoke-Install $Prefix $want ([bool]$ModifyPath) }
} catch {
  if (-not $_.Exception.Data['hardcharger']) { throw }
  if ($RunAsFile) {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
  }
  throw $_.Exception.Message
}
