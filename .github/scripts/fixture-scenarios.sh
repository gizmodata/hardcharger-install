#!/bin/sh
# install.sh end to end against fixture releases served by a local stand-in for GitHub
# (fake_github.py), so it needs no credentials and no real release. Two servers run: one
# "internal" (the API and downloads need a token, as gizmodata/hardcharger's do before launch) and
# one "public" (anonymous). Covered: latest and pinned installs with a token and anonymously,
# the token going to the API but never to the storage host, GH_TOKEN and `gh auth token`,
# downgrade, switching back without a download, --list, SHA256SUMS and GitHub's digest (good,
# corrupted, missing a line, wrong digest, neither published), a build that doesn't run, a release
# without this platform's asset, an unknown version, --modify-path, --prefix, and every uninstall.
#
#   .github/scripts/fixture-scenarios.sh            (SH picks the shell the installer runs under)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$(cd "$HERE/../.." && pwd)/install.sh"
SH="${SH:-sh}"
PY="$(command -v python3 || command -v python)"
TOKEN="fixture-token-$$-not-a-secret"

ROOT="$(mktemp -d)"
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; rm -rf "$ROOT"; }
trap cleanup EXIT
export HOME="$ROOT/home"
mkdir -p "$HOME"
P="$HOME/.hardcharger"
OUT="$ROOT/out"
unset HARDCHARGER_INSTALL_TOKEN GH_TOKEN HARDCHARGER_VERSION HARDCHARGER_PREFIX HARDCHARGER_INSTALL_MIRROR 2>/dev/null || true
# Nothing here may reach the real GitHub: a step that names no fake server gets a dead one.
export HARDCHARGER_INSTALL_GITHUB_API=http://127.0.0.1:9 HARDCHARGER_INSTALL_GITHUB_WEB=http://127.0.0.1:9

step() { printf '\n### %s\n' "$*"; }
fail() { echo "::error::$*"; [ -f "$OUT" ] && sed 's/^/  | /' "$OUT"; exit 1; }
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
  if grep -F -- "$TOKEN" "$OUT" >/dev/null; then fail "the token appeared in the installer's output"; fi
}
expect()     { grep -F -- "$1" "$OUT" >/dev/null || fail "expected output to contain: $1"; }
expect_not() { if grep -F -- "$1" "$OUT" >/dev/null; then fail "expected output NOT to contain: $1"; fi; }
current()    { readlink "$P/bin/hardcharger-server" 2>/dev/null | sed 's|^\.\./versions/||; s|/.*||'; }
is_current() { [ "$(current)" = "$1" ] || fail "current version is '$(current)', expected '$1'"; }
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

case "$(uname -s)" in Darwin) PLATFORM=macos ;; *) PLATFORM=linux ;; esac
case "$(uname -m)" in x86_64|amd64) PLATFORM="$PLATFORM-amd64" ;; *) PLATFORM="$PLATFORM-arm64" ;; esac
ASSET="hardcharger-$PLATFORM.tar.gz"
echo "platform: $PLATFORM; shell: $SH"

# ---- fixtures ---------------------------------------------------------------------------------
F="$ROOT/fixtures"
# build <version> <server name> <with client: 1|0> <server exit code>
build() {
  d="$ROOT/build/$1/hardcharger-$PLATFORM"
  mkdir -p "$d/bin" "$d/lib"
  # shellcheck disable=SC2016 # a script written out verbatim
  printf '#!/bin/sh\nif [ "${1:-}" = --version ]; then echo "Hardcharger %s"; exit %s; fi\necho "fixture server %s $*"\n' "$1" "$4" "$1" > "$d/bin/$2"
  [ "$4" = 0 ] || printf '#!/bin/sh\necho "fixture: simulated loader failure" >&2\nexit %s\n' "$4" > "$d/bin/$2"
  if [ "$3" = 1 ]; then printf '#!/bin/sh\necho "Hardcharger Client %s"\n' "$1" > "$d/bin/hardcharger"; fi
  chmod +x "$d/bin/"*
  echo "fixture library $1" > "$d/lib/libfixture.txt"
  mkdir -p "$F/v$1"
  tar -czf "$F/v$1/$ASSET" -C "$ROOT/build/$1" "hardcharger-$PLATFORM"
}
sums() { echo "$(sum "$F/v$1/$ASSET")  $ASSET" > "$F/v$1/SHA256SUMS"; }

