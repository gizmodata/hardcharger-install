#!/bin/sh
# install.sh end to end against fixture releases served by a local stand-in for GitHub
# (fake_github.py), so it needs no credentials and no real release. Two servers run: one
# "internal" (the API and downloads need a token, as gizmodata/hardcharger's did before launch) and
# one "public" (anonymous). Covered: latest and pinned installs with a token and anonymously,
# the token going to the API but never to the storage host, GH_TOKEN and `gh auth token`,
# downgrade, switching back without a download, the Get started lines, --list, SHA256SUMS and
# GitHub's digest (good, corrupted, missing a line, wrong digest, neither: refused unless
# HARDCHARGER_INSTALL_SHA256), a mirror's own SHA256SUMS not trusted, a version with a line break,
# a pipe or an outward link in the archive, the https-only test overrides, a cut-short script, a build that
# doesn't run, a release without this platform's asset, an unknown version, --modify-path,
# --prefix, and every uninstall.
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
unset HARDCHARGER_INSTALL_TOKEN GH_TOKEN HARDCHARGER_VERSION HARDCHARGER_PREFIX HARDCHARGER_INSTALL_MIRROR HARDCHARGER_INSTALL_SHA256 HARDCHARGER_INSTALL_ALLOW_HTTP 2>/dev/null || true
# Nothing here may reach the real GitHub: a step that names no fake server gets a dead one.
# The stand-ins are plain http, which the installer allows only with the test flag.
export HARDCHARGER_INSTALL_GITHUB_API=http://127.0.0.1:9 HARDCHARGER_INSTALL_GITHUB_WEB=http://127.0.0.1:9 HARDCHARGER_INSTALL_TEST_INSECURE=1

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
    --token "$TOKEN" ${2:+"$2"} 2>"$ROOT/$1.err" &
  pid=$!
  PIDS="$PIDS $pid"
  i=0
  until [ -s "$ROOT/$1.port" ]; do
    i=$((i + 1))
    if [ "$i" -ge 600 ] || ! kill -0 "$pid" 2>/dev/null; then
      cat "$ROOT/$1.err" >&2
      fail "fake GitHub ($1) didn't start ($PY)"
    fi
    sleep 0.1
  done
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

step "1a. Get started: the client line turns TLS off, since the server it starts has none"
# The server runs without TLS by default and the client defaults to TLS: without --tls=false the
# printed client line fails with "speaks plain HTTP, not TLS".
expect "HARDCHARGER_ADMIN_PASSWORD=change-me $P/bin/hardcharger-server --database my.duckdb"
expect "HARDCHARGER_PASSWORD=change-me $P/bin/hardcharger --tls=false --username hardcharger"

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
expect "HARDCHARGER_PASSWORD=change-me $P/bin/hardcharger-server --database my.duckdb"
expect_not "--tls=false"   # no client in 0.1.9, so no client line

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
expect_not "is not a released version"   # the API described 1.0.5, so it exists
expect_not "releases are internal"

step "12. A version that doesn't exist"
# shellcheck disable=SC2086
run nonzero $INTERNAL $WITH_TOKEN HARDCHARGER_VERSION=7.7.7 --
expect "GitHub has no Hardcharger release '7.7.7' that this token can read"

# ---- internal releases, no token ----------------------------------------------------------------
step "13. No token and GitHub answers nothing: a clear message, nothing installed"
# (The "internal" server refuses every anonymous request, as a rate-limited API does.)
# shellcheck disable=SC2086
run nonzero $INTERNAL $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-internal" --
expect "couldn't find Hardcharger's latest release on GitHub"
expect "set HARDCHARGER_INSTALL_TOKEN to a GitHub token"
expect_not "releases are internal"
# shellcheck disable=SC2086
run nonzero $INTERNAL $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-internal" HARDCHARGER_VERSION=1.0.0 --
expect "Hardcharger 1.0.0 has no $ASSET to download"
expect "If 1.0.0 is not a released version, pick one from https://github.com/gizmodata/hardcharger/releases"
expect_not "releases are internal"
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

step "15b. Public, anonymous, a version that was never released: the message says so"
# shellcheck disable=SC2086
run nonzero $PUBLIC $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon" HARDCHARGER_VERSION=7.7.7 --
expect "Hardcharger 7.7.7 has no $ASSET to download"
expect "If 7.7.7 is not a released version, pick one from https://github.com/gizmodata/hardcharger/releases"
expect_not "releases are internal"
[ "$("$ROOT/anon/bin/hardcharger-server" --version)" = "Hardcharger 1.0.0" ] || fail "a failed install changed the current version"

step "16. Public, anonymous, and the API refuses (rate limit): web fallbacks"
rl="HARDCHARGER_INSTALL_GITHUB_API=http://127.0.0.1:9 HARDCHARGER_INSTALL_GITHUB_WEB=$public_URL/web"
# 1.1.0 has no SHA256SUMS, and its GitHub digest is only in the API's answer: with the API refusing,
# no checksum can be found, so nothing is installed (it used to install, "relying on HTTPS alone").
# shellcheck disable=SC2086
run nonzero $rl $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-rl" --
expect "no checksum for $ASSET could be found"
[ ! -e "$ROOT/anon-rl/versions/1.1.0" ] || fail "1.1.0 was installed without a checksum"
# shellcheck disable=SC2086
run 0 $rl $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-rl" HARDCHARGER_INSTALL_SHA256="$(sum "$F/v1.1.0/$ASSET")" --
expect "Checksum OK (HARDCHARGER_INSTALL_SHA256)"
expect "Installed Hardcharger 1.1.0"
# shellcheck disable=SC2086
run nonzero $rl $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-rl2" HARDCHARGER_INSTALL_SHA256=1111111111111111111111111111111111111111111111111111111111111111 --
expect "checksum mismatch for $ASSET: HARDCHARGER_INSTALL_SHA256 says 1111111111111111111111111111111111111111111111111111111111111111"
# shellcheck disable=SC2086
run 0 $rl $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-rl" HARDCHARGER_VERSION=1.0.0 --
expect "Checksum OK (SHA256SUMS)"
# shellcheck disable=SC2086
run nonzero $rl $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/anon-rl" HARDCHARGER_VERSION=1.0.2 --
expect "checksum mismatch for $ASSET: SHA256SUMS says"

