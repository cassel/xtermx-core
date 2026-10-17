# Documentation previews

These PNGs are illustrative documentation artwork, not screen captures of a user's desktop or exact screenshots of a released build. They are rendered offscreen from SwiftUI fixture views using the public XTermX theme palette.

The renderer contains literal sample names, terminal text, counts and chart values. It does not construct the application model, open a PTY, start a server, read agent transcripts, inspect user accounts or capture any screen.

To regenerate on macOS:

```bash
swift run --package-path Packages/XTermXKit xtermx-doc-previews "$PWD/Design/previews"
```

The PNGs are 2560 × 1600. Their visible labels identify them as documentation previews with fictional data. Production layouts may differ.
