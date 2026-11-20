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
# /proc/cpuinfo of a CPU with every flag the optimized Linux x86-64 build needs (a Haswell). Only
# the first flags line counts.
printf 'processor\t: 0\nflags\t\t: fpu sse sse2 cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave\nprocessor\t: 1\nflags\t\t: fpu\n' > "$ROOT/v3"

# case <name> <expect: refuse|pass> <message> <env...>
check() {
  name="$1"; want="$2"; msg="$3"; shift 3
  set +e
  # A CPU with every feature the optimized x86-64 build needs, unless a case says otherwise: the
  # host's own /proc/cpuinfo must not decide.
  out="$(env PATH="$FAKE:$PATH" HOME="$ROOT/home" HARDCHARGER_INSTALL_MIRROR="$ROOT/mirror" \
    HARDCHARGER_INSTALL_TOKEN=none https_proxy=http://127.0.0.1:9 HARDCHARGER_CPU_TARGET= \
    HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/v3" "$@" "$SH" -s < "$INSTALLER" 2>&1)"
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
check "Oracle Linux 8, 0.2.0"               refuse "needs glibc >= 2.38, and this system has glibc 2.28. Hardcharger 0.3.0 and later need only glibc 2.28" FAKE_S=Linux FAKE_M=x86_64 FAKE_GLIBC=2.28 $V
check "glibc 2.17, any version"             refuse "Hardcharger supports glibc 2.28 and newer" FAKE_S=Linux FAKE_M=x86_64 FAKE_GLIBC=2.17 HARDCHARGER_VERSION=0.3.0
check "Debian 12, a manylinux_2_28 release" pass   "Downloading Hardcharger 0.3.0 for linux-arm64" FAKE_S=Linux FAKE_M=aarch64 FAKE_GLIBC=2.36 HARDCHARGER_VERSION=0.3.0
check "Ubuntu 24.04 arm64, 0.2.0"           pass   "Downloading Hardcharger 0.2.0 for linux-arm64" FAKE_S=Linux FAKE_M=aarch64 FAKE_GLIBC=2.39 $V
check "a bad version string"                refuse "must be latest, X.Y.Z or vX.Y.Z (got '1.2')" FAKE_S=Linux FAKE_M=x86_64 FAKE_GLIBC=2.39 HARDCHARGER_VERSION=1.2