# ---- the security review's findings (F5-F7, F9, F10) ----------------------------------------------
step "16a. A mirror's own SHA256SUMS is not trusted: its build of 1.0.0 is checked against the release's"
EM="$ROOT/evil-mirror/v1.0.0"; mkdir -p "$EM"
# A valid build, but not the release's: 1.0.0 plus a file of the mirror's own.
mkdir -p "$ROOT/evil-build"; cp -R "$ROOT/build/1.0.0/hardcharger-$PLATFORM" "$ROOT/evil-build/"
echo "NOT-THE-REAL-BUILD" > "$ROOT/evil-build/hardcharger-$PLATFORM/lib/evil.txt"
tar -czf "$EM/$ASSET" -C "$ROOT/evil-build" "hardcharger-$PLATFORM"
echo "$(sum "$EM/$ASSET")  $ASSET" > "$EM/SHA256SUMS"
# shellcheck disable=SC2086
run nonzero $PUBLIC $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/mirror-p" HARDCHARGER_VERSION=1.0.0 HARDCHARGER_INSTALL_MIRROR="$ROOT/evil-mirror" --
expect "checksum mismatch for $ASSET: SHA256SUMS says $(sum "$F/v1.0.0/$ASSET")"
[ ! -e "$ROOT/mirror-p/versions/1.0.0" ] || fail "the mirror's build was installed"
# shellcheck disable=SC2086
run nonzero $PUBLIC $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/mirror-p" HARDCHARGER_VERSION=1.0.0 HARDCHARGER_INSTALL_TEST_INSECURE= HARDCHARGER_INSTALL_GITHUB_API=https://127.0.0.1:9 HARDCHARGER_INSTALL_GITHUB_WEB=https://127.0.0.1:9 HARDCHARGER_INSTALL_MIRROR=http://127.0.0.1:9/m --
expect "HARDCHARGER_INSTALL_MIRROR http://127.0.0.1:9/m is plain http: set HARDCHARGER_INSTALL_ALLOW_HTTP=1"

step "16b. A version must be one line of [0-9A-Za-z.+-]: a line break is refused"
set +e
env "HARDCHARGER_VERSION=$(printf '1.0.0\nx')" HARDCHARGER_PREFIX="$ROOT/v-p" "$SH" -s < "$INSTALLER" > "$OUT" 2>&1; code=$?
set -e
sed 's/^/  | /' "$OUT"
[ "$code" != 0 ] || fail "a version with a line break was accepted"
expect "must be latest, X.Y.Z or vX.Y.Z"

step "16c. An archive holding a device-like entry or a link out of the build is refused"
# 1.0.5: a named pipe; 1.0.6: a link to an absolute path; both with a good SHA256SUMS.
for v in 1.0.5 1.0.6; do
  d="$ROOT/build/$v/hardcharger-$PLATFORM"; mkdir -p "$d/bin" "$d/lib"
  printf '#!/bin/sh\necho "Hardcharger %s"\n' "$v" > "$d/bin/hardcharger-server"; chmod +x "$d/bin/hardcharger-server"
  if [ "$v" = 1.0.5 ]; then mkfifo "$d/lib/pipe"; else ln -s /etc/passwd "$d/lib/passwd"; fi
  mkdir -p "$F/v$v"; tar -czf "$F/v$v/$ASSET" -C "$ROOT/build/$v" "hardcharger-$PLATFORM"; sums "$v"
done
# shellcheck disable=SC2086
run nonzero $PUBLIC $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/odd-p" HARDCHARGER_VERSION=1.0.5 --
expect "lib/pipe, which is not a regular file, folder or link; not installing it"
# shellcheck disable=SC2086
run nonzero $PUBLIC $NO_TOKEN HARDCHARGER_PREFIX="$ROOT/odd-p" HARDCHARGER_VERSION=1.0.6 --
expect "lib/passwd, a link to /etc/passwd outside the build; not installing it"
[ ! -e "$ROOT/odd-p/versions/1.0.6" ] || fail "an archive with a link out of the build was installed"

step "16d. The test-only GitHub overrides must be https without the test flag"
run nonzero HARDCHARGER_INSTALL_TEST_INSECURE= HARDCHARGER_VERSION=1.0.0 --
expect "HARDCHARGER_INSTALL_GITHUB_API and _WEB are test settings and must be https:// (got http://127.0.0.1:9)"

step "16e. A download cut short at any line runs nothing (curl | sh runs what has arrived)"
lines="$(wc -l < "$INSTALLER" | tr -d ' ')"
ls -la "$P" > "$ROOT/prefix.before" 2>&1 || true
n=1
while [ "$n" -lt "$lines" ]; do
  # shellcheck disable=SC2086
  head -n "$n" "$INSTALLER" | env $PUBLIC $NO_TOKEN "$SH" > "$OUT" 2>&1 || true
  if grep -q -e Downloading -e Installed -e Switched -e Removed "$OUT"; then fail "the first $n lines did something"; fi
  n=$((n + 1))
done
ls -la "$P" > "$ROOT/prefix.after" 2>&1 || true
cmp -s "$ROOT/prefix.before" "$ROOT/prefix.after" || fail "a cut-short script changed $P"
echo "  every prefix of the $lines lines ran nothing"

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
