#!/bin/sh
# Hardcharger installer for macOS and Linux.
#
#   curl https://install.hardcharger.gizmodata.com | sh                              # latest
#   curl https://install.hardcharger.gizmodata.com | HARDCHARGER_VERSION=0.2.0 sh    # a given version
#
# Installs hardcharger-server and the hardcharger client from
# https://github.com/gizmodata/hardcharger/releases into ~/.hardcharger:
#
#   ~/.hardcharger/versions/<version>/   one directory per installed version (bin/, lib/, ...)
#   ~/.hardcharger/bin/                  links to the current version's executables
#
# Switching to a version that is already installed downloads nothing. A failed
# download, checksum or check of the new binaries leaves the current version as it was.
#
# Options (pass them with `sh -s -- <options>` when piping):
#   --version <v>      latest (the default), X.Y.Z or vX.Y.Z.     env: HARDCHARGER_VERSION
#   --prefix <dir>     where to install (default ~/.hardcharger). env: HARDCHARGER_PREFIX
#   --list             list the installed versions and exit
#   --uninstall [<v>]  remove one version, or everything under the prefix
#   --modify-path      add the bin directory to your shell's startup file
#   --help             this help
#
# Environment:
#   HARDCHARGER_INSTALL_TOKEN  a GitHub token that can read gizmodata/hardcharger's releases
#                              (also GH_TOKEN, then `gh auth token`); "none" downloads anonymously.
#   HARDCHARGER_INSTALL_MIRROR a directory or URL laid out like the releases
#                              (<mirror>/vX.Y.Z/<asset>, <mirror>/vX.Y.Z/SHA256SUMS)
#
# Source: https://github.com/gizmodata/hardcharger-install

set -eu

REPO="gizmodata/hardcharger"
INSTALL_URL="https://install.hardcharger.gizmodata.com"
API="https://api.github.com/repos/${REPO}"

# Oldest glibc any Hardcharger Linux build supports (manylinux_2_28).
GLIBC_FLOOR="2.28"

# ---- output -------------------------------------------------------------------
if [ -t 1 ]; then
  B="$(printf '\033[1m')"; G="$(printf '\033[32m')"; R="$(printf '\033[31m')"
  Y="$(printf '\033[33m')"; D="$(printf '\033[2m')"; N="$(printf '\033[0m')"
else
  B=""; G=""; R=""; Y=""; D=""; N=""