build 0.1.9 hardcharger 0 0;        sums 0.1.9   # before 0.2.0: the server was named `hardcharger`
build 1.0.0 hardcharger-server 1 0; sums 1.0.0   # server and client, SHA256SUMS and digest
build 1.1.0 hardcharger-server 1 0               # the latest: GitHub's digest only
build 1.0.1 hardcharger-server 1 127; sums 1.0.1 # a build whose server doesn't run
build 1.0.2 hardcharger-server 1 0; sums 1.0.2   # corrupted after SHA256SUMS was made
size=$(wc -c < "$F/v1.0.2/$ASSET" | tr -d ' ')
printf 'X' | dd of="$F/v1.0.2/$ASSET" bs=1 seek=$((size / 2)) conv=notrunc 2>/dev/null
build 1.0.3 hardcharger-server 1 0                # SHA256SUMS without a line for the asset
echo "0000000000000000000000000000000000000000000000000000000000000000  something-else.tar.gz" > "$F/v1.0.3/SHA256SUMS"
build 1.0.4 hardcharger-server 1 0                # GitHub's digest doesn't match
echo "$ASSET sha256:1111111111111111111111111111111111111111111111111111111111111111" > "$F/v1.0.4/digest-override"
mkdir -p "$F/v1.0.5"; echo "other" > "$F/v1.0.5/hardcharger-windows-amd64.zip"   # nothing for this platform

serve() {   # serve <name> [--private]: starts a server, sets <name>_URL
  "$PY" "$HERE/fake_github.py" --root "$F" --port 0 --port-file "$ROOT/$1.port" --log "$ROOT/$1.log" \
    --token "$TOKEN" ${2:+"$2"} &
  PIDS="$PIDS $!"
  i=0; until [ -s "$ROOT/$1.port" ]; do i=$((i + 1)); [ "$i" -lt 100 ] || fail "fake GitHub didn't start"; sleep 0.1; done
  eval "$1_URL=http://127.0.0.1:$(cat "$ROOT/$1.port")"
}
serve internal --private
serve public
# shellcheck disable=SC2154 # set by serve
INTERNAL="HARDCHARGER_INSTALL_GITHUB_API=$internal_URL/api HARDCHARGER_INSTALL_GITHUB_WEB=$internal_URL/web"
# shellcheck disable=SC2154
PUBLIC="HARDCHARGER_INSTALL_GITHUB_API=$public_URL/api HARDCHARGER_INSTALL_GITHUB_WEB=$public_URL/web"
WITH_TOKEN="HARDCHARGER_INSTALL_TOKEN=$TOKEN"
NO_TOKEN="HARDCHARGER_INSTALL_TOKEN=none"

# ---- internal releases, with a token ---------------------------------------------------------
step "1. Latest, with a token (piped to $SH like curl | sh)"
# shellcheck disable=SC2086
run 0 $INTERNAL $WITH_TOKEN --
expect "Downloading Hardcharger 1.1.0 for $PLATFORM"
expect "Checksum OK (GitHub's asset digest)"
expect "Installed Hardcharger 1.1.0"
# shellcheck disable=SC2016 # the literal line the installer prints
expect 'export PATH="$HOME/.hardcharger/bin:$PATH"'
is_current 1.1.0
[ "$("$P/bin/hardcharger-server" --version)" = "Hardcharger 1.1.0" ] || fail "bin/hardcharger-server isn't 1.1.0"
[ "$("$P/bin/hardcharger" --version)" = "Hardcharger Client 1.1.0" ] || fail "bin/hardcharger isn't 1.1.0's client"
[ -f "$P/versions/1.1.0/lib/libfixture.txt" ] || fail "lib/ wasn't installed"

step "1b. The token went to the API, never to the storage host"
grep -q '^/api/.* auth=yes$' "$ROOT/internal.log" || fail "no authorized API request"
grep -q '^/storage/.*' "$ROOT/internal.log" || fail "nothing was fetched from storage"
if grep -q '^/storage/.* auth=yes$' "$ROOT/internal.log"; then fail "the token was sent to the storage host"; fi

step "2. Same version again: nothing to do"
# shellcheck disable=SC2086
run 0 $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=1.1.0 --
expect "Hardcharger 1.1.0 is installed and current"
expect_not "Downloading"

