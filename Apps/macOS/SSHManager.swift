import AppKit
import SwiftUI
import XTermXKit
import XTermXTerminalUI

extension AppModel {
    func openSSH(_ host: SSHHost) {
        if let id = sshSessions.first(where: { $0.value.host.id == host.id })?.key { focus(id); return }
        let id = "ssh-" + UUID().uuidString
        let session = SSHSession(host: host)
        sshSessions[id] = session
        let ws = Workspace(name: host.name, layout: .leaf(id), focused: id)
        workspaces.append(ws); activeID = ws.id; composing = false
        focus(id); session.connect()
    }
}

struct SSHSidebarSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("xtermx.sidebar.ssh") private var expanded = true
    @State private var editing: SSHHost?
    @State private var removing: SSHHost?
    var body: some View {
        Section(isExpanded: $expanded) {
            ForEach(model.sshHosts) { host in
                Button { model.openSSH(host) } label: {
                    HStack {
                        Image(systemName: "network").foregroundStyle(host.themeID.map { AppTheme.preset($0).chrome.primary.color } ?? Color.secondary)
                        VStack(alignment: .leading) {
                            Text(host.name)
                            Text("\(host.username)@\(host.host):\(host.port)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.plain)
                .contextMenu {
                    Button("Connect") { model.openSSH(host) }
                    Button("Edit host…") { editing = host }
                    Button("Forget host…", role: .destructive) { removing = host }
                }
            }
            Button { editing = SSHHost(name: "", host: "", username: NSUserName()) } label: { Label("Add SSH host…", systemImage: "plus") }
                .buttonStyle(.plain)
            if model.sshHosts.isEmpty { Text("Save a destination, then connect from here.").font(.caption).foregroundStyle(.secondary) }
        } header: { SectionLabel("SSH") }
        .sheet(item: $editing) { MacSSHHostEditor(host: $0) }
        .alert("Forget this SSH host?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Forget host", role: .destructive) {
                if let host = removing {
                    model.sshHosts.removeAll { $0.id == host.id }
                    SSHHostStore.deleteSecret(for: host); SSHHostStore.forget(host)
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("The saved secret and remembered host key will be removed. Open sessions stay connected.") }
    }
}

struct MacSSHHostEditor: View {
    @State var host: SSHHost
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var error: String?
    @State private var resetKey = false
    private var invalid: String? { SSHConnectionRules.error(host: host.host, port: host.port, username: host.username) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(LocalizedStringKey(host.name.isEmpty ? "New SSH destination" : "Edit SSH destination"), systemImage: "network").font(.title2.bold())
            Form {
                TextField("Name", text: $host.name)
                TextField("Host or IP address", text: $host.host)
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                TextField("Remote user", text: $host.username)
                Picker("Authentication", selection: $host.auth) {
                    Text("Password").tag(SSHHost.Auth.password)
                    Text("OpenSSH Ed25519 key").tag(SSHHost.Auth.ed25519Key)
                }
                if host.auth == .password { SecureField("Password", text: $secret) }
                else {
                    SecureField("Private key", text: $secret)
                    Button("Choose private key…") { chooseKey() }
                    Text("Unencrypted OpenSSH Ed25519 keys are supported. The secret is kept in this Mac's Keychain.").font(.caption)
                }
                TextField("Command after login (optional)", text: $host.startupCommand)
                Picker("Session palette", selection: $host.themeID) {
                    Text("Follow window theme").tag(nil as String?)
                    ForEach(AppTheme.presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                }
                let palette = host.themeID.map(AppTheme.preset) ?? .default
                Text("$ ssh \(host.username)@\(host.host)").font(.caption.monospaced())
                    .foregroundStyle(palette.terminal.foreground.color).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading).background(palette.terminal.background.color, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Leave the secret blank to keep it. The first server key is remembered; a changed key blocks the connection.").font(.caption).foregroundStyle(.secondary)
            if let invalid { Text(invalid).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Forget remembered server key…", role: .destructive) { resetKey = true }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save host") { save() }.disabled(invalid != nil)
            }
        }.padding(24).frame(width: 590)
        .alert("Trust a new server key next time?", isPresented: $resetKey) {
            Button("Forget key", role: .destructive) { SSHHostStore.forget(host) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only do this after verifying a server's key change through another trusted channel.") }
    }
    private func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 65536 else { error = "Choose a private key smaller than 64 KB."; return }
            secret = try String(contentsOf: url, encoding: .utf8); error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard invalid == nil else { return }
        if let problem = SSHSession.secretError(secret.isEmpty ? SSHHostStore.secret(for: host) : secret, for: host.auth) { error = problem; return }
        if host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host.name = host.host }
        if !secret.isEmpty {
            SSHHostStore.setSecret(secret, for: host)
            guard SSHHostStore.secret(for: host) == secret else { error = "The secret could not be saved to Keychain. Unlock it and try again."; return }
        }
        if let i = model.sshHosts.firstIndex(where: { $0.id == host.id }) { model.sshHosts[i] = host }
        else { model.sshHosts.append(host) }
        dismiss()
    }
}

struct SSHConnectionStrip: View {
    let session: SSHSession
    var body: some View {
        HStack {
            switch session.status {
            case .connecting: ProgressView().controlSize(.mini); Text("Connecting securely…")
            case .connected:
                Image(systemName: "lock.shield")
                Text("SSH connected")
                if let key = session.newHostKey { Text("First server key remembered").help(key) }
                Spacer()
                Button("Disconnect") { session.disconnect() }
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                Spacer(); Button("Reconnect") { session.connect() }
            case .closed, .idle:
                Text("SSH disconnected")
                Spacer(); Button("Reconnect") { session.connect() }
            }
        }.font(.caption).padding(6)
    }
}
