#!/bin/sh
# Unit tests of install.sh's platform checks, with fake uname/getconf/ldd/sysctl on PATH.
# Nothing is downloaded: every case must be refused (or pass the checks) before any fetch,
# which an empty HARDCHARGER_INSTALL_MIRROR and a dead proxy make sure of.
#
#   .github/scripts/platform-tests.sh [<shell>]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$(cd "$HERE/../.." && pwd)/install.sh"
SH="${1:-sh}"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
FAKE="$ROOT/fakebin"
mkdir -p "$FAKE" "$ROOT/mirror" "$ROOT/home"
failures=0

cat > "$FAKE/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo "$FAKE_S" ;; -m) echo "$FAKE_M" ;; *) echo "$FAKE_S" ;; esac
EOF
cat > "$FAKE/getconf" <<'EOF'
#!/bin/sh
case "$1" in
  LONG_BIT) echo "${FAKE_LONG_BIT:-64}" ;;
  GNU_LIBC_VERSION) [ -n "${FAKE_GLIBC:-}" ] && echo "glibc $FAKE_GLIBC" || exit 1 ;;
  *) exit 1 ;;
esac
EOF
cat > "$FAKE/ldd" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_MUSL:-}" ]; then echo "musl libc (x86_64)" >&2; exit 1; fi
[ -n "${FAKE_GLIBC:-}" ] && echo "ldd (GNU libc) $FAKE_GLIBC" || exit 1
EOF
cat > "$FAKE/sysctl" <<'EOF'
#!/bin/sh
echo "${FAKE_TRANSLATED:-0}"
EOF
chmod +x "$FAKE"/*

# case <name> <expect: refuse|pass> <message> <env...>
check() {
  name="$1"; want="$2"; msg="$3"; shift 3
  set +e
  out="$(env PATH="$FAKE:$PATH" HOME="$ROOT/home" HARDCHARGER_INSTALL_MIRROR="$ROOT/mirror" \
    HARDCHARGER_INSTALL_TOKEN=none https_proxy=http://127.0.0.1:9 "$@" "$SH" -s < "$INSTALLER" 2>&1)"
  code=$?
  set -e
  ok=1
  case "$want" in
    refuse) [ "$code" != 0 ] || ok=0 ;;
    pass)   ;;   # gets past the platform checks; the empty mirror then has nothing to download
  esac
  printf '%s\n' "$out" | grep -F -- "$msg" >/dev/null || ok=0
  if [ "$ok" = 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $code; wanted '$msg')"; printf '%s\n' "$out" | sed 's/^/     | /'
    failures=$((failures + 1))
  fi
}

V=HARDCHARGER_VERSION=0.2.0
check "armv7l (32-bit Raspberry Pi OS)"     refuse "needs a 64-bit operating system, and this one is 32-bit (armv7l). On a Raspberry Pi" FAKE_S=Linux FAKE_M=armv7l $V
check "armv6l (Pi 1 / Zero)"                refuse "64-bit Raspberry Pi OS"                   FAKE_S=Linux FAKE_M=armv6l $V
check "aarch64 kernel, 32-bit userland"     refuse "32-bit (aarch64 kernel, 32-bit userland)" FAKE_S=Linux FAKE_M=aarch64 FAKE_LONG_BIT=32 FAKE_GLIBC=2.41 $V
check "i686"                                refuse "needs a 64-bit operating system, and this one is 32-bit (i686)" FAKE_S=Linux FAKE_M=i686 $V
check "riscv64"                             refuse "no build for the riscv64 processor"       FAKE_S=Linux FAKE_M=riscv64 $V
check "Intel Mac"                           refuse "for Apple silicon (arm64) only"           FAKE_S=Darwin FAKE_M=x86_64 FAKE_TRANSLATED=0 $V
check "Rosetta shell on Apple silicon"      pass   "for macos-arm64"                          FAKE_S=Darwin FAKE_M=x86_64 FAKE_TRANSLATED=1 $V
check "FreeBSD"                             refuse "has no build for FreeBSD"                 FAKE_S=FreeBSD FAKE_M=amd64 $V
check "Git Bash on Windows"                 refuse "irm https://install.hardcharger.gizmodata.com/install.ps1 | iex" FAKE_S=MINGW64_NT-10.0 FAKE_M=x86_64 $V
check "Alpine (musl)"                       refuse "uses musl libc (Alpine Linux or similar)" FAKE_S=Linux FAKE_M=x86_64 FAKE_MUSL=1 $V
check "Debian 12 / Pi OS Bookworm, 0.2.0"   refuse "Hardcharger 0.2.0 for Linux needs glibc >= 2.38, and this system has glibc 2.36" FAKE_S=Linux FAKE_M=aarch64 FAKE_GLIBC=2.36 $V
check "Oracle Linux 8, 0.2.0"               refuse "needs glibc >= 2.38, and this system has glibc 2.28. Builds for glibc 2.28 and newer" FAKE_S=Linux FAKE_M=x86_64 FAKE_GLIBC=2.28 $V
check "glibc 2.17, any version"             refuse "Hardcharger supports glibc 2.28 and newer" FAKE_S=Linux FAKE_M=x86_64 FAKE_GLIBC=2.17 HARDCHARGER_VERSION=0.3.0
check "Debian 12, a manylinux_2_28 release" pass   "Downloading Hardcharger 0.3.0 for linux-arm64" FAKE_S=Linux FAKE_M=aarch64 FAKE_GLIBC=2.36 HARDCHARGER_VERSION=0.3.0
check "Ubuntu 24.04 arm64, 0.2.0"           pass   "Downloading Hardcharger 0.2.0 for linux-arm64" FAKE_S=Linux FAKE_M=aarch64 FAKE_GLIBC=2.39 $V
check "a bad version string"                refuse "must be latest, X.Y.Z or vX.Y.Z (got '1.2')" FAKE_S=Linux FAKE_M=x86_64 FAKE_GLIBC=2.39 HARDCHARGER_VERSION=1.2

if [ "$failures" != 0 ]; then echo "$failures platform test(s) failed"; exit 1; fi
echo "all platform tests passed ($SH)"
