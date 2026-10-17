# Contributing

XTermX Core welcomes focused bug fixes, documentation improvements and reproducible reports for the Mac app, Linux node and shared libraries.

1. Describe the problem and expected behavior. Use sample projects and fictional terminal text.
2. Keep changes scoped. Add tests for new non-UI logic or regressions where they provide useful evidence.
3. Run relevant package tests and build the Mac app when changing its code. State your OS/toolchain and what you actually validated.
4. Open a pull request with the behavior change and validation results. Do not include generated build output.

The iOS and Watch applications are maintained separately and are not included in this repository. Please do not add copies of their application sources or signing material.

Never attach real pairing links, QR secrets, access tokens, SSH keys, account data or unrelated terminal history. Before publishing an image, reproduce the issue with fictional data. For security concerns, follow [SECURITY.md](SECURITY.md).

Contributions to this public repository are made under its [MIT license](LICENSE). Third-party code keeps its own license and attribution requirements.