fi
info()  { printf '%s==>%s %s\n' "${G}${B}" "$N" "$*"; }
warn()  { printf '%swarning:%s %s\n' "${Y}${B}" "$N" "$*" >&2; }
fatal() { printf '%serror:%s %s\n' "${R}${B}" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Hardcharger installer (macOS and Linux)

  curl $INSTALL_URL | sh                              # latest
  curl $INSTALL_URL | HARDCHARGER_VERSION=0.2.0 sh    # a given version (switch or downgrade)
  curl $INSTALL_URL | sh -s -- --list                 # installed versions

Options (with \`sh -s -- <options>\` when piping):
  --version <v>      latest (the default), X.Y.Z or vX.Y.Z      [HARDCHARGER_VERSION]
  --prefix <dir>     install root (default ~/.hardcharger)       [HARDCHARGER_PREFIX]
  --list             list installed versions
  --uninstall [<v>]  remove version <v>, or everything under the prefix
  --modify-path      add <prefix>/bin to your shell's startup file
  --help             this help

Environment:
  HARDCHARGER_INSTALL_TOKEN   GitHub token that can read $REPO releases
                              (falls back to GH_TOKEN, then \`gh auth token\`; "none" = anonymous)
  HARDCHARGER_INSTALL_MIRROR  directory or URL laid out like the releases (vX.Y.Z/<asset>)

Windows: irm $INSTALL_URL/install.ps1 | iex
EOF
}

# ---- arguments ----------------------------------------------------------------
VERSION="${HARDCHARGER_VERSION:-latest}"
PREFIX="${HARDCHARGER_PREFIX:-${HOME:-}/.hardcharger}"
ACTION="install"
UNINSTALL_VERSION=""
MODIFY_PATH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)     [ $# -ge 2 ] || fatal "--version needs a value (latest, X.Y.Z or vX.Y.Z)"
                   VERSION="$2"; shift 2 ;;
    --version=*)   VERSION="${1#*=}"; shift ;;
    --prefix)      [ $# -ge 2 ] || fatal "--prefix needs a directory"
                   PREFIX="$2"; shift 2 ;;
    --prefix=*)    PREFIX="${1#*=}"; shift ;;
    --list)        ACTION="list"; shift ;;
    --uninstall)   ACTION="uninstall"; shift
                   case "${1:-}" in -*|"") ;; *) UNINSTALL_VERSION="$1"; shift ;; esac ;;
    --uninstall=*) ACTION="uninstall"; UNINSTALL_VERSION="${1#*=}"; shift ;;
    --modify-path) MODIFY_PATH=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             fatal "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$PREFIX" ] || fatal "HOME is not set; pass --prefix <dir>"
PREFIX="${PREFIX%/}"
case "$PREFIX" in /*) ;; *) PREFIX="$(pwd)/$PREFIX" ;; esac
BIN="$PREFIX/bin"
VERSIONS="$PREFIX/versions"

# "latest", "0.2.0" or "v0.2.0" -> "latest" / "0.2.0"; anything else is refused.
normalize_version() {
  nv="${1#v}"
  case "$1" in latest|"") echo latest; return 0 ;; esac
  if printf '%s\n' "$nv" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
    echo "$nv"
  else
    return 1
  fi
}

# ---- installed versions and the current one -----------------------------------
current_version() {
  [ -L "$BIN/hardcharger-server" ] || return 0
  cv="$(readlink "$BIN/hardcharger-server" 2>/dev/null || true)"
  cv="${cv#../versions/}"
  echo "${cv%%/*}"
}

installed_versions() {
  [ -d "$VERSIONS" ] || return 0
  for d in "$VERSIONS"/*; do
    [ -x "$d/bin/hardcharger-server" ] && basename "$d"
  done | sort -t. -k1,1n -k2,2n -k3,3n
}

do_list() {
  cur="$(current_version)"
  vs="$(installed_versions)"
  if [ -z "$vs" ]; then
    echo "No Hardcharger versions installed in $PREFIX"
    return 0
  fi
  echo "Hardcharger versions in $VERSIONS:"
  for v in $vs; do
    if [ "$v" = "$cur" ]; then echo "  * $v (current)"; else echo "    $v"; fi
  done
}

# Point $BIN's links at version $1's executables, and drop links into other versions.
switch_to() {
  mkdir -p "$BIN"
  for exe in "$VERSIONS/$1/bin"/*; do
    [ -f "$exe" ] && [ -x "$exe" ] || continue
    n="$(basename "$exe")"
    ln -s "../versions/$1/bin/$n" "$BIN/.$n.new.$$"
    mv -f "$BIN/.$n.new.$$" "$BIN/$n"
  done
  for l in "$BIN"/*; do
    [ -L "$l" ] || continue
    t="$(readlink "$l" 2>/dev/null || true)"
    case "$t" in
      "../versions/$1/"*) ;;
      ../versions/*) rm -f "$l" ;;
    esac
  done
}

unlink_all() {
  [ -d "$BIN" ] || return 0
  for l in "$BIN"/*; do
    [ -L "$l" ] || continue
    case "$(readlink "$l" 2>/dev/null || true)" in ../versions/*) rm -f "$l" ;; esac
  done
}

do_uninstall() {
  if [ -n "$UNINSTALL_VERSION" ]; then
    v="$(normalize_version "$UNINSTALL_VERSION")" || fatal "not a version: $UNINSTALL_VERSION"
    [ "$v" != latest ] || fatal "--uninstall takes a version number, or nothing to remove everything"
    [ -d "$VERSIONS/$v" ] || fatal "Hardcharger $v is not installed in $PREFIX (see --list)"
    cur="$(current_version)"
    rm -rf "${VERSIONS:?}/$v"
    info "Removed Hardcharger $v"
    if [ "$v" = "$cur" ]; then
      unlink_all
      rest="$(installed_versions | tr '\n' ' ')"
      if [ -n "$rest" ]; then
        warn "$v was the current version, so no version is current now. Installed: $rest"
        echo "  Switch with: curl $INSTALL_URL | HARDCHARGER_VERSION=<version> sh"
      fi
    fi
    return 0
  fi
  # Everything: only a directory that looks like ours, and never $HOME or /.
  case "$PREFIX" in ""|/|"${HOME:-/}") fatal "refusing to remove $PREFIX" ;; esac
  if [ ! -d "$PREFIX" ]; then
    info "Nothing to remove: $PREFIX does not exist"
    return 0
  fi
  [ -d "$VERSIONS" ] || [ -d "$BIN" ] || fatal "$PREFIX does not look like a Hardcharger install (no versions/ or bin/); not removing it"
  rm -rf "$PREFIX"
  info "Removed $PREFIX"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.config/fish/conf.d/hardcharger.fish"; do
    if [ -f "$rc" ] && grep -qF "Added by the Hardcharger installer" "$rc" 2>/dev/null; then
      echo "  $rc has the Hardcharger installer's PATH line; delete it (and the comment above it)."
    fi
  done
}

# ---- platform -----------------------------------------------------------------
needs_64bit() {
  model=""
  [ -r /proc/device-tree/model ] && model="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"
  msg="Hardcharger needs a 64-bit operating system, and this one is 32-bit ($1)."
  case "$model:$1" in
    *"Raspberry Pi"*|*:arm*|*:aarch64)
      msg="$msg On a Raspberry Pi (3, 4, 5, 400, 500 or Zero 2 W), install the 64-bit Raspberry Pi OS (in Raspberry Pi Imager: \"Raspberry Pi OS (64-bit)\") and run this again. Older models (Pi 1, Pi 2 before v1.2, Zero, Zero W) can't run 64-bit software." ;;
  esac
  fatal "$msg"
}

detect_platform() {
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  uname_m="$(uname -m 2>/dev/null || echo unknown)"
  case "$uname_s" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    MINGW*|MSYS*|CYGWIN*|Windows*)
      fatal "on Windows, install from PowerShell: irm $INSTALL_URL/install.ps1 | iex" ;;
    *) fatal "Hardcharger has no build for $uname_s (macOS and Linux here; Windows through install.ps1)" ;;
  esac
  case "$uname_m" in
    x86_64|amd64)  ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    armv6*|armv7*|armv8l|armhf|armel|arm|i386|i486|i586|i686|x86) needs_64bit "$uname_m" ;;
    *) fatal "Hardcharger has no build for the $uname_m processor (it ships for x86-64 and arm64)" ;;
  esac
  # A 64-bit kernel can run a 32-bit userland (32-bit Raspberry Pi OS on a Pi 4 or 5 does).
  if [ "$OS" = linux ] && [ "$(getconf LONG_BIT 2>/dev/null || echo 64)" = 32 ]; then
    needs_64bit "$uname_m kernel, 32-bit userland"
  fi
  if [ "$OS" = macos ] && [ "$ARCH" = amd64 ]; then
    # A shell running under Rosetta on Apple silicon reports x86_64.
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
      ARCH=arm64
    else
      fatal "Hardcharger's macOS build is for Apple silicon (arm64) only; Intel Macs can run the Docker image instead: docker run -p 31337:31337 -e HARDCHARGER_ADMIN_PASSWORD=change-me gizmodata/hardcharger"
    fi
  fi
  PLATFORM="${OS}-${ARCH}"
}

# 0 when version $1 >= $2 (dotted numbers).
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = na > nb ? na : nb
    for (i = 1; i <= n; i++) { if ((x[i] + 0) > (y[i] + 0)) exit 0; if ((x[i] + 0) < (y[i] + 0)) exit 1 }
    exit 0 }'
}

# The glibc on this system: "2.36", "musl", or "" when it can't be told.
detect_libc() {
  if ldd --version 2>&1 | grep -qi musl; then echo musl; return 0; fi
  for f in /lib/ld-musl-*.so.1; do [ -e "$f" ] && { echo musl; return 0; }; done
  lv="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
  [ -n "$lv" ] || lv="$(ldd --version 2>/dev/null | head -n 1 | awk '{print $NF}')"
  printf '%s\n' "$lv" | grep -Eq '^[0-9]+\.[0-9]+' && echo "$lv" || echo ""
}

# The glibc a release's Linux build needs, before downloading it. Releases don't
# say yet, so this is hard-coded: 0.0.x-0.2.x were built on Ubuntu 24.04 and need
# glibc 2.38 (their highest GLIBC_ symbol); later ones are built in manylinux_2_28.
# A downloaded build is also checked for its real GLIBC_ symbols before it is used.
glibc_needed() {
  case "$1" in
    0.0.*|0.1.*|0.2.*) echo 2.38 ;;
    *) echo "$GLIBC_FLOOR" ;;
  esac
}

glibc_too_old() {
  fatal "Hardcharger $1 for Linux needs glibc >= $2, and this system has glibc $3. $(glibc_hint)"
}

glibc_hint() {
  if version_ge "$SYS_GLIBC" "$GLIBC_FLOOR"; then
    echo "Builds for glibc $GLIBC_FLOOR and newer (Debian 12 / Raspberry Pi OS Bookworm, RHEL/Oracle Linux 8, Ubuntu 20.04) come in a later release; until then use a newer distribution or the Docker image (gizmodata/hardcharger)."
  else
    echo "Hardcharger supports glibc $GLIBC_FLOOR and newer; on this system use the Docker image (gizmodata/hardcharger)."
  fi
}

check_libc() {
  SYS_GLIBC=""
  [ "$OS" = linux ] || return 0
  SYS_GLIBC="$(detect_libc)"
  case "$SYS_GLIBC" in
    musl) fatal "this system uses musl libc (Alpine Linux or similar), and Hardcharger's Linux builds need glibc. Use a glibc distribution (Debian, Ubuntu, RHEL, ...) or the Docker image (gizmodata/hardcharger)." ;;
    "")   warn "couldn't tell this system's glibc version; Hardcharger's Linux builds need glibc >= $GLIBC_FLOOR." ;;
  esac
}

# ---- downloads ----------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || fatal "this installer needs '$1'; install it and run again"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1" | awk '{print $1}'
  else return 1
  fi
}

# The token goes to curl in a file (-H @file), never on a command line or in output.
setup_auth() {
  AUTH_HDR=""
  tok="${HARDCHARGER_INSTALL_TOKEN:-${GH_TOKEN:-}}"
  if [ "$tok" = none ]; then
    tok=""
  elif [ -z "$tok" ] && command -v gh >/dev/null 2>&1; then
    tok="$(gh auth token 2>/dev/null || true)"
  fi
  if [ -n "$tok" ]; then
    AUTH_HDR="$WORK/auth-header"
    ( umask 077; printf 'Authorization: Bearer %s\n' "$tok" > "$AUTH_HDR" )
  fi
  tok=""
}

PROGRESS="-s"
[ -t 2 ] && PROGRESS="--progress-bar"

# curl_api <url> <out>: GitHub API JSON, with the token when there is one.
curl_api() {
  if [ -n "$AUTH_HDR" ]; then
    curl -fsSL --proto '=https' --retry 3 -H @"$AUTH_HDR" -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' -o "$2" "$1"
  else
    curl -fsSL --proto '=https' --retry 3 -H 'Accept: application/vnd.github+json' -o "$2" "$1"
  fi
}

# Splits release JSON into one "key": value per line (good enough for the flat fields used here).
# shellcheck disable=SC2020 # five characters to five newlines, on purpose
json_lines() { tr -d '\r' < "$1" | tr ',{}[]' '\n\n\n\n\n'; }

json_field() {
  json_lines "$1" | sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

# asset_info <release.json> <name> -> "<id> <digest>" (digest may be missing).
asset_info() {
  json_lines "$1" | awk -v want="$2" '
    function val(s) { sub(/^[^:]*:[[:space:]]*"/, "", s); sub(/".*$/, "", s); return s }
    /^[[:space:]]*"url"[[:space:]]*:[[:space:]]*"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\/[0-9]+"/ {
      id = val($0); sub(/.*\//, "", id); name = ""; digest = ""; next }
    id != "" && name == "" && /^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"/ { name = val($0); next }
    id != "" && /^[[:space:]]*"digest"[[:space:]]*:[[:space:]]*"/ { digest = val($0); next }
    id != "" && /^[[:space:]]*"browser_download_url"/ {
      if (name == want) { print id, digest; exit }
      id = "" }'
}

# Resolves $VERSION (maybe "latest") to $VER and $TAG, and leaves the release JSON at
# $RELEASE_JSON when the API answered.
resolve_release() {
  RELEASE_JSON=""
  if [ -n "${HARDCHARGER_INSTALL_MIRROR:-}" ]; then
    [ "$VERSION" != latest ] || fatal "with HARDCHARGER_INSTALL_MIRROR, pass the version (HARDCHARGER_VERSION=X.Y.Z)"
    VER="$VERSION"; TAG="v$VER"; return 0
  fi
  if [ "$VERSION" = latest ]; then
    api_url="$API/releases/latest"
  else
    api_url="$API/releases/tags/v$VERSION"
  fi
  if curl_api "$api_url" "$WORK/release.json" 2>/dev/null; then
    RELEASE_JSON="$WORK/release.json"
    TAG="$(json_field "$RELEASE_JSON" tag_name)"
  elif [ -n "$AUTH_HDR" ]; then
    fatal "GitHub has no Hardcharger release '$VERSION' that this token can read ($api_url). See https://github.com/$REPO/releases"
  elif [ "$VERSION" = latest ]; then
    # Anonymous and the API refused (rate limit): ask github.com where /releases/latest goes.
    TAG="$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
    TAG="${TAG##*/}"
  else
    TAG="v$VERSION"
  fi
  VER="$(normalize_version "${TAG:-}")" || VER=""
  if [ -z "$VER" ] || [ "$VER" = latest ]; then
    fatal "couldn't find Hardcharger's latest release on GitHub. While the releases are internal, set HARDCHARGER_INSTALL_TOKEN to a GitHub token that can read $REPO (or sign in with \`gh auth login\`), or pass a version: HARDCHARGER_VERSION=X.Y.Z"
  fi
  TAG="v$VER"
}

# fetch_asset <name> <out>: 0 on success, 1 when the release has no such asset.
fetch_asset() {
  if [ -n "${HARDCHARGER_INSTALL_MIRROR:-}" ]; then
    m="${HARDCHARGER_INSTALL_MIRROR%/}"
    case "$m" in *://*) ;; *) m="file://$m" ;; esac
    curl -fSL $PROGRESS -o "$2" "$m/$TAG/$1" 2>/dev/null
    return
  fi
  if [ -n "$AUTH_HDR" ]; then
    [ -n "$RELEASE_JSON" ] || return 1
    ai="$(asset_info "$RELEASE_JSON" "$1")"
    [ -n "$ai" ] || return 1
    # curl sends a -H Authorization header only to api.github.com, not to the storage host it redirects to.
    curl -fSL $PROGRESS --proto '=https' --retry 3 -H @"$AUTH_HDR" -H 'Accept: application/octet-stream' \
      -o "$2" "$API/releases/assets/${ai%% *}"
  else
    curl -fSL $PROGRESS --proto '=https' --retry 3 -o "$2" "https://github.com/$REPO/releases/download/$TAG/$1" 2>/dev/null
  fi
}

# Checks $1 (named $2) against SHA256SUMS and GitHub's own asset digest, whichever exist.
verify_checksum() {
  checked=""
  have="$(sha256_of "$1")" || fatal "no sha256sum, shasum or openssl here to check the download with; install one and run again"
  if fetch_asset SHA256SUMS "$WORK/SHA256SUMS" >/dev/null 2>&1; then
    want="$(awk -v f="$2" '{n = $2; sub(/^\*/, "", n)} n == f {print $1; exit}' "$WORK/SHA256SUMS")"
    [ -n "$want" ] || fatal "the release's SHA256SUMS has no line for $2; not installing it"
    [ "$have" = "$want" ] || fatal "checksum mismatch for $2: SHA256SUMS says $want, the download is $have. Nothing was changed; run again, and report it if it repeats."
    checked="SHA256SUMS"
  fi
  if [ -n "$RELEASE_JSON" ]; then
    digest="$(asset_info "$RELEASE_JSON" "$2" | awk '{print $2}')"
    case "$digest" in
      sha256:*)
        [ "$have" = "${digest#sha256:}" ] || fatal "checksum mismatch for $2: GitHub says ${digest#sha256:}, the download is $have. Nothing was changed; run again, and report it if it repeats."
        checked="${checked:+$checked and }GitHub's asset digest" ;;
    esac
  fi
  if [ -n "$checked" ]; then
    info "Checksum OK ($checked): $have"
  else
    warn "no checksum is published for $2 (no SHA256SUMS, and GitHub's API didn't answer); relying on HTTPS alone"
  fi
}

# Runs the executables of an unpacked build; prints why it failed and returns 1 if one doesn't run.
check_build() {
  dir="$1"
  if [ "$OS" = linux ]; then
    # The build's own GLIBC_ symbols decide, whatever the table above says.
    need_g="$(LC_ALL=C grep -aoh 'GLIBC_2\.[0-9][0-9]*' "$dir"/bin/* "$dir"/lib/*.so* 2>/dev/null \
      | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n -u | tail -n 1)"
    if [ -n "$need_g" ] && [ -n "$SYS_GLIBC" ] && ! version_ge "$SYS_GLIBC" "$need_g"; then
      echo "  Hardcharger $VER for Linux needs glibc >= $need_g, and this system has glibc $SYS_GLIBC. $(glibc_hint)" >&2
      return 1
    fi
  fi
  for exe in "$dir"/bin/*; do
    [ -f "$exe" ] && [ -x "$exe" ] || continue
    if ! out="$("$exe" --version 2>&1)"; then
      echo "  $(basename "$exe") --version failed:" >&2
      printf '%s\n' "$out" | sed 's/^/    /' | head -n 8 >&2
      case "$out" in
        *GLIBC_*) echo "  It needs a newer glibc than this system's $SYS_GLIBC. $(glibc_hint)" >&2 ;;
        *openssl@3*) echo "  This build needs OpenSSL 3 from Homebrew: brew install openssl@3" >&2 ;;
        *libssl.so.3*|*libcrypto.so.3*) echo "  This build needs OpenSSL 3 (Debian/Ubuntu: apt-get install libssl3; RHEL 9: dnf install openssl-libs)." >&2 ;;
        *libzstd*) echo "  This build needs libzstd (Debian/Ubuntu: apt-get install libzstd1)." >&2 ;;
      esac
      return 1
    fi
    case "$out" in *"$VER"*) ;; *) warn "$(basename "$exe") reports '$out', not $VER" ;; esac
  done
}

do_install() {
  v="$(normalize_version "$VERSION")" || fatal "HARDCHARGER_VERSION/--version must be latest, X.Y.Z or vX.Y.Z (got '$VERSION')"
  VERSION="$v"
  detect_platform
  check_libc
  need curl
  need tar
  need awk

  mkdir -p "$PREFIX" 2>/dev/null || fatal "can't create $PREFIX (pass --prefix <a writable directory>)"
  [ -w "$PREFIX" ] || fatal "$PREFIX is not writable (pass --prefix <a writable directory>)"
  WORK="$(mktemp -d "$PREFIX/.install.XXXXXX")" || fatal "can't create a temporary directory in $PREFIX"
  trap 'rm -rf "$WORK"' EXIT
  trap 'rm -rf "$WORK"; exit 130' INT TERM

  # A pinned version is checked against this system's glibc before anything is fetched.
  if [ -n "$SYS_GLIBC" ] && [ "$VERSION" != latest ]; then
    gn="$(glibc_needed "$VERSION")"
    version_ge "$SYS_GLIBC" "$gn" || glibc_too_old "$VERSION" "$gn" "$SYS_GLIBC"
  fi
  setup_auth
  if [ "$VERSION" != latest ] && [ -x "$VERSIONS/$VERSION/bin/hardcharger-server" ]; then
    VER="$VERSION"; TAG="v$VER"         # installed already: no network needed
  else
    resolve_release                     # "latest" costs one small API call, then the same check
  fi
  if [ -n "$SYS_GLIBC" ]; then
    gn="$(glibc_needed "$VER")"
    version_ge "$SYS_GLIBC" "$gn" || glibc_too_old "$VER" "$gn" "$SYS_GLIBC"
  fi

  prev="$(current_version)"
  if [ -x "$VERSIONS/$VER/bin/hardcharger-server" ] && check_build "$VERSIONS/$VER" 2>/dev/null; then
    if [ "$prev" = "$VER" ]; then
      info "Hardcharger $VER is installed and current"
    else
      switch_to "$VER"
      info "Switched to Hardcharger $VER (already installed; nothing downloaded)${prev:+, from $prev}"
    fi
  else
    asset="hardcharger-$PLATFORM.tar.gz"
    info "Downloading Hardcharger $VER for $PLATFORM ($asset)"
    if ! fetch_asset "$asset" "$WORK/$asset"; then
      hint=""
      [ -n "$AUTH_HDR" ] || [ -n "${HARDCHARGER_INSTALL_MIRROR:-}" ] || hint=" While the releases are internal, set HARDCHARGER_INSTALL_TOKEN to a GitHub token that can read $REPO (or sign in with \`gh auth login\`)."
      fatal "Hardcharger $VER has no $asset to download (see https://github.com/$REPO/releases/tag/$TAG).$hint"
    fi
    verify_checksum "$WORK/$asset" "$asset"
    mkdir "$WORK/x"
    tar -xzf "$WORK/$asset" -C "$WORK/x" || fatal "couldn't unpack $asset"
    top="$WORK/x/hardcharger-$PLATFORM"
    [ -d "$top" ] || top="$WORK/x"
    # Releases before 0.2.0 named the server `hardcharger` (the client's name since 0.2.0):
    # install it as hardcharger-server, so that name always means the server.
    case "$VER" in
      0.0.*|0.1.*)
        if [ ! -e "$top/bin/hardcharger-server" ] && [ -x "$top/bin/hardcharger" ]; then
          mv "$top/bin/hardcharger" "$top/bin/hardcharger-server"
        fi ;;
    esac
    [ -x "$top/bin/hardcharger-server" ] || fatal "$asset has no bin/hardcharger-server; not installing it"
    if [ "$OS" = macos ] && command -v xattr >/dev/null 2>&1; then
      xattr -dr com.apple.quarantine "$top" 2>/dev/null || true
    fi
    check_build "$top" || fatal "Hardcharger $VER doesn't run on this system, so it wasn't installed${prev:+; $prev is still current}."
    mkdir -p "$VERSIONS"
    [ ! -e "$VERSIONS/$VER" ] || mv "$VERSIONS/$VER" "$WORK/old"
    mv "$top" "$VERSIONS/$VER"
    switch_to "$VER"
    info "Installed Hardcharger $VER in $VERSIONS/$VER${prev:+ (was $prev)}"
  fi

  for exe in "$BIN"/*; do
    [ -L "$exe" ] && printf '    %s\n' "$exe"
  done
  path_setup
  getting_started
}

# ---- PATH -----------------------------------------------------------------------
path_line() {
  case "$BIN" in
    "$HOME"/*) echo "export PATH=\"\$HOME/${BIN#"$HOME"/}:\$PATH\"" ;;
    *)         echo "export PATH=\"$BIN:\$PATH\"" ;;
  esac
}

rc_file() {
  case "$(basename "${SHELL:-sh}")" in
    zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ "$OS" = macos ]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi ;;
    fish) echo "$HOME/.config/fish/conf.d/hardcharger.fish" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

ON_PATH=0
path_setup() {
  case ":${PATH:-}:" in *":$BIN:"*) ON_PATH=1 ;; esac
  rc="$(rc_file)"
  case "$rc" in
    *.fish) line="fish_add_path $BIN" ;;
    *)      line="$(path_line)" ;;
  esac
  if [ "$MODIFY_PATH" = 1 ]; then
    if [ -f "$rc" ] && grep -qF "$line" "$rc"; then
      info "$rc already adds $BIN to PATH"
    else
      mkdir -p "$(dirname "$rc")"
      printf '\n# Added by the Hardcharger installer (%s)\n%s\n' "$INSTALL_URL" "$line" >> "$rc"
      info "Added $BIN to PATH in $rc (open a new terminal, or run: $line)"
    fi
  elif [ "$ON_PATH" = 0 ]; then
    printf '\n%sAdd Hardcharger to your PATH%s (for example in %s):\n    %s\n' "$B" "$N" "$rc" "$line"
    printf '  or run this installer again with: sh -s -- --modify-path\n'
  fi
  other="$(command -v hardcharger-server 2>/dev/null || true)"
  if [ -n "$other" ] && [ "$other" != "$BIN/hardcharger-server" ]; then
    warn "$other comes first on your PATH, so it runs instead of $BIN/hardcharger-server"
  fi
}

getting_started() {
  if [ "$ON_PATH" = 1 ]; then s="hardcharger-server"; c="hardcharger"; else s="$BIN/hardcharger-server"; c="$BIN/hardcharger"; fi
  printf '\nGet started:\n'
  pw=HARDCHARGER_ADMIN_PASSWORD
  case "$(current_version)" in 0.0.*|0.1.*) pw=HARDCHARGER_PASSWORD ;; esac
  printf '    %s%s=change-me %s --database my.duckdb%s\n' "$B" "$pw" "$s" "$N"
  if [ -e "$BIN/hardcharger" ]; then
    printf '    %sHARDCHARGER_PASSWORD=change-me %s --username hardcharger%s    %s# in another terminal%s\n' "$B" "$c" "$N" "$D" "$N"
  fi
  printf '\nDocs: https://github.com/%s#readme\n' "$REPO"
}

case "$ACTION" in
  list)      do_list ;;
  uninstall) do_uninstall ;;
  install)   do_install ;;
esac
