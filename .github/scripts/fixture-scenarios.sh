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
# --prefix, and every uninstall. Then the CPU target (Linux x86-64's optimized and baseline builds,
# on every host: a fake uname says Linux x86_64 and HARDCHARGER_INSTALL_TEST_CPUINFO stands in for
# /proc/cpuinfo): auto on a v3 CPU and on kvm64, forced builds, switching builds of one version
# (a reinstall) and between versions (none), --list, the baseline's checksum (SHA256SUMS, GitHub's
# digest, a mirror, HARDCHARGER_INSTALL_SHA256), the token path, and a version with no baseline build.
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
unset HARDCHARGER_INSTALL_TOKEN GH_TOKEN HARDCHARGER_VERSION HARDCHARGER_PREFIX HARDCHARGER_INSTALL_MIRROR HARDCHARGER_INSTALL_SHA256 HARDCHARGER_INSTALL_ALLOW_HTTP HARDCHARGER_CPU_TARGET 2>/dev/null || true
# Nothing here may reach the real GitHub: a step that names no fake server gets a dead one.
# The stand-ins are plain http, which the installer allows only with the test flag.
export HARDCHARGER_INSTALL_GITHUB_API=http://127.0.0.1:9 HARDCHARGER_INSTALL_GITHUB_WEB=http://127.0.0.1:9 HARDCHARGER_INSTALL_TEST_INSECURE=1
# On Linux x86-64 the installer reads /proc/cpuinfo to choose between the optimized and the baseline
# build. The host's CPU must not decide what these tests see (Docker's x86-64 emulation on Apple
# silicon lacks abm and xsave, for one), so every step reads a CPU with every feature, unless it says otherwise.
printf 'flags\t\t: fpu sse sse2 cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave\n' > "$ROOT/v3"
export HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/v3"

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

serve() {   # serve <name> <fixture root> [--private]: starts a server, sets <name>_URL
  sname="$1"; sroot="$2"; sflag="${3:-}"
  "$PY" "$HERE/fake_github.py" --root "$sroot" --port 0 --port-file "$ROOT/$sname.port" --log "$ROOT/$sname.log" \
    --token "$TOKEN" ${sflag:+"$sflag"} 2>"$ROOT/$sname.err" &
  pid=$!
  PIDS="$PIDS $pid"
  i=0
  until [ -s "$ROOT/$sname.port" ]; do
    i=$((i + 1))
    if [ "$i" -ge 600 ] || ! kill -0 "$pid" 2>/dev/null; then
      cat "$ROOT/$sname.err" >&2
      fail "fake GitHub ($sname) didn't start ($PY)"
    fi
    sleep 0.1
  done
  eval "${sname}_URL=http://127.0.0.1:$(cat "$ROOT/$sname.port")"
}
serve internal "$F" --private
serve public "$F"
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

