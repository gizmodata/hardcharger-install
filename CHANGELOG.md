# Changelog

All notable changes to the Hardcharger installer are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). `main` is deployed to
<https://install.hardcharger.gizmodata.com> on every push, after the tests pass.

## [Unreleased]

## [0.1.0] - 2026-10-17

### Added

- `install.sh` (POSIX sh; tested with dash, bash and macOS sh): installs `hardcharger-server` and
  the `hardcharger` client from gizmodata/hardcharger's releases into
  `~/.hardcharger/versions/<version>/`, with `~/.hardcharger/bin` linking to the current version.
  `HARDCHARGER_VERSION`/`--version` (latest, X.Y.Z, vX.Y.Z) installs or switches; a version
  already installed switches without a download. `--list`, `--uninstall [<v>]`, `--prefix`,
  `--modify-path` (otherwise the PATH line is only printed).
- Checks before anything changes: the platform (musl, Intel Mac and 32-bit systems are refused
  with what to do instead, Raspberry Pi included), the system's glibc against the release's need
  (before downloading), the download against `SHA256SUMS` and GitHub's asset digest, and every
  executable's `--version`. A failure leaves the current version current.
- Downloads with `HARDCHARGER_INSTALL_TOKEN`, `GH_TOKEN` or `gh auth token` through the GitHub
  API while the releases are internal (the token goes to curl in a file, never on a command
  line), and anonymously once they are public. `HARDCHARGER_INSTALL_MIRROR` installs from a
  directory or URL laid out like the releases.
- Releases before 0.2.0, whose server was named `hardcharger`, are installed as
  `hardcharger-server`.
- `install.ps1` for Windows (PowerShell 5.1 and 7, x64 and ARM64), with the same options and a
  junction for instant switching. Until a release has Windows zips, it says Windows builds are
  coming and exits non-zero.
- `test-install.yml`: both installers end to end against the real releases on Linux amd64/arm64,
  macOS arm64, a Debian 13 container and Windows amd64/arm64, plus the glibc message on Debian 12
  arm64 (Raspberry Pi OS Bookworm) and Oracle Linux 8, which are known to fail until the
  glibc 2.28 builds ship. Triggered by every push and pull request, by hardcharger's releases
  (`repository_dispatch: hardcharger-released`) and weekly.
- `deploy.yml`: after the tests pass on `main`, uploads both scripts to S3 as `text/plain`,
  invalidates CloudFront and checks the live http and https URLs serve them, by GitHub OIDC.
