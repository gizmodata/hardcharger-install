# Changelog

All notable changes to the Hardcharger installer are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). `main` is deployed to
<https://install.hardcharger.gizmodata.com> on every push, after the tests pass.

## [Unreleased]

### Fixed

- The "Get started" client line that `install.sh` and `install.ps1` print now says `--tls=false`.
  The server on the line above runs without TLS by default and the client uses TLS unless told
  otherwise, so the line as printed failed with "The server at …:31337 speaks plain HTTP, not
  TLS". Every release with a client (0.3.0 on) accepts `--tls=false` (`--no-tls` is newer than
  2.0.0-rc.1). The fixture tests now check the printed lines on Linux, macOS and Windows.
- Messages that said builds were coming: for a release without a Windows zip, `install.ps1` says
  Windows builds start with 0.3.0; for a pinned release that needs glibc 2.38 on a system with
  glibc 2.28 or newer, `install.sh` says 0.3.0 and later need only glibc 2.28.
- The real-release smoke test (`e2e.sh`, which runs from public launch on) connects the client
  with `--tls=false`, and accepts the Warp SQL error (`execution_error`) that 0.3.0 and
  2.0.0-rc.1 return for a failing statement. Both checks failed against those releases.

### Documentation

- Trademark notices: Hardcharger™ and GizmoData™ on the README titles and first mentions, package
  metadata and the footer, which says both are trademarks of GizmoData LLC.
- README: Windows builds (zip and MSI) ship from 0.3.0 on and are Authenticode-signed from
  2.0.0-rc.1 on; Linux builds need glibc 2.28 from 0.3.0 on; a "Get started" section with the
  printed lines; the Windows pin example uses 0.3.0, the first release with a Windows zip.

### Changed

- The deploy is gated on tests that need no credentials. `fixture-scenarios.sh` and
  `windows-tests.ps1` run every scenario against fixture releases served by `fake_github.py`, a
  local stand-in for GitHub's releases API, redirects and downloads, both "internal" (token
  required) and "public". Together with lint, the platform unit tests and the glibc message, these
  gate the deploy on Linux, macOS and Windows.
- The real-release check (`real release, runs at public launch`) runs only once gizmodata/hardcharger's
  releases are public, detected with an anonymous request to github.com. Until then it posts a
  notice and passes, and it switches on by itself at launch. The `HARDCHARGER_RELEASES_TOKEN`
  secret and its job are gone.
- `install.sh` and `install.ps1` take `HARDCHARGER_INSTALL_GITHUB_API` (and, for `install.sh`,
  `HARDCHARGER_INSTALL_GITHUB_WEB`) for tests, and allow plain http only when one is set.
  `--uninstall` also removes the empty prefix that a failed first install leaves.

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