# ---- the CPU target: Linux x86-64's optimized and baseline builds (hardcharger#62) ----------------
# On every host: a fake uname/getconf/ldd make this Linux x86_64 with glibc 2.39, the fixture
# builds are shell scripts, and HARDCHARGER_INSTALL_TEST_CPUINFO stands in for /proc/cpuinfo.
FL="$ROOT/fakelinux"; mkdir -p "$FL"
# shellcheck disable=SC2016 # scripts written out verbatim
printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$FL/uname"
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in LONG_BIT) echo 64 ;; GNU_LIBC_VERSION) echo "glibc 2.39" ;; *) exit 1 ;; esac\n' > "$FL/getconf"
printf '#!/bin/sh\necho "ldd (GNU libc) 2.39"\n' > "$FL/ldd"
chmod +x "$FL"/*
printf 'model name\t: Common KVM processor\nflags\t\t: fpu de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ht syscall nx lm constant_tsc nopl xtopology cpuid pni cx16 hypervisor pti\n' > "$ROOT/kvm64"
CF="$ROOT/cpu-fixtures"
OA="hardcharger-linux-amd64.tar.gz"
BA="hardcharger-linux-amd64-baseline.tar.gz"
# cbuild <version> <optimized|baseline>: a tarball laid out like the release's, whose lib/build.txt
# says which build it is.
cbuild() {
  n="hardcharger-linux-amd64"; [ "$2" = optimized ] || n="$n-$2"
  d="$ROOT/cpu-build/$1-$2/$n"
  mkdir -p "$d/bin" "$d/lib"
  printf '#!/bin/sh\necho "Hardcharger %s"\n' "$1" > "$d/bin/hardcharger-server"
  printf '#!/bin/sh\necho "Hardcharger Client %s"\n' "$1" > "$d/bin/hardcharger"
  chmod +x "$d/bin/"*
  echo "$2" > "$d/lib/build.txt"
  echo "fixture" > "$d/LICENSE"
  mkdir -p "$CF/v$1"
  tar -czf "$CF/v$1/$n.tar.gz" -C "$ROOT/cpu-build/$1-$2" "$n"
}
csums() { : > "$CF/v$1/SHA256SUMS"; for a in "$CF/v$1"/*.tar.gz; do echo "$(sum "$a")  $(basename "$a")" >> "$CF/v$1/SHA256SUMS"; done; }
cbuild 2.13.1 optimized; csums 2.13.1                              # before the baseline build
cbuild 2.13.0 optimized                                            # before it too, and dies of SIGILL,
printf '#!/bin/sh\nkill -ILL $$\n' > "$ROOT/cpu-build/2.13.0-optimized/hardcharger-linux-amd64/bin/hardcharger-server"
tar -czf "$CF/v2.13.0/$OA" -C "$ROOT/cpu-build/2.13.0-optimized" hardcharger-linux-amd64; csums 2.13.0   # as on kvm64
cbuild 2.13.5 optimized; cbuild 2.13.5 baseline                    # its optimized build refuses this CPU, as 2.13.2's do
printf '#!/bin/sh\necho "hardcharger-server: this build needs an x86-64-v3 CPU (AVX2: Intel Haswell, AMD Excavator or newer), and this one lacks: avx2." >&2\necho "Download the baseline build, which runs on any x86-64 CPU: hardcharger-linux-amd64-baseline.tar.gz" >&2\nexit 1\n' > "$ROOT/cpu-build/2.13.5-optimized/hardcharger-linux-amd64/bin/hardcharger-server"
tar -czf "$CF/v2.13.5/$OA" -C "$ROOT/cpu-build/2.13.5-optimized" hardcharger-linux-amd64; csums 2.13.5
cbuild 2.13.2 optimized; cbuild 2.13.2 baseline; csums 2.13.2      # the first with both
cbuild 2.13.3 optimized; cbuild 2.13.3 baseline; csums 2.13.3      # the baseline corrupted after SHA256SUMS
size=$(wc -c < "$CF/v2.13.3/$BA" | tr -d ' ')
printf 'X' | dd of="$CF/v2.13.3/$BA" bs=1 seek=$((size / 2)) conv=notrunc 2>/dev/null
cbuild 2.13.4 optimized; cbuild 2.13.4 baseline                    # GitHub's digest of the baseline is wrong
echo "$BA sha256:1111111111111111111111111111111111111111111111111111111111111111" > "$CF/v2.13.4/digest-override"
# The latest. Its optimized tarball carries a marker file saying "baseline": only the installer may
# write that file, so it must not make this build count as the baseline one.
mkdir -p "$ROOT/cpu-build/2.14.0-optimized/hardcharger-linux-amd64"
echo baseline > "$ROOT/cpu-build/2.14.0-optimized/hardcharger-linux-amd64/.hardcharger-build"
cbuild 2.14.0 optimized; cbuild 2.14.0 baseline; csums 2.14.0
serve cpupub "$CF"
serve cpuint "$CF" --private
# shellcheck disable=SC2154 # set by serve
CPUPUB="PATH=$FL:$PATH HARDCHARGER_INSTALL_GITHUB_API=$cpupub_URL/api HARDCHARGER_INSTALL_GITHUB_WEB=$cpupub_URL/web $NO_TOKEN"
# Offline: the fake Linux, and no GitHub (the dead server every step gets by default).
CPUOFF="PATH=$FL:$PATH $NO_TOKEN"
CP="$ROOT/cpu"
KVM="HARDCHARGER_INSTALL_TEST_CPUINFO=$ROOT/kvm64"
V3="HARDCHARGER_INSTALL_TEST_CPUINFO=$ROOT/v3"
cur_build() { cat "$CP/versions/$1/lib/build.txt"; }
ccurrent() { readlink "$CP/bin/hardcharger-server" 2>/dev/null | sed 's|^\.\./versions/||; s|/.*||'; }
cis_current() { [ "$(ccurrent)" = "$1" ] || fail "current version is '$(ccurrent)', expected '$1'"; }

step "22. auto on a v3 CPU: the optimized build, as before"
# shellcheck disable=SC2086
run 0 $CPUPUB $V3 -- --prefix "$CP"
expect "Downloading Hardcharger 2.14.0 for linux-amd64 ($OA)"
expect "Installed Hardcharger 2.14.0 in $CP/versions/2.14.0"
expect_not "baseline"
[ "$(cur_build 2.14.0)" = optimized ] || fail "auto on a v3 CPU didn't install the optimized build"
[ ! -e "$CP/versions/2.14.0/.hardcharger-build" ] || fail "the tarball's own .hardcharger-build was kept"
run 0 -- --prefix "$CP" --list
expect "  * 2.14.0 (current)"
expect_not "baseline"

step "23. auto on kvm64: the baseline build, with why and how to choose; it replaces the optimized one"
# shellcheck disable=SC2086
run 0 $CPUPUB $KVM -- --prefix "$CP"
expect "this CPU lacks lahf_lm popcnt sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave, which Hardcharger's optimized Linux x86-64 build needs"
expect "It runs on any x86-64 CPU, but slower."
expect "can hide the host's CPU features"
expect "To choose the build yourself: --cpu-target optimized or --cpu-target baseline"
expect "Hardcharger 2.14.0 is installed as the optimized build; replacing it with the baseline build"
expect "Downloading Hardcharger 2.14.0 for linux-amd64 ($BA)"
expect "Checksum OK (SHA256SUMS and GitHub's asset digest)"
expect "Installed Hardcharger 2.14.0 (baseline build) in $CP/versions/2.14.0 (was its optimized build)"
[ "$(cur_build 2.14.0)" = baseline ] || fail "auto on kvm64 didn't install the baseline build"
cis_current 2.14.0
[ "$("$CP/bin/hardcharger-server" --version)" = "Hardcharger 2.14.0" ] || fail "bin/hardcharger-server isn't 2.14.0"
grep -q "/web/gizmodata/hardcharger/releases/download/v2.14.0/$BA" "$ROOT/cpupub.log" || fail "the baseline tarball wasn't downloaded from the release"
run 0 -- --prefix "$CP" --list
expect "  * 2.14.0 (current, baseline)"

step "24. auto on kvm64 again: installed and current, nothing downloaded"
# shellcheck disable=SC2086
run 0 $CPUOFF $KVM HARDCHARGER_VERSION=2.14.0 -- --prefix "$CP"
expect "Hardcharger 2.14.0 (baseline build) is installed and current"
expect_not "Downloading"

step "25. --cpu-target optimized on kvm64 replaces the baseline build with the optimized one"
# shellcheck disable=SC2086
run 0 $CPUPUB $KVM -- --prefix "$CP" --version 2.14.0 --cpu-target optimized
expect_not "this CPU lacks"
expect "Hardcharger 2.14.0 is installed as the baseline build; replacing it with the optimized build"
expect "Downloading Hardcharger 2.14.0 for linux-amd64 ($OA)"
expect "Installed Hardcharger 2.14.0 in $CP/versions/2.14.0 (was its baseline build)"
[ "$(cur_build 2.14.0)" = optimized ] || fail "--cpu-target optimized didn't install the optimized build"
[ ! -e "$CP/versions/2.14.0/.hardcharger-build" ] || fail "the optimized build kept the baseline marker"

step "26. --cpu-target=baseline on a v3 CPU, another version: 2.13.2's baseline build"
# shellcheck disable=SC2086
run 0 $CPUPUB $V3 -- --prefix "$CP" --version v2.13.2 --cpu-target=baseline
expect_not "this CPU lacks"
expect "Downloading Hardcharger 2.13.2 for linux-amd64 ($BA)"
expect "Installed Hardcharger 2.13.2 (baseline build) in $CP/versions/2.13.2 (was 2.14.0)"
[ "$(cur_build 2.13.2)" = baseline ] || fail "2.13.2 isn't the baseline build"
run 0 -- --prefix "$CP" --list
expect "  * 2.13.2 (current, baseline)"
expect "    2.14.0"
expect_not "2.14.0 (baseline)"

step "27. Switching between installed versions keeps each one's build and downloads nothing"
# shellcheck disable=SC2086
run 0 $CPUOFF $V3 HARDCHARGER_VERSION=2.14.0 -- --prefix "$CP"
expect "Switched to Hardcharger 2.14.0 (already installed; nothing downloaded), from 2.13.2"
expect_not "Downloading"
cis_current 2.14.0
# shellcheck disable=SC2086
run 0 $CPUOFF $V3 HARDCHARGER_CPU_TARGET=baseline HARDCHARGER_VERSION=2.13.2 -- --prefix "$CP"
expect "Switched to Hardcharger 2.13.2 (baseline build; already installed, nothing downloaded), from 2.14.0"
expect_not "Downloading"
cis_current 2.13.2
[ "$(cur_build 2.13.2)" = baseline ] || fail "switching changed 2.13.2's build"

step "28. auto on a v3 CPU, 2.13.2: the baseline build installed is replaced by the optimized one"
# shellcheck disable=SC2086
run 0 $CPUPUB $V3 HARDCHARGER_VERSION=2.13.2 -- --prefix "$CP"
expect "Hardcharger 2.13.2 is installed as the baseline build; replacing it with the optimized build"
expect "Installed Hardcharger 2.13.2 in $CP/versions/2.13.2 (was its baseline build)"
[ "$(cur_build 2.13.2)" = optimized ] || fail "2.13.2 isn't the optimized build"

step "29. A corrupted baseline tarball is refused, and nothing changes"
# shellcheck disable=SC2086
run nonzero $CPUPUB $V3 HARDCHARGER_CPU_TARGET=baseline HARDCHARGER_VERSION=2.13.3 -- --prefix "$CP"
expect "checksum mismatch for $BA: SHA256SUMS says"
expect "Nothing was changed"
cis_current 2.13.2
[ ! -e "$CP/versions/2.13.3" ] || fail "a refused baseline download left versions/2.13.3"
# shellcheck disable=SC2086
run nonzero $CPUPUB $V3 HARDCHARGER_CPU_TARGET=baseline HARDCHARGER_VERSION=2.13.4 -- --prefix "$CP"
expect "checksum mismatch for $BA: GitHub says 1111111111111111111111111111111111111111111111111111111111111111"
[ ! -e "$CP/versions/2.13.4" ] || fail "a baseline tarball with a wrong digest was installed"
# Replacing the current version's build: a refused download keeps the build installed.
# shellcheck disable=SC2086
run nonzero $CPUPUB $KVM HARDCHARGER_VERSION=2.13.2 HARDCHARGER_INSTALL_SHA256=1111111111111111111111111111111111111111111111111111111111111111 -- --prefix "$CP"
expect "Hardcharger 2.13.2 is installed as the optimized build; replacing it with the baseline build"
expect "checksum mismatch for $BA: HARDCHARGER_INSTALL_SHA256 says"
cis_current 2.13.2
[ "$(cur_build 2.13.2)" = optimized ] || fail "a refused baseline download changed 2.13.2's build"

step "30. A version from before the baseline build: --cpu-target baseline is refused before any download; auto tries the optimized build"
# shellcheck disable=SC2086
run nonzero $CPUPUB $V3 HARDCHARGER_VERSION=2.13.1 -- --prefix "$CP" --cpu-target baseline
expect "Hardcharger 2.13.1 has no baseline build: the baseline build is released from 2.13.2 on."
expect_not "Downloading"
# auto: /proc/cpuinfo may leave out features the CPU runs (Docker's x86-64 emulation on Apple silicon
# lists no abm or xsave, yet runs the optimized build), so the optimized build is tried, and installed
# only if it runs. One that dies of SIGILL, as before 2.13.2 on kvm64, changes nothing.
# shellcheck disable=SC2086
run nonzero $CPUPUB $KVM HARDCHARGER_VERSION=2.13.0 -- --prefix "$CP"
expect "and Hardcharger 2.13.0 has no baseline build: the baseline build is released from 2.13.2 on. Trying 2.13.0's optimized build"
expect "Downloading Hardcharger 2.13.0 for linux-amd64 ($OA)"
expect "Illegal instruction (exit 132)"
expect "This CPU lacks instructions Hardcharger's optimized Linux x86-64 build needs. The baseline build, for any x86-64 CPU, is released from 2.13.2 on: install the latest release (the default) or pin 2.13.2 or newer."
expect "Hardcharger 2.13.0 doesn't run on this system, so it wasn't installed; 2.13.2 is still current"
cis_current 2.13.2
[ ! -e "$CP/versions/2.13.0" ] || fail "a build that died of SIGILL was kept"
# One that runs (the emulator's case) is installed.
# shellcheck disable=SC2086
run 0 $CPUPUB $KVM HARDCHARGER_VERSION=2.13.1 -- --prefix "$CP"
expect "Trying 2.13.1's optimized build: it is installed only if it runs here"
expect "Installed Hardcharger 2.13.1 in $CP/versions/2.13.1 (was 2.13.2)"
cis_current 2.13.1
[ "$(cur_build 2.13.1)" = optimized ] || fail "2.13.1 isn't the optimized build"

step "30b. An optimized build that refuses this CPU (2.13.2's own check): the hint names --cpu-target baseline"
# shellcheck disable=SC2086
run nonzero $CPUPUB $V3 HARDCHARGER_VERSION=2.13.5 -- --prefix "$CP"
expect "this build needs an x86-64-v3 CPU"
expect "The baseline build runs on any x86-64 CPU, but slower: run this again with --cpu-target baseline (HARDCHARGER_CPU_TARGET=baseline)."
expect "Hardcharger 2.13.5 doesn't run on this system, so it wasn't installed; 2.13.1 is still current"
cis_current 2.13.1
# Positive twin: the baseline build of that version installs.
# shellcheck disable=SC2086
run 0 $CPUPUB $V3 HARDCHARGER_VERSION=2.13.5 -- --prefix "$CP" --cpu-target baseline
expect "Installed Hardcharger 2.13.5 (baseline build) in $CP/versions/2.13.5 (was 2.13.1)"

step "31. The baseline build from a mirror: checked against the release's SHA256SUMS, or HARDCHARGER_INSTALL_SHA256"
CM="$ROOT/cpu-mirror/v2.13.2"; mkdir -p "$CM"
cp "$CF/v2.13.2/$BA" "$CM/$BA"
# shellcheck disable=SC2086
run 0 $CPUPUB $KVM HARDCHARGER_PREFIX="$ROOT/cpu-m" HARDCHARGER_VERSION=2.13.2 HARDCHARGER_INSTALL_MIRROR="$ROOT/cpu-mirror" --
expect "Checksum OK (SHA256SUMS)"
expect "Installed Hardcharger 2.13.2 (baseline build)"
[ "$(cat "$ROOT/cpu-m/versions/2.13.2/lib/build.txt")" = baseline ] || fail "the mirror's baseline build wasn't installed"
run 0 -- --prefix "$ROOT/cpu-m" --uninstall
# The mirror's own build of the baseline, with its own SHA256SUMS: refused.
mkdir -p "$ROOT/cpu-evil"; cp -R "$ROOT/cpu-build/2.13.2-baseline/hardcharger-linux-amd64-baseline" "$ROOT/cpu-evil/"
echo "NOT-THE-REAL-BUILD" > "$ROOT/cpu-evil/hardcharger-linux-amd64-baseline/lib/evil.txt"
tar -czf "$CM/$BA" -C "$ROOT/cpu-evil" hardcharger-linux-amd64-baseline
echo "$(sum "$CM/$BA")  $BA" > "$CM/SHA256SUMS"
# shellcheck disable=SC2086
run nonzero $CPUPUB $KVM HARDCHARGER_PREFIX="$ROOT/cpu-m" HARDCHARGER_VERSION=2.13.2 HARDCHARGER_INSTALL_MIRROR="$ROOT/cpu-mirror" --
expect "checksum mismatch for $BA: SHA256SUMS says $(sum "$CF/v2.13.2/$BA")"
[ ! -e "$ROOT/cpu-m/versions/2.13.2" ] || fail "the mirror's baseline build was installed"
# With HARDCHARGER_INSTALL_SHA256 (no GitHub at all): the given sum decides.
cp "$CF/v2.13.2/$BA" "$CM/$BA"
# shellcheck disable=SC2086
run 0 $CPUOFF $KVM HARDCHARGER_PREFIX="$ROOT/cpu-m" HARDCHARGER_VERSION=2.13.2 HARDCHARGER_INSTALL_MIRROR="$ROOT/cpu-mirror" HARDCHARGER_INSTALL_SHA256="$(sum "$CF/v2.13.2/$BA")" --
expect "Checksum OK (HARDCHARGER_INSTALL_SHA256)"
expect "Installed Hardcharger 2.13.2 (baseline build)"
run 0 -- --prefix "$ROOT/cpu-m" --uninstall

step "32. The baseline build through the API with a token (internal releases)"
: > "$ROOT/cpuint.log"
# shellcheck disable=SC2086,SC2154
run 0 PATH="$FL:$PATH" HARDCHARGER_INSTALL_GITHUB_API="$cpuint_URL/api" HARDCHARGER_INSTALL_GITHUB_WEB="$cpuint_URL/web" $WITH_TOKEN $KVM HARDCHARGER_PREFIX="$ROOT/cpu-t" --
expect "Downloading Hardcharger 2.14.0 for linux-amd64 ($BA)"
expect "Checksum OK (SHA256SUMS and GitHub's asset digest)"
[ "$(cat "$ROOT/cpu-t/versions/2.14.0/lib/build.txt")" = baseline ] || fail "the token path didn't install the baseline build"
if grep -q '^/storage/.* auth=yes$' "$ROOT/cpuint.log"; then fail "the token was sent to the storage host"; fi

step "33. Uninstall the baseline build of one version, then everything"
# shellcheck disable=SC2086
run 0 $CPUOFF $KVM HARDCHARGER_CPU_TARGET=baseline -- --prefix "$ROOT/cpu-t" --uninstall 2.14.0
expect "Removed Hardcharger 2.14.0"
[ ! -e "$ROOT/cpu-t/versions/2.14.0" ] || fail "versions/2.14.0 is still there"
run 0 -- --prefix "$ROOT/cpu-t" --uninstall
run 0 -- --prefix "$CP" --uninstall
expect "Removed $CP"
[ ! -e "$CP" ] || fail "$CP is still there"

echo
echo "ALL FIXTURE SCENARIOS PASSED ($PLATFORM, $SH)"