step "3. Downgrade to 0.1.9 (whose server was named hardcharger) with --version v0.1.9"
# shellcheck disable=SC2086
run 0 $INTERNAL $WITH_TOKEN -- --version v0.1.9
expect "Checksum OK (SHA256SUMS and GitHub's asset digest)"
expect "Installed Hardcharger 0.1.9"
expect "(was 1.1.0)"
is_current 0.1.9
[ "$("$P/bin/hardcharger-server" --version)" = "Hardcharger 0.1.9" ] || fail "0.1.9's server isn't bin/hardcharger-server"
[ ! -e "$P/bin/hardcharger" ] || fail "0.1.9 has no client, but bin/hardcharger is still there"
[ ! -e "$P/versions/0.1.9/bin/hardcharger" ] || fail "0.1.9's server wasn't renamed"
expect "HARDCHARGER_PASSWORD=change-me"

step "4. Switch back to 1.1.0: no download, offline, no token"
# shellcheck disable=SC2086
run 0 $INTERNAL $NO_TOKEN HARDCHARGER_VERSION=1.1.0 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 --
expect "Switched to Hardcharger 1.1.0 (already installed; nothing downloaded), from 0.1.9"
expect_not "Downloading"
is_current 1.1.0
[ -e "$P/bin/hardcharger" ] || fail "switching back didn't restore bin/hardcharger"

step "5. GH_TOKEN works as the token"
# shellcheck disable=SC2086
run 0 $INTERNAL GH_TOKEN=$TOKEN HARDCHARGER_VERSION=1.0.0 --
expect "Installed Hardcharger 1.0.0"

step "5b. So does \`gh auth token\`"
mkdir -p "$ROOT/fakegh"
# shellcheck disable=SC2016 # a script written out verbatim
printf '#!/bin/sh\n[ "$1 $2" = "auth token" ] && echo "%s"\n' "$TOKEN" > "$ROOT/fakegh/gh"
chmod +x "$ROOT/fakegh/gh"
# shellcheck disable=SC2086
run 0 $INTERNAL PATH="$ROOT/fakegh:$PATH" HARDCHARGER_VERSION=1.1.0 --
is_current 1.1.0

step "6. --list"
run 0 -- --list
expect "* 1.1.0 (current)"
expect "    1.0.0"
expect "    0.1.9"

step "7. A corrupted download is refused, and 1.1.0 stays current"
# shellcheck disable=SC2086
run nonzero $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=1.0.2 --
expect "checksum mismatch for $ASSET: SHA256SUMS says"
expect "Nothing was changed"
is_current 1.1.0
[ ! -e "$P/versions/1.0.2" ] || fail "a refused download left versions/1.0.2"
[ -z "$(find "$P" -maxdepth 1 -name '.install.*')" ] || fail "temporary files left in $P"

step "8. A SHA256SUMS without the asset's line is refused"
# shellcheck disable=SC2086
run nonzero $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=1.0.3 --
expect "the release's SHA256SUMS has no line for $ASSET"
is_current 1.1.0

step "9. A wrong GitHub digest is refused"
# shellcheck disable=SC2086
run nonzero $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=1.0.4 --
expect "checksum mismatch for $ASSET: GitHub says 1111111111111111111111111111111111111111111111111111111111111111"
is_current 1.1.0

step "10. A build whose server doesn't run is refused"
# shellcheck disable=SC2086
run nonzero $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=1.0.1 --
expect "fixture: simulated loader failure"
expect "Hardcharger 1.0.1 doesn't run on this system, so it wasn't installed; 1.1.0 is still current"
is_current 1.1.0
[ ! -e "$P/versions/1.0.1" ] || fail "a build that doesn't run was kept"

step "11. A release without this platform's asset"
# shellcheck disable=SC2086
run nonzero $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=1.0.5 --
expect "Hardcharger 1.0.5 has no $ASSET to download"
expect_not "While the releases are internal"

step "12. A version that doesn't exist"
# shellcheck disable=SC2086
run nonzero $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=7.7.7 --
expect "GitHub has no Hardcharger release '7.7.7' that this token can read"

# ---- internal releases, no token ----------------------------------------------------------------
step "13. Internal releases without a token: a clear message, nothing installed"
# shellcheck disable=SC2086
run nonzero $INTERNAL $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-internal" --
expect "set HARDCHARGER_INSTALL_TOKEN to a GitHub token that can read gizmodata/hardcharger"
# shellcheck disable=SC2086
run nonzero $INTERNAL $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-internal" HARDCHARGER_VERSION=1.0.0 --
expect "Hardcharger 1.0.0 has no $ASSET to download"
expect "While the releases are internal, set HARDCHARGER_INSTALL_TOKEN"
[ ! -e "$ROOT/anon-internal/versions" ] || fail "a failed anonymous install left versions/"
run 0 HARDCHARGER_PREFIX="$ROOT/anon-internal" -- --uninstall
expect "it was empty"
[ ! -e "$ROOT/anon-internal" ] || fail "--uninstall left the empty prefix of a failed install"

