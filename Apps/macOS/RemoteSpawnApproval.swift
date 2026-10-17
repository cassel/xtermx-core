import SwiftUI
import XTermXHost

struct RemoteSpawnCard: View {
    let approval: RemoteSpawnApproval
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Open a terminal?", systemImage: "laptopcomputer.and.iphone").font(.headline)
            Text(model.deviceNames.name(identity: approval.deviceID, reported: approval.deviceName)).fontWeight(.medium)
            if let id = approval.deviceID { Text("Signed device · \(id.prefix(12))").font(.caption2.monospaced()) }
            Text(approval.folder).font(.caption).textSelection(.enabled).lineLimit(3)
            if let agent = approval.agentID { Text("Agent: \(agent)").font(.caption) }
            if let input = approval.initialInput, !input.isEmpty {
                DisclosureGroup("Also sends initial text") {
                    ScrollView { Text(input).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 120)
                }
            }
            if approval.bypass { Text("The agent will start with its bypass option.").font(.caption).foregroundStyle(theme.chrome.destructive.color) }
            HStack {
                Button("Decline") { model.server.spawnGate.answer(approval.id, choice: .deny) }
                Spacer()
                Button("Open once") { model.server.spawnGate.answer(approval.id, choice: .once) }
            }
            if approval.deviceID != nil, approval.folder != "/" {
                Button("Trust this folder for this device") { model.server.spawnGate.answer(approval.id, choice: .trustFolder) }
                Text("Includes subfolders. Remove trust in Remote access settings.").font(.caption2)
            } else { Text("This connection has no verified device identity. It can only be approved once.").font(.caption2) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.chrome.popover.color, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.chrome.border.color))
    }
}

struct RemoteSpawnSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsCard("Opening terminals", "Approve a new session here before a device starts it.") {
            Toggle("Ask before opening terminals", isOn: Binding(get: { model.server.spawnGate.rules.askBeforeSpawn },
                                                                  set: { model.server.spawnGate.rules.askBeforeSpawn = $0 }))
                .toggleStyle(.switch)
            Text("Trusted folders skip the question only for the device whose signed identity you approved.").font(.caption)
            if model.server.spawnGate.rules.folders.isEmpty { Text("No trusted folders yet.").font(.caption) }
            ForEach(model.server.spawnGate.rules.folders) { folder in
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(model.deviceNames.name(identity: folder.deviceID, reported: folder.deviceName)).fontWeight(.medium)
                        Text(folder.path).font(.caption).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Remove trust", role: .destructive) { model.server.spawnGate.rules.folders.removeAll { $0.id == folder.id } }
                }
            }
        }
    }
}
