<p align="center"><img src="Design/icon.png" width="128" alt="XTermX icon"></p>
<h1 align="center">XTermX</h1>
<p align="center"><b>Your agents, side by side. Your terminals, wherever you are.</b></p>
<p align="center">Native Mac terminal · Linux node · Encrypted remote sessions</p>
<p align="center"><b>English</b> · <a href="README.pt-BR.md">Português</a> · <a href="README.es.md">Español</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="https://cassel.us">C. Cassel</a></p>

XTermX is a terminal workspace for people working with coding agents. Run Claude Code, Codex, Gemini CLI and other terminal tools side by side, name each pane, see who needs your attention, and keep your work in view.

**The Mac app, Linux node and shared libraries in this repository are open source under MIT. The iOS app and its Apple Watch companion are developed separately and remain proprietary. Their App Store launch is planned; there is no public App Store download link yet.**

If you want to use the official companion app, watch this page for the App Store link when it launches. If you want to build the desktop app or run a Linux node today, see [Build and run](#build-and-run).

## A look at XTermX

These are **illustrative documentation previews**, rendered offscreen from fictional fixtures using XTermX's theme palette. They explain the workflow; they are not captures of a personal desktop or pixel-for-pixel screenshots of a released build. No real sessions, accounts, folders or usage data are shown. [How the previews are made](Design/previews/README.md).

![Illustrative workspace with four named terminal panes and fictional agent tasks](Design/previews/workspace-demo.png)

Name a pane **API**, **Interface**, **Tests** or **Review**. Keep a running agent next to its tests, move between panes with the keyboard, and spot the one waiting for you.

![Illustrative Home overview showing sample activity counts and a token history chart](Design/previews/home-demo.png)

Home brings terminal states, provider plan limits, local usage charts and recent activity into sections. Provider limits and local token estimates have different sources; the app keeps that distinction visible.

## What you can do

### Work across terminal panes

- Organize terminals into workspace tabs and split panes horizontally or vertically.
- Rename panes with your own labels; switch quickly by name or recent focus.
- Resize dividers, equalize the layout, maximize a pane, or swap it with a neighbor.
- Launch installed coding CLIs from a catalog of 28 agents, discovered on your `PATH`.
- Use the command palette, keyboard navigation, broadcast typing and Control Rooms.
- Pick from ten themes, adjust contrast, dim inactive panes and customize shortcuts.
- Search terminal contents, use Mac dictation, and save workspace layouts for later.

### Follow agent work

Claude Code and Codex integrations can show session status, recent tool activity, tasks, tokens and requests that need a response. A chat view groups supported agent transcripts while the terminal stays available underneath.

Home and Usage show local history and charts. Provider-reported plan percentages appear when the corresponding agent integration supplies them. Estimates derived from token counts are **not** subscription billing totals.

Optional notifications can go to macOS, Telegram or Slack. External notifications are configured by you; normal terminal use does not require them.

### Reach other machines

The Mac can host terminals and connect to other XTermX nodes. The Linux command-line node runs PTYs, the remote server and the agent-tool server without a desktop app. Mac ↔ Linux, Mac ↔ Mac and Linux ↔ Linux connections use the same protocol.

Pair through a QR code or pairing link. Connect on your LAN, or over a network you provide, such as a VPN. XTermX does not supply a hosted relay or a VPN service.

The Mac also includes an SSH client, host-key trust checks, an SFTP browser and a text editor for remote files.

### Continue from the companion apps

The separately distributed iOS app can follow the same host sessions, send text and quick replies, respond to supported agent requests, and attach files when the host allows it. Wider layouts can show two terminals side by side. The Watch companion offers a compact session view and quick actions.

**iOS and Watch application sources and signing material are not included in this repository.** Opening the shared protocol and libraries does not make those applications open source. App Store availability will be announced separately.

## A typical workflow

1. Open XTermX on the Mac and start a workspace for your project.
2. Launch your preferred installed agents and give their panes useful names.
3. Keep terminals visible or open Home to see activity and requests together.
4. Optionally connect another XTermX machine through **Machines → Add machine**.
5. When the companion app becomes available, pair it from **Remote access** to follow your host sessions.

Agent accounts, subscriptions and CLI installations are yours. XTermX does not include provider subscriptions or bypass provider limits.

## Build and run

[Download the Mac development build](https://github.com/cassel/xtermx-core/releases/tag/dev-2026.10.17-1857) — universal Apple Silicon + Intel, macOS 15+. It is ad-hoc signed and **not notarized by Apple**; macOS may block first launch. Source-build instructions follow. The proprietary iOS/Watch apps are not included.

### Mac

Requirements: **macOS 15 or later**, **Xcode 26 or later**, and **XcodeGen**. Dependencies are resolved by Swift Package Manager.

```bash
git clone https://github.com/cassel/xtermx-core.git
cd xtermx-core
xcodegen generate
open XTermX.xcodeproj
```

Select **XTermX-macOS**, choose your own Apple development team in Signing & Capabilities, and run. No developer certificate, provisioning profile or private key is shipped here.

For a local unsigned build check:

```bash
xcodebuild -project XTermX.xcodeproj -scheme XTermX-macOS \
  -destination 'platform=macOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

See [development and distribution](docs/BUILDING.md) for CLI builds, tests and the notarized Mac release workflow.

### Linux

Use Swift 6.2+ or Docker, a Linux user account, and the dependencies described in the installation script. The script installs a binary and starts a systemd user service where available; review it before running it on your own machine.

```bash
git clone https://github.com/cassel/xtermx-core.git
cd xtermx-core
XTERMX_ADDRESSES="node.example.com" ./Server/install.sh
```

The terminal processes run as that Linux user and use that user's installed tools and credentials. No Linux binaries are attached to this initial source release. Linux runtime compatibility needs validation on your target distribution.

For a manual CLI build:

```bash
cd Packages/XTermXKit
swift build -c release --product xtermx
.build/release/xtermx --help
```

## Pairing and permissions

On the Mac, open the globe menu or press **⌘⇧G**, enable remote access, then pair using the displayed link or QR code. Treat that code as a credential: share it only with devices you trust and keep it out of screenshots.

- Paired device history stays listed after disconnection; an offline entry does not mean the device has an active connection.
- Panes can be shared as **View & control**, **View only** or **Private**.
- Remote terminal creation, file receipt and Control Room permissions have host controls.
- Receiving files is opt-in. The host sets the attachment size limit in Settings → Remote access (500 MB per file by default), with an optional total storage quota. Changes reach paired devices immediately. Older Rooms & files uploads remain limited to 4 MB.
- **Forget all devices** rotates the pairing secret and requires devices to pair again.

Terminal frames use authenticated ChaCha20-Poly1305 encryption, fresh connection nonces and replay counters. Network ports are **47820** for WebSocket and **47821** for the Watch-compatible HTTP transport; Bonjour advertises `_xtermx._tcp`. Reachability depends on your LAN/VPN/firewall configuration. Do not assume `.local` names work outside your LAN.

See [SECURITY.md](SECURITY.md) before reporting a security problem. These mechanisms are described from the implementation; no independent security audit is claimed.

## Tools for coding agents

The local MCP server allows supported agents to request scoped work. Enabling agent-created panes is optional. Requests to spawn an agent pane require human approval; agents cannot close panes through `pane_close`.

| Tools | Purpose |
|---|---|
| `pane_spawn` | Request another agent pane, with approval |
| `pane_list`, `pane_read`, `pane_send`, `pane_shell` | Inspect or drive panes within the caller's scope |
| `pane_wait`, `pane_report`, `pane_reports` | Wait for work and collect results |
| `room_members`, `room_read`, `room_send`, `room_reply` | Coordinate agents in an assigned Control Room |
| `pane_agents`, `machine_check`, `budget_check` | Discover agents, inspect host load and query budget state |

The MCP endpoint listens on loopback, uses per-pane tokens and rejects browser-origin requests. Unknown budget state is not treated as permission to proceed.

## Keyboard shortcuts

Defaults below; the Mac app's **Settings → Shortcuts** shows the active bindings.

| Shortcut | Action |
|---|---|
| ⌘T / ⌘N | New workspace / terminal |
| ⌘D / ⌘⇧D | Split right / down |
| ⌘] / ⌘[ | Next / previous pane |
| ⌃ + arrow | Focus a neighboring pane |
| ⌃⇧ + arrow | Move a pane to its neighbor's position |
| ⌃N | Split the focused pane along its longer side |
| ⌃Tab | Quick Terminal Switcher |
| ⌘⇧M / ⌘P | Maximize / equalize |
| ⌘K | Command palette |
| ⌘B / ⌘⇧B | Toggle sidebar / right panel |
| ⌘⌥B | Broadcast typing |
| ⌘⇧G | Remote access and devices |
| ⌘W | Close the focused pane |

## Selecting text and opening links

On Mac, drag across terminal text and press **⌘C** to copy, including in mouse-aware programs such as tmux. Hold **Control** while hovering to underline a detected web link, then click to open it in your browser; **⌘click** also works. Hold **Option** while clicking or dragging to send mouse input to a terminal program. Enable automatic copying in **Settings → Terminal → Copy when selecting text**.

## Project structure

```text
Apps/macOS/                 Native Mac application and settings
Packages/XTermXKit/
  Sources/XTermXKit/        Models, protocol, cryptography, themes, client
  Sources/XTermXNIO/        SwiftNIO network transport
  Sources/XTermXHost/       PTYs, host server, agent integration, MCP
  Sources/XTermXTerminalUI/ Terminal rendering and SSH libraries
  Sources/xtermx/           Mac/Linux CLI
  Sources/DocumentationPreview/  Fixture-only preview renderer
  Tests/                   Shared logic and integration tests
Server/                    Linux installer, service and Dockerfile
Release/mac-release.sh     Mac signing/notarization workflow
Design/previews/           Synthetic documentation images
```

Shared libraries contain conditional support for Apple platforms. The public Xcode project builds the **Mac app only**; the iOS and Watch applications are maintained outside this repository.

## Development status and contributions

XTermX is in active development. The initial public snapshot comes from a development branch with 165 passing Swift tests and successful Mac, iOS and Watch builds in its private integration workspace. That does not certify every physical-device or Linux configuration. For validation of this public source tree, see [BUILDING.md](docs/BUILDING.md).

Bug reports, documentation improvements and focused contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Never include real terminal contents, pairing links, keys or account data in public issues or screenshots.

## License and credits

Copyright © 2026 **C. Cassel** — [cassel.us](https://cassel.us).

This public repository is licensed under [MIT](LICENSE). That license covers the code and materials published here; it does not grant rights to the separately maintained proprietary iOS/Watch application sources or to third-party dependencies beyond their own licenses.

Terminal emulation: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). SSH: [Citadel](https://github.com/orlandos-nl/Citadel). Networking: [SwiftNIO](https://github.com/apple/swift-nio). Project generation: [XcodeGen](https://github.com/yonaskolb/XcodeGen).
