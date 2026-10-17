#!/bin/sh
# End-to-end scenarios for install.sh against the real gizmodata/hardcharger releases:
# install, smoke test, downgrade, switch back without a download, --list, a corrupted
# download, a build that doesn't run, a SHA256SUMS without the asset, anonymous downloads,
# --modify-path, uninstalling one version, the current one, and everything.
#
#   HARDCHARGER_INSTALL_TOKEN=... .github/scripts/scenarios.sh [<version under test>]
#
# The token must read gizmodata/hardcharger's releases while they are internal. It is never
# printed. Runs in a throwaway HOME. SH picks the shell the installer runs under (default sh).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$(cd "$HERE/../.." && pwd)/install.sh"
SH="${SH:-sh}"
UNDER_TEST="${1:-}"
OLD="0.1.2"        # an older release to downgrade to and switch back from
MIRRORED="0.1.0"   # a release the corrupted-download cases serve from a local mirror
PORT="${PORT:-31400}"
REPO="gizmodata/hardcharger"

[ -n "${HARDCHARGER_INSTALL_TOKEN:-}" ] || { echo "::error::HARDCHARGER_INSTALL_TOKEN is not set (it must read $REPO's releases)"; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"
mkdir -p "$HOME"
P="$HOME/.hardcharger"
OUT="$ROOT/out"

step() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
fail() { echo "::error::$*"; [ -f "$OUT" ] && sed 's/^/  | /' "$OUT"; exit 1; }
# run <expected exit: 0|nonzero> <env...> -- <installer args...>: output to $OUT and the log
run() {
  want="$1"; shift
  envs=""
  while [ "$1" != "--" ]; do envs="$envs $1"; shift; done
  shift
  set +e
  # shellcheck disable=SC2086 # word splitting of the NAME=value list is intended
  env $envs "$SH" -s -- "$@" < "$INSTALLER" > "$OUT" 2>&1
  code=$?
  set -e
  sed 's/^/  | /' "$OUT"
  if [ "$want" = 0 ] && [ "$code" != 0 ]; then fail "installer exited $code, expected success"; fi
  if [ "$want" = nonzero ] && [ "$code" = 0 ]; then fail "installer succeeded, expected a failure"; fi
}
expect()     { grep -F -- "$1" "$OUT" >/dev/null || fail "expected output to contain: $1"; }
expect_not() { if grep -F -- "$1" "$OUT" >/dev/null; then fail "expected output NOT to contain: $1"; fi; }
current()    { readlink "$P/bin/hardcharger-server" 2>/dev/null | sed 's|^\.\./versions/||; s|/.*||'; }
is_current() { [ "$(current)" = "$1" ] || fail "current version is '$(current)', expected '$1'"; }

case "$(uname -s)" in Darwin) PLATFORM=macos ;; *) PLATFORM=linux ;; esac
case "$(uname -m)" in x86_64|amd64) PLATFORM="$PLATFORM-amd64" ;; *) PLATFORM="$PLATFORM-arm64" ;; esac
ASSET="hardcharger-$PLATFORM.tar.gz"

api() {
  printf 'Authorization: Bearer %s\n' "$HARDCHARGER_INSTALL_TOKEN" > "$ROOT/hdr"
  curl -fsSL -H @"$ROOT/hdr" "$@"
  rm -f "$ROOT/hdr"
}
if [ -z "$UNDER_TEST" ]; then
  UNDER_TEST="$(api "https://api.github.com/repos/$REPO/releases/latest" | tr ',' '\n' \
    | sed -n 's/.*"tag_name" *: *"v\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$UNDER_TEST" ] || fail "couldn't look up the latest release"
  LATEST=1
else
  UNDER_TEST="${UNDER_TEST#v}"
  LATEST=0
fi
echo "version under test: $UNDER_TEST (latest: $LATEST); older: $OLD; platform: $PLATFORM; shell: $SH"

# ---------------------------------------------------------------------------------------------
step "1. Install (token; piped to $SH like curl | sh)"
if [ "$LATEST" = 1 ]; then run 0 -- ; else run 0 HARDCHARGER_VERSION="$UNDER_TEST" -- ; fi
expect "Downloading Hardcharger $UNDER_TEST for $PLATFORM"
expect "Checksum OK"
expect "Installed Hardcharger $UNDER_TEST"
# shellcheck disable=SC2016 # the literal line the installer prints
expect 'export PATH="$HOME/.hardcharger/bin:$PATH"'
is_current "$UNDER_TEST"
"$HERE/e2e.sh" "$P/bin" "$PORT" "$UNDER_TEST"