# The CPU target (Linux x86-64: optimized or baseline build), with /proc/cpuinfo from a file.
# kvm64: QEMU's "Common KVM processor" (x86-64-v1), as a CentOS 8 guest shows it.
printf 'model name\t: Common KVM processor\nflags\t\t: fpu de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ht syscall nx lm constant_tsc nopl xtopology cpuid pni cx16 hypervisor pti\n' > "$ROOT/kvm64"
# Ivy Bridge: AVX but no AVX2.
printf 'flags\t\t: fpu sse sse2 ssse3 cx16 sse4_1 sse4_2 popcnt pni lahf_lm xsave avx f16c\n' > "$ROOT/ivybridge"
printf 'processor\t: 0\nFeatures\t: fp asimd\n' > "$ROOT/noflags"
L="FAKE_S=Linux FAKE_M=x86_64 FAKE_GLIBC=2.39"
OPT="Downloading Hardcharger 2.13.2 for linux-amd64 (hardcharger-linux-amd64.tar.gz)"
BASE="Downloading Hardcharger 2.13.2 for linux-amd64 (hardcharger-linux-amd64-baseline.tar.gz)"
V2132=HARDCHARGER_VERSION=2.13.2
# shellcheck disable=SC2086 # $L is a NAME=value list
{
check "auto, a v3 CPU: optimized"               pass   "$OPT"  $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/v3"
check "auto, kvm64: baseline"                   pass   "$BASE" $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "auto, kvm64: says what's missing"        pass   "this CPU lacks lahf_lm popcnt sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave, which Hardcharger's optimized Linux x86-64 build needs (x86-64-v3: AVX2), so this installer uses the baseline build (hardcharger-linux-amd64-baseline.tar.gz). It runs on any x86-64 CPU, but slower." $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "auto, kvm64: the VM hint"                pass   'its CPU model setting (QEMU'"'"'s or Proxmox'"'"'s "kvm64" or "qemu64", for example) can hide the host'"'"'s CPU features: set it to "host"' $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "auto, kvm64: how to choose"              pass   "To choose the build yourself: --cpu-target optimized or --cpu-target baseline (HARDCHARGER_CPU_TARGET=optimized or =baseline)." $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "auto, Ivy Bridge (AVX, no AVX2)"         pass   "this CPU lacks avx2 bmi1 bmi2 fma abm movbe, which" $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/ivybridge"
check "auto, no flags line: optimized"          pass   "$OPT"  $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/noflags"
check "auto, no cpuinfo at all: optimized"      pass   "$OPT"  $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/does-not-exist"
check "optimized forced on kvm64"               pass   "$OPT"  $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64" HARDCHARGER_CPU_TARGET=optimized
check "baseline forced on a v3 CPU"             pass   "$BASE" $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/v3" HARDCHARGER_CPU_TARGET=baseline
check "BASELINE in capitals"                    pass   "$BASE" $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/v3" HARDCHARGER_CPU_TARGET=BASELINE
check "empty HARDCHARGER_CPU_TARGET is auto"    pass   "$BASE" $L $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64" HARDCHARGER_CPU_TARGET=
check "a release candidate of a later version"  pass   "Downloading Hardcharger 2.14.0-rc.1 for linux-amd64 (hardcharger-linux-amd64-baseline.tar.gz)" $L HARDCHARGER_VERSION=2.14.0-rc.1 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "a wrong CPU target"                      refuse "HARDCHARGER_CPU_TARGET/--cpu-target must be one of auto, optimized, baseline, not 'fastest'" $L $V2132 HARDCHARGER_CPU_TARGET=fastest
check "baseline on macOS"                       refuse "the baseline build is for Linux on x86-64 only, and this is macos-arm64, which has one build for every CPU" FAKE_S=Darwin FAKE_M=arm64 $V2132 HARDCHARGER_CPU_TARGET=baseline
check "baseline on Linux arm64"                 refuse "the baseline build is for Linux on x86-64 only, and this is linux-arm64" FAKE_S=Linux FAKE_M=aarch64 FAKE_GLIBC=2.39 $V2132 HARDCHARGER_CPU_TARGET=baseline
check "auto on Linux arm64 ignores cpuinfo"     pass   "Downloading Hardcharger 2.13.2 for linux-arm64 (hardcharger-linux-arm64.tar.gz)" FAKE_S=Linux FAKE_M=aarch64 FAKE_GLIBC=2.39 $V2132 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "baseline forced, 2.13.1: not released"   refuse "Hardcharger 2.13.1 has no baseline build: the baseline build is released from 2.13.2 on. Install 2.13.2 or later" $L HARDCHARGER_VERSION=2.13.1 HARDCHARGER_CPU_TARGET=baseline
check "auto on kvm64, 2.13.1: says so"         pass   "this CPU lacks lahf_lm popcnt sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave, which Hardcharger's optimized Linux x86-64 build needs (x86-64-v3: AVX2), and Hardcharger 2.13.1 has no baseline build: the baseline build is released from 2.13.2 on. Trying 2.13.1's optimized build: it is installed only if it runs here" $L HARDCHARGER_VERSION=2.13.1 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "auto on kvm64, 2.13.1: the way on"        pass   "For the baseline build, which runs on any x86-64 CPU, install the latest release (the default) or pin 2.13.2 or newer." $L HARDCHARGER_VERSION=2.13.1 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "auto on kvm64, 2.13.1: tries optimized"   pass   "Downloading Hardcharger 2.13.1 for linux-amd64 (hardcharger-linux-amd64.tar.gz)" $L HARDCHARGER_VERSION=2.13.1 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/kvm64"
check "auto on a v3 CPU, 2.13.1: optimized"     pass   "Downloading Hardcharger 2.13.1 for linux-amd64 (hardcharger-linux-amd64.tar.gz)" $L HARDCHARGER_VERSION=2.13.1 HARDCHARGER_INSTALL_TEST_CPUINFO="$ROOT/v3"
}

if [ "$failures" != 0 ]; then echo "$failures platform test(s) failed"; exit 1; fi
echo "all platform tests passed ($SH)"
