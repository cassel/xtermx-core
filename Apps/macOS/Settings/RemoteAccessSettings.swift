import AppKit
import SwiftUI
import XTermXHost
import XTermXKit

/// Pairing, connected devices and host controls get their own space within the XTermX settings cards.
struct RemoteAccessSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var tab = RemotePage.connect
    @State private var showingCode = false
    @State private var addresses: [String] = []
    @State private var address = ""
    @State private var tailscaleInstalled = false
    @State private var forgetting = false

    private enum RemotePage: String, CaseIterable, Identifiable {
        case connect = "Connect", devices = "Devices", advanced = "Advanced"
        var id: Self { self }
    }

    var body: some View {
        SettingsPage(section: .remoteAccess) {
            Picker("Remote access page", selection: $tab) {
                ForEach(RemotePage.allCases) { page in Text(LocalizedStringKey(page.rawValue)).tag(page) }
            }.pickerStyle(.segmented)
            if let error = model.server.lastError {
                Text(error).foregroundStyle(theme.chrome.destructive.color).textSelection(.enabled)
            }
            switch tab {
            case .connect: connect
            case .devices: devices
            case .advanced: advanced
            }
        }
        .task { await refreshAddresses() }
        .onChange(of: model.server.isRunning) { _, running in if !running { showingCode = false } }
        .alert("Pair every device again?", isPresented: $forgetting) {
            Button("Forget devices", role: .destructive) { model.server.rotateSecret(); showingCode = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects devices and replaces the pairing key. Each device will need a new code.")
        }
    }

    private var connect: some View {
        Group {
            SettingsCard("A link to this Mac", "Use the terminals from your iPhone. Your Watch connects through the phone.") {
                Toggle("Remote access", isOn: Binding(get: { model.remoteEnabled }, set: { model.remoteEnabled = $0 }))
                    .toggleStyle(.switch)
                Label(LocalizedStringKey(model.server.isRunning ? "Ready for connections" : "Connections are off"),
                      systemImage: model.server.isRunning ? "checkmark.circle" : "pause.circle")
                    .foregroundStyle(model.server.isRunning ? StateColors.done.color : theme.chrome.mutedForeground.color)
                Button(LocalizedStringKey(showingCode ? "Hide pairing code" : "Connect my phone")) {
                    Task { await refreshAddresses(); showingCode.toggle() }
                }.disabled(!model.server.isRunning)
                if showingCode, model.server.isRunning, !address.isEmpty {
                    let url = model.server.pairing(addresses: [address] + addresses.filter { $0 != address }).url
                    HStack(alignment: .center, spacing: 20) {
                        QRCodeView(text: url.absoluteString).frame(width: 180, height: 180)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("In XTermX on iPhone, add a Mac and scan this code.")
                            Text("Keep the code private: it grants access to this Mac's shared panes.")
                                .font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
                            Button("Copy pairing link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                        }
                    }
                }
            }
            PairingPasswordSettings()
            if tailscaleInstalled || addresses.contains(where: HostIdentity.isTailscaleAddress) {
                SettingsCard("Beyond your Wi-Fi", "Tailscale can give your devices a private route back to this Mac.") {
                    if addresses.contains(where: HostIdentity.isTailscaleAddress) {
                        Label("A Tailscale address is available", systemImage: "network")
                        Text("Sign in to the same Tailscale network on your phone to connect away from home.")
                    } else {
                        Label("Tailscale is installed", systemImage: "network")
                        Text("Connect Tailscale on this Mac and your phone, then refresh the addresses in Advanced.")
                    }
                    Text("An available address does not guarantee the devices can reach each other.")
                        .font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
                }
            }
        }
    }

    private var devices: some View {
        Group {
            SettingsCard("Your devices", "Devices stay here after their first verified connection, including when offline.") {
                if model.deviceRoster.isEmpty {
                    Label("No devices yet", systemImage: "iphone.slash")
                    Text("A device is remembered after its first connection.").font(.caption)
                }
                ForEach(model.deviceRoster) { device in
                    ConnectedDeviceRow(device: device)
                }
            }
            RemoteSpawnSettings()
            ReceivedFileLimitSettings()
            SettingsCard("What devices can do", "These choices apply to every paired device and take effect immediately.") {
                Toggle("Let devices open new panes", isOn: Binding(get: { model.server.allowRemoteSpawn },
                                                                  set: { model.server.allowRemoteSpawn = $0 }))
                    .toggleStyle(.switch)
                Toggle("Manage Control Rooms", isOn: Binding(get: { model.server.permissions.manageRooms },
                                                             set: { model.server.permissions.manageRooms = $0 }))
                    .toggleStyle(.switch)
                Text("Rename workspace rooms and send a message or command to their local panes.").font(.caption)
                Toggle("Receive files from devices", isOn: Binding(get: { model.server.permissions.sendFiles },
                                                                   set: { model.server.permissions.sendFiles = $0 }))
                    .toggleStyle(.switch)
                Text("Attachment limits are configured below. Older Rooms & files uploads: up to 4 MB.").font(.caption)
                Button("Show received files") {
                    let url = model.server.receivedFiles.directory
                    do {
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    } catch { NSAlert(error: error).runModal() }
                }
                Text("These switches govern remote app actions. A device that can type in a shell can still run shell commands.")
                    .font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
            }
        }
    }

    private var advanced: some View {
        Group {
            SettingsCard("Route to this Mac", "The pairing code includes the available routes. Devices try them in order.") {
                Picker("First address", selection: $address) {
                    ForEach(addresses, id: \.self) { value in
                        Text(HostIdentity.isTailscaleAddress(value) ? "\(value) · Tailscale" : value).tag(value)
                    }
                }
                Button("Refresh addresses") { Task { await refreshAddresses() } }
                LabeledContent("Terminal port", value: String(model.server.port))
                LabeledContent("Watch port", value: String(model.server.httpPort))
                Text("Changing networks may change these addresses. Refresh and pair again if a device cannot connect.")
                    .font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
            }
            SettingsCard("Stay ready", "Keep the Mac available while a device is watching a terminal.") {
                Toggle("Stay awake during remote viewing", isOn: Binding(get: { model.remoteAwake.enabled },
                                                                         set: { model.remoteAwake.enabled = $0 }))
                    .toggleStyle(.switch)
                Text(LocalizedStringKey(model.remoteAwake.active ? "Keeping this Mac awake for remote viewing" : "No sleep hold is active"))
                    .font(.caption)
                Text("The display can still turn off. Watch viewing releases the hold within about 12 seconds after polling stops.").font(.caption)
                if let error = model.remoteAwake.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            SettingsCard("Start pairing over", "Replace the key if a device or pairing link is no longer yours.") {
                Button("Forget all devices…", role: .destructive) { forgetting = true }
            }
        }
    }

    private func refreshAddresses() async {
        let found = await Task.detached(priority: .userInitiated) { HostIdentity.addresses() }.value
        guard !Task.isCancelled else { return }
        addresses = found
        if !addresses.contains(address) { address = addresses.first ?? "" }
        tailscaleInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos") != nil
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") != nil
            || ["/Applications/Tailscale.app", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
                .contains { FileManager.default.fileExists(atPath: $0) }
    }
}

/// A small command menu in the title bar; pairing and device details live on the settings page.
struct RemoteAccessMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var tailscaleAddress: String?

    var body: some View {
        Menu {
            Toggle("Remote access", isOn: Binding(get: { model.remoteEnabled }, set: { model.remoteEnabled = $0 }))
            Text(model.server.isRunning ? "\(model.server.devices.count) devices connected" : "Connections are off")
            Divider()
            Button("Remote settings…") {
                UserDefaults.standard.set(SettingsSection.remoteAccess.rawValue, forKey: "xtermx.settings.section")
                openSettings()
            }
            if let address = tailscaleAddress {
                Text("Tailscale · \(address)")
                Button("Copy Tailscale address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                }
            }
            if let url = tailscaleURL {
                Button("Open Tailscale") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            }
        } label: {
            Image(systemName: "globe")
                .foregroundStyle(model.server.isRunning ? theme.chrome.primary.color : theme.chrome.mutedForeground.color)
                .overlay(alignment: .topTrailing) {
                    if !model.server.devices.isEmpty {
                        Text("\(model.server.devices.count)").font(.system(size: 8, weight: .bold))
                            .padding(2).background(theme.chrome.primary.color, in: Circle()).offset(x: 6, y: -5)
                    }
                }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .task {
            let found = await Task.detached { HostIdentity.addresses().first(where: HostIdentity.isTailscaleAddress) }.value
            guard !Task.isCancelled else { return }
            tailscaleAddress = found
        }
        .help("Remote access \(model.server.isRunning ? "on" : "off") · Settings ⌘⇧G")
        .accessibilityLabel("Remote access")
    }

    private var tailscaleURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys")
            ?? (FileManager.default.fileExists(atPath: "/Applications/Tailscale.app") ? URL(fileURLWithPath: "/Applications/Tailscale.app") : nil)
    }
}

struct PaneSharingSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsPage(section: .sharing) {
            SettingsCard("Shared panes", "Choose what paired devices can do in each local terminal. New panes allow control.") {
                if model.manager.panes.isEmpty { Text("Open a local terminal to choose how it is shared.") }
                ForEach(model.manager.panes) { pane in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pane.displayTitle).fontWeight(.medium)
                            Text(pane.cwd).font(.caption).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Picker("Access to \(pane.displayTitle)", selection: Binding(get: { model.server.paneSharing.access(pane.id) },
                                                                            set: { model.server.setPaneAccess(pane.id, to: $0) })) {
                            ForEach(PaneAccess.allCases) { access in Text(LocalizedStringKey(access.title)).tag(access) }
                        }.labelsHidden().frame(width: 170)
                    }
                }
                Text("Private panes are hidden from device lists and streams. View only allows watching without typing, resizing or approving agent requests.").font(.caption)
                Text("These rules apply to remote app actions. Another terminal that allows control still grants shell access on this Mac.").font(.caption)
            }
        }
    }
}