step "2. Same version again: nothing to do"
run 0 HARDCHARGER_VERSION="$UNDER_TEST" --
expect "Hardcharger $UNDER_TEST is installed and current"
expect_not "Downloading"

step "3. Downgrade to $OLD with --version v$OLD"
run 0 -- --version "v$OLD"
expect "Downloading Hardcharger $OLD"
expect "Installed Hardcharger $OLD"
expect "(was $UNDER_TEST)"
is_current "$OLD"
[ ! -e "$P/bin/hardcharger" ] || fail "$OLD has no client, but bin/hardcharger is still there"
"$HERE/e2e.sh" "$P/bin" "$((PORT + 2))" "$OLD"

step "4. Switch back to $UNDER_TEST: no download, and offline"
run 0 HARDCHARGER_VERSION="$UNDER_TEST" HARDCHARGER_INSTALL_TOKEN=none https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 --
expect "Switched to Hardcharger $UNDER_TEST (already installed; nothing downloaded), from $OLD"
expect_not "Downloading"
is_current "$UNDER_TEST"
"$HERE/e2e.sh" "$P/bin" "$((PORT + 4))" "$UNDER_TEST"

step "5. --list"
run 0 -- --list
expect "* $UNDER_TEST (current)"
expect "    $OLD"

# ---------------------------------------------------------------------------------------------
step "6. A corrupted download is refused, and $UNDER_TEST stays current"
M="$ROOT/mirror"; mkdir -p "$M/v$MIRRORED"
# shellcheck disable=SC2020 # two characters to two newlines
id="$(api "https://api.github.com/repos/$REPO/releases/tags/v$MIRRORED" | tr ',{' '\n\n' | awk -v want="$ASSET" '
  /"url": *"https:\/\/api.github.com\/repos\/.*\/releases\/assets\/[0-9]+"/ { u = $0; sub(/.*assets\//, "", u); sub(/".*/, "", u) }
  /"name": *"/ && u != "" { n = $0; sub(/.*"name": *"/, "", n); sub(/".*/, "", n); if (n == want) { print u; exit } u = "" }')"
[ -n "$id" ] || fail "no $ASSET in v$MIRRORED"
api -H 'Accept: application/octet-stream' -o "$ROOT/good.tar.gz" "https://api.github.com/repos/$REPO/releases/assets/$id"
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
echo "$(sum "$ROOT/good.tar.gz")  $ASSET" > "$M/v$MIRRORED/SHA256SUMS"
# Same size, one changed byte in the middle.
cp "$ROOT/good.tar.gz" "$M/v$MIRRORED/$ASSET"
size=$(wc -c < "$ROOT/good.tar.gz" | tr -d ' ')
printf 'X' | dd of="$M/v$MIRRORED/$ASSET" bs=1 seek=$((size / 2)) conv=notrunc 2>/dev/null
cmp -s "$ROOT/good.tar.gz" "$M/v$MIRRORED/$ASSET" && fail "corruption didn't change the file"
run nonzero HARDCHARGER_VERSION="$MIRRORED" HARDCHARGER_INSTALL_MIRROR="$M" --
expect "checksum mismatch for $ASSET: SHA256SUMS says"
is_current "$UNDER_TEST"
[ ! -e "$P/versions/$MIRRORED" ] || fail "a refused download left versions/$MIRRORED behind"
[ -z "$(find "$P" -maxdepth 1 -name '.install.*')" ] || fail "temporary files left in $P"

step "6b. Positive twin: the same mirror with the good file installs"
cp "$ROOT/good.tar.gz" "$M/v$MIRRORED/$ASSET"
run 0 HARDCHARGER_VERSION="$MIRRORED" HARDCHARGER_INSTALL_MIRROR="$M" --
expect "Checksum OK (SHA256SUMS)"
is_current "$MIRRORED"
run 0 -- --uninstall "$MIRRORED"
run 0 HARDCHARGER_VERSION="$UNDER_TEST" --
is_current "$UNDER_TEST"

step "6c. A SHA256SUMS without a line for the asset is refused"
echo "0000000000000000000000000000000000000000000000000000000000000000  something-else.tar.gz" > "$M/v$MIRRORED/SHA256SUMS"
run nonzero HARDCHARGER_VERSION="$MIRRORED" HARDCHARGER_INSTALL_MIRROR="$M" --
expect "the release's SHA256SUMS has no line for $ASSET"
is_current "$UNDER_TEST"

step "6d. A build whose server doesn't run is refused, and $UNDER_TEST stays current"
mkdir -p "$ROOT/broken/hardcharger-$PLATFORM/bin"
printf '#!/bin/sh\necho "simulated loader failure" >&2\nexit 127\n' > "$ROOT/broken/hardcharger-$PLATFORM/bin/hardcharger-server"
chmod +x "$ROOT/broken/hardcharger-$PLATFORM/bin/hardcharger-server"
mkdir -p "$M/v9.9.9"
tar -czf "$M/v9.9.9/$ASSET" -C "$ROOT/broken" "hardcharger-$PLATFORM"
echo "$(sum "$M/v9.9.9/$ASSET")  $ASSET" > "$M/v9.9.9/SHA256SUMS"
run nonzero HARDCHARGER_VERSION=9.9.9 HARDCHARGER_INSTALL_MIRROR="$M" --
expect "simulated loader failure"
expect "Hardcharger 9.9.9 doesn't run on this system, so it wasn't installed; $UNDER_TEST is still current"
is_current "$UNDER_TEST"
[ ! -e "$P/versions/9.9.9" ] || fail "a build that doesn't run was kept"

# ---------------------------------------------------------------------------------------------
step "7. Anonymous (no token)"
if curl -fsS -o /dev/null "https://github.com/$REPO/releases/latest" 2>/dev/null; then
  echo "releases are public: anonymous downloads must work"
  run 0 HARDCHARGER_INSTALL_TOKEN=none GH_TOKEN= HARDCHARGER_PREFIX="$ROOT/anon" HARDCHARGER_VERSION="$OLD" --
  expect "Installed Hardcharger $OLD"
  "$HERE/e2e.sh" "$ROOT/anon/bin" "$((PORT + 6))" "$OLD"
else
  echo "releases are internal: anonymous downloads must fail with a clear message"
  run nonzero HARDCHARGER_INSTALL_TOKEN=none GH_TOKEN= HARDCHARGER_PREFIX="$ROOT/anon" --
  expect "set HARDCHARGER_INSTALL_TOKEN to a GitHub token that can read $REPO"
  run nonzero HARDCHARGER_INSTALL_TOKEN=none GH_TOKEN= HARDCHARGER_PREFIX="$ROOT/anon" HARDCHARGER_VERSION="$OLD" --
  expect "Hardcharger $OLD has no $ASSET to download"
  expect "set HARDCHARGER_INSTALL_TOKEN"
  [ ! -e "$ROOT/anon/versions" ] || fail "an anonymous failure left versions/ behind"
  run 0 HARDCHARGER_PREFIX="$ROOT/anon" -- --uninstall
  [ ! -e "$ROOT/anon" ] || fail "--uninstall left the empty prefix of a failed install"
fi

step "8. --modify-path (bash), twice: one line"
run 0 SHELL=/bin/bash -- --modify-path
case "$PLATFORM" in macos-*) rc="$HOME/.bash_profile" ;; *) rc="$HOME/.bashrc" ;; esac
[ "$(grep -cF '.hardcharger/bin' "$rc")" = 1 ] || fail "$rc should add .hardcharger/bin once"
run 0 SHELL=/bin/bash -- --modify-path
expect "already adds"
[ "$(grep -cF '.hardcharger/bin' "$rc")" = 1 ] || fail "$rc should still add .hardcharger/bin once"

