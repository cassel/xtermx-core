import SwiftUI
import XTermXKit

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var clearing = false
    @State private var showingEvents = false
    var body: some View {
        @Bindable var privacy = model.privacy
        SettingsPage(section: .privacy) {
            SettingsCard("Activity on this Mac", "A small local history of pane openings and closures, including panes requested by agents.") {
                Toggle("Keep local activity logs", isOn: $privacy.enabled).toggleStyle(.switch)
                Picker("Remove activity after", selection: $privacy.days) {
                    Text("30 days").tag(30); Text("60 days").tag(60); Text("90 days").tag(90)
                }
                Text("Only time, action, pane kind, an opaque reference and whether an agent opened it. No terminal text, prompts, folders, host names or secrets. Up to 2,000 events.").font(.caption)
                Text("Agents can request a pane; only a person can close it. Retention applies to XTermX's activity file.").font(.caption)
                HStack {
                    Text("\(privacy.records.count) local events").font(.caption)
                    Spacer()
                    Button("Refresh") { Task { await privacy.refresh() } }
                    Button(LocalizedStringKey(showingEvents ? "Hide activity" : "Review activity")) { showingEvents.toggle() }
                    Button("Clear activity…", role: .destructive) { clearing = true }
                }
                if showingEvents {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(privacy.records.suffix(100).enumerated()), id: \.offset) { _, entry in
                                Text("\(entry.date.formatted()) · \(entry.action.rawValue) · \(entry.kind.rawValue) · \(entry.openedByAgent ? "agent-requested" : "person-requested") · \(entry.paneReference)")
                                    .font(.caption.monospaced())
                            }
                        }
                    }.frame(maxHeight: 180)
                }
            }
            SettingsCard("Review a diagnostic", "See the exact JSON before saving a file. Nothing is sent by XTermX.") {
                Text("Build and macOS version, counts of open panes and devices, remote-access on/off and activity count. No logs, addresses, pairing links or user files are attached.").font(.caption)
                Button("Prepare diagnostic preview") { Task { await privacy.prepareDiagnostic(model) } }
                if let diagnostic = privacy.diagnostic {
                    ScrollView { Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 220)
                    Button("Save reviewed diagnostic…") { privacy.saveDiagnostic() }
                }
            }
            if let error = privacy.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task { await privacy.refresh() }
        .alert("Clear local activity?", isPresented: $clearing) {
            Button("Clear activity", role: .destructive) { Task { await privacy.clear() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only XTermX's activity file is removed. It records new events again while logging is on.") }
    }
}
