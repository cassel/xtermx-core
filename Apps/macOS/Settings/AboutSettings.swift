import AppKit
import SwiftUI
import XTermXKit

/// Settings › About: which build of XTermX this is.
struct AboutSettings: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsPage(section: .about) {
            SettingsCard("Version", "The copy of XTermX on this Mac; include it when you report a problem.") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("XTermX \(Self.short)").font(.system(size: 13, weight: .medium))
                        Text("Build \(Self.build)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                    }
                    .textSelection(.enabled)
                    Spacer()
                    Button("Copy version") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("XTermX \(Self.short) (\(Self.build))", forType: .string)
                    }
                }
            }
            SettingsCard("Created by", "C. Cassel") {
                Link("cassel.us", destination: URL(string: "https://cassel.us")!)
                    .font(.system(size: 14, weight: .semibold))
            }
            SettingsCard("Project and releases", "Read release notes or visit the source. Downloads and installation are your choice.") {
                HStack {
                    Link("Release notes and updates", destination: FeedbackDraft.releasesURL)
                    Spacer()
                    Link("Project on GitHub", destination: FeedbackDraft.projectURL)
                }
                Text("XTermX does not install an update from this page. Check release signing and requirements before replacing your copy.").font(.caption)
            }
        }
    }

    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    static var short: String { info["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { info["CFBundleVersion"] as? String ?? "?" }
}