step "9. --prefix"
run 0 HARDCHARGER_VERSION="$OLD" -- --prefix "$ROOT/custom"
"$ROOT/custom/bin/hardcharger-server" --version | grep -F "Hardcharger $OLD" >/dev/null || fail "--prefix install doesn't run"
expect "export PATH=\"$ROOT/custom/bin:\$PATH\""
run 0 -- --prefix "$ROOT/custom" --uninstall
[ ! -e "$ROOT/custom" ] || fail "--prefix --uninstall left $ROOT/custom"

# ---------------------------------------------------------------------------------------------
step "10. Uninstall $OLD (not current)"
run 0 -- --uninstall "$OLD"
expect "Removed Hardcharger $OLD"
[ ! -e "$P/versions/$OLD" ] || fail "versions/$OLD is still there"
is_current "$UNDER_TEST"
"$P/bin/hardcharger-server" --version >/dev/null

step "11. Uninstall the current version"
run 0 HARDCHARGER_VERSION="$OLD" --
is_current "$OLD"
run 0 -- --uninstall "$OLD"
expect "no version is current now. Installed: $UNDER_TEST"
[ ! -e "$P/bin/hardcharger-server" ] || fail "bin/hardcharger-server still points at a removed version"

step "12. Uninstall everything"
run 0 -- --uninstall
expect "Removed $P"
expect "has the Hardcharger installer's PATH line; delete it"
[ ! -e "$P" ] || fail "$P is still there"
run 0 -- --uninstall
expect "Nothing to remove"

echo
echo "ALL SCENARIOS PASSED ($PLATFORM, $SH, Hardcharger $UNDER_TEST)"
