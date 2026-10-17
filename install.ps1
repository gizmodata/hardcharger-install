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
        $env:HARDCHARGER_VERSION = '0.2.0'; irm https://install.hardcharger.gizmodata.com/install.ps1 | iex

    Windows builds are not released yet: until a release has hardcharger-windows-<arch>.zip,
    this script says so and fails.

.PARAMETER Version
    latest (the default), X.Y.Z or vX.Y.Z. Also $env:HARDCHARGER_VERSION.

.PARAMETER Prefix
    Install root. Default %USERPROFILE%\.hardcharger. Also $env:HARDCHARGER_PREFIX.

.PARAMETER List
    List the installed versions.

.PARAMETER Uninstall
    Remove -Version <v> if given, otherwise everything under the prefix.

.PARAMETER ModifyPath
    Add <prefix>\bin to the user's PATH.

.NOTES
    $env:HARDCHARGER_INSTALL_TOKEN  GitHub token that can read gizmodata/hardcharger's releases
                                    (falls back to $env:GH_TOKEN, then `gh auth token`; "none" = anonymous)
    $env:HARDCHARGER_INSTALL_MIRROR directory or URL laid out like the releases (vX.Y.Z\<asset>)

.LINK
    https://github.com/gizmodata/hardcharger-install
#>
[CmdletBinding()]
param(
  [string]$Version = '',
  [string]$Prefix = '',
  [switch]$List,
  [switch]$Uninstall,
  [switch]$ModifyPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar is very slow on 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'gizmodata/hardcharger'
$Api = "https://api.github.com/repos/$Repo"
$InstallUrl = 'https://install.hardcharger.gizmodata.com'
# Run as a file, a failure exits non-zero; piped into iex, it throws (exit would close the window).
$RunAsFile = [bool]$PSCommandPath

function Info([string]$m) { Write-Host "==> $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Fail([string]$m) { $e = New-Object System.Exception $m; $e.Data['hardcharger'] = $true; throw $e }

function Get-NormalVersion([string]$v) {
  if (-not $v -or $v -eq 'latest') { return 'latest' }
  $n = $v -replace '^v', ''
  if ($n -notmatch '^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$') {
    Fail "HARDCHARGER_VERSION/-Version must be latest, X.Y.Z or vX.Y.Z (got '$v')"
  }
  return $n
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
      $hint = if ($headers.ContainsKey('Authorization')) { 'this token can''t read it' } else {
        'while the releases are internal, set $env:HARDCHARGER_INSTALL_TOKEN to a GitHub token that can read ' + $Repo + ' (or sign in with `gh auth login`)' }
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
        if ($base -match '^[a-z]+://') {
          try { Invoke-WebRequest -Uri "$base/$tag/$asset" -OutFile $zip -UseBasicParsing } catch { Fail "the mirror has no $tag/$asset" }
          try { Invoke-WebRequest -Uri "$base/$tag/SHA256SUMS" -OutFile $sums -UseBasicParsing; $haveSums = $true } catch { $haveSums = $false }
        } else {
          if (-not (Test-Path -LiteralPath (Join-Path $base "$tag\$asset"))) { Fail "the mirror has no $tag\$asset" }
          Copy-Item -LiteralPath (Join-Path $base "$tag\$asset") -Destination $zip
          if (Test-Path -LiteralPath (Join-Path $base "$tag\SHA256SUMS")) { Copy-Item -LiteralPath (Join-Path $base "$tag\SHA256SUMS") -Destination $sums; $haveSums = $true }
        }
      } else {
        if (-not $release) {
          try { $release = Invoke-RestMethod -Uri "$Api/releases/tags/$tag" -Headers $headers -UseBasicParsing }
          catch { Fail "couldn't read Hardcharger release $tag on GitHub" }
        }
        $a = @($release.assets | Where-Object { $_.name -eq $asset })[0]
        if (-not $a) {
          Fail "Windows builds are coming in a later release: Hardcharger $ver has no $asset yet. Until then, run Hardcharger in WSL 2 (curl $InstallUrl | sh) or with Docker (docker run -p 31337:31337 -e HARDCHARGER_ADMIN_PASSWORD=change-me gizmodata/hardcharger)."
        }
        $digest = [string]$a.digest
        $dl = @{ 'User-Agent' = 'hardcharger-install'; 'Accept' = 'application/octet-stream' }
        if ($headers.ContainsKey('Authorization')) { $dl['Authorization'] = $headers['Authorization'] }
        Info "Downloading Hardcharger $ver for $platform ($asset)"
        # Both PowerShells drop the Authorization header when the API redirects to the storage host.
        Invoke-WebRequest -Uri $a.url -Headers $dl -OutFile $zip -UseBasicParsing
        $s = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS' })[0]
        if ($s) { Invoke-WebRequest -Uri $s.url -Headers $dl -OutFile $sums -UseBasicParsing; $haveSums = $true }
      }

      $have = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
      $checked = @()
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
      else { Warn "no checksum is published for $asset; relying on HTTPS alone" }

      $x = Join-Path $work 'x'
      Expand-Archive -LiteralPath $zip -DestinationPath $x
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
    Write-Host "    `$env:HARDCHARGER_PASSWORD = 'change-me'; & '$bin\hardcharger.exe' --username hardcharger   # in another terminal"
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
  if ($List) { Invoke-List $Prefix }
  elseif ($Uninstall) { Invoke-Uninstall $Prefix ($(if ($want -eq 'latest') { '' } else { $want })) }
  else { Invoke-Install $Prefix $want ([bool]$ModifyPath) }
} catch {
  if (-not $_.Exception.Data['hardcharger']) { throw }
  if ($RunAsFile) {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
  }
  throw $_.Exception.Message
}