# ---- public releases, anonymous -------------------------------------------------------------------
: > "$ROOT/public.log"
step "14. Public releases, anonymous: latest"
# shellcheck disable=SC2086
run 0 $PUBLIC $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon" --
expect "Installed Hardcharger 1.1.0"
expect "Checksum OK (GitHub's asset digest)"
[ "$("$ROOT/anon/bin/hardcharger-server" --version)" = "Hardcharger 1.1.0" ] || fail "anonymous latest isn't 1.1.0"
grep -q '/web/gizmodata/hardcharger/releases/download/v1.1.0/' "$ROOT/public.log" || fail "anonymous download didn't use the web download URL"
if grep -q 'auth=yes' "$ROOT/public.log"; then fail "an anonymous install sent an Authorization header"; fi

step "15. Public, anonymous, pinned, with SHA256SUMS from the web download URL"
# shellcheck disable=SC2086
run 0 $PUBLIC $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon" HARDCHARGER_VERSION=1.0.0 --
expect "Checksum OK (SHA256SUMS and GitHub's asset digest)"

step "16. Public, anonymous, and the API refuses (rate limit): web fallbacks"
rl="HARDCHARGER_INSTALL_GITHUB_API=http://127.0.0.1:9 HARDCHARGER_INSTALL_GITHUB_WEB=$public_URL/web"
# shellcheck disable=SC2086
run 0 $rl $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-rl" --
expect "Installed Hardcharger 1.1.0"
expect "no checksum is published for $ASSET"
# shellcheck disable=SC2086
run 0 $rl $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-rl" HARDCHARGER_VERSION=1.0.0 --
expect "Checksum OK (SHA256SUMS)"
# shellcheck disable=SC2086
run nonzero $rl $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-rl" HARDCHARGER_VERSION=1.0.2 --
expect "checksum mismatch for $ASSET: SHA256SUMS says"

# ---- PATH, prefix, uninstall ---------------------------------------------------------------------
step "17. --modify-path (bash), twice: one line"
run 0 SHELL=/bin/bash HARDCHARGER_VERSION=1.1.0 -- --modify-path
case "$PLATFORM" in macos-*) rcf="$HOME/.bash_profile" ;; *) rcf="$HOME/.bashrc" ;; esac
[ "$(grep -cF '.hardcharger/bin' "$rcf")" = 1 ] || fail "$rcf should add .hardcharger/bin once"
run 0 SHELL=/bin/bash HARDCHARGER_VERSION=1.1.0 -- --modify-path
expect "already adds"
[ "$(grep -cF '.hardcharger/bin' "$rcf")" = 1 ] || fail "$rcf should still add .hardcharger/bin once"

step "18. --prefix outside HOME"
# shellcheck disable=SC2086
run 0 $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=1.0.0 -- --prefix "$ROOT/custom"
expect "export PATH=\"$ROOT/custom/bin:\$PATH\""
[ "$("$ROOT/custom/bin/hardcharger-server" --version)" = "Hardcharger 1.0.0" ] || fail "--prefix install doesn't run"
run 0 -- --prefix "$ROOT/custom" --uninstall
[ ! -e "$ROOT/custom" ] || fail "--prefix --uninstall left $ROOT/custom"

step "19. Uninstall 0.1.9 (not current)"
run 0 -- --uninstall 0.1.9
expect "Removed Hardcharger 0.1.9"
[ ! -e "$P/versions/0.1.9" ] || fail "versions/0.1.9 is still there"
is_current 1.1.0

step "20. Uninstall the current version"
run 0 -- --uninstall 1.1.0
expect "no version is current now. Installed: 1.0.0"
[ ! -e "$P/bin/hardcharger-server" ] || fail "bin/hardcharger-server still points at a removed version"
[ ! -e "$P/bin/hardcharger" ] || fail "bin/hardcharger still points at a removed version"

step "21. Uninstall everything"
run 0 -- --uninstall
expect "Removed $P"
expect "has the Hardcharger installer's PATH line; delete it"
[ ! -e "$P" ] || fail "$P is still there"
run 0 -- --uninstall
expect "Nothing to remove"

echo
echo "ALL FIXTURE SCENARIOS PASSED ($PLATFORM, $SH)"
