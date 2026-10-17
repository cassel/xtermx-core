#if os(macOS)
import AppKit
import SwiftUI
import Charts
import XTermXKit

// All content is a literal fixture. No AppModel, PTY, disk scan, network, or screen capture.
private let theme = AppTheme.default
private let canvas = theme.chrome.canvas.color
private let card = theme.chrome.card.color
private let accent = theme.chrome.primary.color
private let muted = theme.chrome.mutedForeground.color

struct DemoPane: View {
    let title: String
    let state: PaneState
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(state.label).foregroundStyle(state.color)
                Image(systemName: "rectangle.split.2x1")
            }.font(.system(size: 13)).padding(12).background(card)
            VStack(alignment: .leading, spacing: 13) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line).foregroundStyle(index == 0 ? accent : theme.terminal.foreground.color)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 10)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(theme.terminal.background.color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(state == .blocked ? state.color : theme.chrome.border.color, lineWidth: 1.5))
    }
}

struct PreviewFrame<Content: View>: View {
    let heading: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("XTermX").font(.system(size: 27, weight: .bold))
                Text(heading).font(.system(size: 18)).foregroundStyle(muted)
                Spacer()
                Text("DOCUMENTATION PREVIEW").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(muted)
            }
            content
            HStack {
                Text("Fictional sessions and sample data • No personal screen captures")
                Spacer()
                Text("C. Cassel · cassel.us")
            }.font(.system(size: 11)).foregroundStyle(muted)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas).foregroundStyle(theme.chrome.foreground.color)
            .environment(\.appTheme, theme).environment(\.colorScheme, .dark)
    }
}

struct WorkspacePreview: View {
    var body: some View {
        PreviewFrame(heading: "A workspace for your agents") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Home", systemImage: "house")
                    Text("WORKSPACES").font(.caption).foregroundStyle(muted)
                    Label("Demo project", systemImage: "rectangle.split.2x2")
                        .foregroundStyle(accent)
                    Text("TERMINALS").font(.caption).foregroundStyle(muted)
                    Label("API", systemImage: "terminal")
                    Label("Interface", systemImage: "terminal")
                    Label("Tests", systemImage: "terminal")
                    Label("Review", systemImage: "terminal")
                    Spacer()
                    Label("Settings", systemImage: "gearshape")
                }.font(.system(size: 14)).padding(18).frame(width: 170).background(card, in: RoundedRectangle(cornerRadius: 10))
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        DemoPane(title: "API · Claude Code", state: .working, lines: ["› Add pagination to the sample API", "Reading routes.swift…", "Editing the response model", "Running integration tests…"])
                        DemoPane(title: "Interface · Codex", state: .blocked, lines: ["› Build a settings screen", "Theme picker is ready.", "Review requested:", "Apply the preview changes? [y/n]"])
                    }
                    HStack(spacing: 12) {
                        DemoPane(title: "Tests", state: .idle, lines: ["$ swift test", "✓ Models", "✓ Pagination", "All sample checks passed.", "$ ▋"])
                        DemoPane(title: "Review", state: .idle, lines: ["$ git diff --stat", "Routes.swift      | +24 -6", "Settings.swift    | +18 -3", "Ready for your review.", "$ ▋"])
                    }
                }
            }
        }
    }
}

struct DashboardPreview: View {
    let data = [12.0, 24, 18, 42, 31, 58, 46, 64, 39, 72, 54, 68]
    var body: some View {
        PreviewFrame(heading: "Your terminals, at a glance") {
            VStack(alignment: .leading, spacing: 20) {
                Text("Right now").font(.title2.bold())
                HStack(spacing: 12) {
                    metric("In motion", "2", "waveform.path", accent)
                    metric("Needs you", "1", "hand.raised.fill", StateColors.blocked.color)
                    metric("At a prompt", "3", "pause.circle", StateColors.done.color)
                    metric("Ended", "0", "checkmark.circle", muted)
                }
                Text("Plan usage").font(.title2.bold())
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sample account · weekly").font(.headline)
                        Text("38% used").foregroundStyle(muted)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(accent.opacity(0.16))
                                Capsule().fill(accent).frame(width: geo.size.width * 0.38)
                            }
                        }.frame(height: 7)
                        Text("Illustrative provider limit").font(.caption).foregroundStyle(muted)
                    }.padding(18).frame(width: 260).frame(maxHeight: .infinity).background(card, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading) {
                        Text("Local token history · sample data").font(.headline)
                        Chart(Array(data.enumerated()), id: \.offset) { item in
                            BarMark(x: .value("Hour", item.offset + 1), y: .value("Tokens (thousands)", item.element))
                                .foregroundStyle(accent.gradient).cornerRadius(3)
                        }.chartXAxisLabel("Hour").chartYAxisLabel("Thousands of tokens")
                    }.padding(18).background(card, in: RoundedRectangle(cornerRadius: 12))
                }.frame(height: 245)
                Text("Recent activity").font(.title2.bold())
                HStack(spacing: 12) {
                    activity("API", "Running integration tests", "bolt.horizontal.circle")
                    activity("Interface", "Waiting for your review", "hand.raised")
                    activity("Tests", "Sample checks passed", "checkmark.circle")
                }
            }
        }
    }
    func metric(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).foregroundStyle(tint)
            Text(value).font(.system(size: 34, weight: .semibold))
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(card, in: RoundedRectangle(cornerRadius: 12))
    }
    func activity(_ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.callout).foregroundStyle(muted)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(card, in: RoundedRectangle(cornerRadius: 12))
    }
}

@main struct DocumentationPreview {
    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "../../Design/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try render(WorkspacePreview(), name: "workspace-demo.png", folder: folder)
        try render(DashboardPreview(), name: "home-demo.png", folder: folder)
    }
    @MainActor static func render<V: View>(_ view: V, name: String, folder: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: 1280, height: 800))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: folder.appendingPathComponent(name))
        print("Rendered \(name) using fictional fixtures only")
    }
}
#else
@main struct DocumentationPreview {
    static func main() { print("Documentation rendering requires macOS.") }
}
#endif
