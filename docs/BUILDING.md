# Building XTermX Core

The public source includes the Mac application, the Mac/Linux CLI, host services and shared libraries. It deliberately excludes the proprietary iOS and Watch applications, their release scripts and all signing material.

## Mac app

Use macOS 15+, Xcode 26+ and XcodeGen. Select your installed Xcode with your normal development environment, then:

```bash
xcodegen generate
open XTermX.xcodeproj
```

Build scheme `XTermX-macOS`. Select your own development team and set `XTX_BUNDLE_PREFIX` to your own reverse-DNS prefix in `project.yml` to run your own signed local app. `project.yml` leaves the team blank; no account is assumed.

Unsigned compile check:

```bash
xcodebuild -project XTermX.xcodeproj -scheme XTermX-macOS \
  -destination 'platform=macOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

The Mac terminal runs without App Sandbox so its child shells can execute your tools. Microphone, camera, speech and file access are subject to macOS permissions. Running third-party commands inside the terminal gives those commands the access of your user account.

## CLI and tests

```bash
cd Packages/XTermXKit
swift build --product xtermx
.build/debug/xtermx --help
swift test
```

Tests include real local PTYs and loopback host/client traffic. Custom shell startup files can interfere with PTY tests. To isolate zsh startup configuration for the test process:

```bash
ZDOTDIR="$(mktemp -d)" XTMUX_SKIP=1 swift test
```

This sets environment variables only for that invocation; it does not change your shell configuration. Tests with names referring to remote viewing test protocol/library behavior, not the private companion app UI. Some suites are conditional on the host platform.

## Linux node

`Server/install.sh` builds with Swift 6.2+ when available or uses the official Swift Docker image. It installs under the current user's home and enables a systemd user service if supported. It may offer to enable lingering so the node survives logout. Review the script and service before running them.

`Server/Dockerfile` provides a container build. Terminals then run inside the container; agents must be installed there. No Linux runtime validation is implied by a successful Mac test run.

## Mac distribution

`Release/mac-release.sh` archives, signs with Developer ID, notarizes and packages a DMG. It requires your own paid team and App Store Connect notarization credentials, supplied through environment variables. It is an explicit distribution command, not a normal build step.

```bash
TEAM_ID=YOUR_TEAM \
ASC_KEY_ID=YOUR_KEY_ID \
ASC_ISSUER_ID=YOUR_ISSUER_ID \
ASC_KEY_PATH=/path/to/your/AuthKey.p8 \
./Release/mac-release.sh
```

Do not commit those values, certificates, provisioning profiles, archives or disk images. Notarization requires network access to Apple. The script does not publish a GitHub release or submit an App Store product listing.

## Public snapshot validation

Validated on 2026-10-17 from the exported public source tree:

- Mac Debug build with `CODE_SIGNING_ALLOWED=NO`: passed.
- Mac/Linux CLI product `xtermx` built on macOS: passed.
- Shared Swift suite: 165 tests in 49 suites passed after building the CLI prerequisite.
- Documentation renderer: both fixture-only PNGs generated and visually inspected.
- Export manifest hashes and relative documentation links: checked.

The initial validation reused local dependency/build caches; the hooks integration test was given the expected `.build/debug/xtermx` path to the freshly built public CLI. No credentials or private application sources were needed. Physical-device UI testing and Linux runtime testing remain separate from these checks.

## Updated development download — build 202610171857

The updated public source passed 190 Swift tests in 53 suites on macOS. The download is a universal Release build for Apple Silicon and Intel, requiring macOS 15+. It includes current host transfer settings and terminal replay fixes. The release contains build provenance, third-party notices and SHA-256 checksums.

It is ad-hoc signed and not notarized; macOS may block first launch. Intel runtime and Linux runtime have not been validated for this download. The proprietary iOS and Watch applications are excluded.
