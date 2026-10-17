import AppKit
import CoreImage
import Observation
import SwiftUI
import XTermXHost
import XTermXKit

/// A terminal on another machine, placed in this window's layout.
struct RemoteLeaf: Hashable {
    /// `PairingInfo.id` of the machine.
    let machine: String
    let pane: String
}

/// The other XTermX machines (Linux nodes, other Macs) this Mac is paired with, and live links to them.
@MainActor
@Observable
final class MachineStore {
    private(set) var pairings: [PairingInfo] = PairingStore.load()
    private(set) var connections: [String: HostConnection] = [:]

    init() {
        for p in pairings { open(p) }
    }

    func connection(_ machine: String) -> HostConnection? { connections[machine] }

    func add(_ pairing: PairingInfo) {
        if let old = pairings.first(where: { $0.hostName == pairing.hostName }) { remove(old) }
        pairings.append(pairing)
        PairingStore.save(pairings)
        open(pairing)
    }

    func remove(_ pairing: PairingInfo) {
        connections[pairing.id]?.disconnect()
        connections[pairing.id] = nil
        pairings.removeAll { $0.id == pairing.id }
        PairingStore.save(pairings)
    }

    func reconnect(_ pairing: PairingInfo) {
        connections[pairing.id]?.disconnect()
        connections[pairing.id]?.connect()
    }

    private func open(_ pairing: PairingInfo) {
        let c = HostConnection(pairing: pairing, deviceName: HostIdentity.hostName, platform: .macOS, identity: try? DeviceIdentity.loadOrCreate())
        connections[pairing.id] = c
        c.connect()
    }

    /// Reads an xtermx:// pairing link from a QR code in an image (a screenshot of a server's terminal).
    static func pairingLink(in image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return detector.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first { $0.hasPrefix("xtermx://") }
    }
}

// MARK: - Sidebar section

struct MachinesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var adding = false
    @AppStorage("xtermx.sidebar.machines") private var expanded = true

    var body: some View {
        Section(isExpanded: $expanded) {
            ForEach(model.deviceRoster) { device in
                ConnectedDeviceRow(device: device, compact: true)
            }
            ForEach(model.machines.pairings) { pairing in
                MachineRow(pairing: pairing)
            }
            Button { adding = true } label: { Label("Add machine…", systemImage: "plus") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.chrome.mutedForeground.color)
            Button {
                model.rightTab = .devices
                model.rightPanelVisible = true
            } label: { Label("Pair a device with this Mac…", systemImage: "qrcode") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.chrome.mutedForeground.color)
        } header: { SectionLabel("Machines") }
        .sheet(isPresented: $adding) { AddMachineSheet() }
    }
}

struct MachineRow: View {
    let pairing: PairingInfo
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var expanded = true

    var body: some View {
        let c = model.machines.connection(pairing.id)
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(c?.panes ?? []) { pane in
                PaneRow(pane, agent: pane.agentID.flatMap { id in c?.agents.first { $0.id == id } })
                    .contentShape(Rectangle())
                    .onTapGesture { model.openRemote(machine: pairing.id, pane: pane.id) }
                    .contextMenu {
                        Button("Open") { model.openRemote(machine: pairing.id, pane: pane.id) }
                        Button("Close on \(c?.hostName ?? pairing.hostName)", role: .destructive) { c?.close(paneID: pane.id) }
                    }
            }
            if c?.status == .connected {
                Button { model.newRemoteTerminal(machine: pairing.id) } label: { Label("New terminal", systemImage: "plus") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                Text(c?.hostName ?? pairing.hostName).lineLimit(1)
                Spacer()
                let blocked = c?.panes.filter { $0.state == .blocked }.count ?? 0
                if blocked > 0 {
                    Text("\(blocked)").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4)
                        .background(StateColors.blocked.color, in: Capsule()).foregroundStyle(.black)
                }
                Circle().fill(c?.status == .connected ? StateColors.done.color : StateColors.idle.color).frame(width: 6, height: 6)
            }
            .font(.system(size: 12))
            .help(status(c))
        }
        .contextMenu {
            if c?.status == .connected {
                Button("New terminal on \(c?.hostName ?? pairing.hostName)") { model.newRemoteTerminal(machine: pairing.id) }
            }
            Button("Reconnect") { model.machines.reconnect(pairing) }
            Button("Copy address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c?.activeAddress ?? pairing.address, forType: .string)
            }
            Divider()
            Button("Forget machine", role: .destructive) { model.machines.remove(pairing) }
        }
    }

    private func status(_ c: HostConnection?) -> String {
        switch c?.status {
        case .connected?: "Connected via \(c?.activeAddress ?? "")"
        case .connecting?: "Connecting…"
        case .failed(let why)?: why
        default: "Offline"
        }
    }
}

struct AddMachineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a machine").font(.title3.bold())
            Text("On the other machine run `xtermx pair` (Linux) or open Remote Access (Mac), then paste its link here — or copy a screenshot of its QR code (⌃⇧⌘4) and use Paste QR.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("xtermx://pair?…", text: $link, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
                .font(.system(size: 11, design: .monospaced))
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("Paste QR image") { pasteQR() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }.buttonStyle(.borderedProminent).keyboardShortcut(.return)
                    .disabled(link.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func pasteQR() {
        guard let image = NSImage(pasteboard: .general) else { return error = "There is no image on the clipboard." }
        guard let found = MachineStore.pairingLink(in: image) else { return error = "No XTermX QR code in that image." }
        link = found
        error = nil
    }

    private func add() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let pairing = PairingInfo(url: url) else {
            return error = "That is not an XTermX pairing link."
        }
        model.machines.add(pairing)
        dismiss()
    }
}

/// Same saved name in Machines, Devices and Settings; never keys labels by the generic “iPhone”.
struct DeviceRosterEntry: Identifiable {
    let record: RememberedDevice?
    let connection: ConnectedDevice?
    var id: String { identity ?? connection!.id.uuidString }
    var identity: String? { record?.id ?? connection?.identity }
    var name: String { connection?.name ?? record?.name ?? "Device" }
    var platform: ClientPlatform { connection?.platform ?? record?.platform ?? .iOS }
    var isConnected: Bool { connection != nil }
}

struct ConnectedDeviceRow: View {
    let device: DeviceRosterEntry
    var compact = false
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = ""
    private func edit() {
        name = model.deviceNames.name(identity: device.identity, reported: device.name)
        naming = true
    }
    var body: some View {
        HStack {
            Image(systemName: device.platform == .watchOS ? "applewatch" : device.platform == .iOS ? "iphone" : "laptopcomputer")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName(device)).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(device.isConnected ? StateColors.done.color : StateColors.idle.color).frame(width: 5, height: 5)
                    Text(device.isConnected ? "Connected" : "Offline").font(.caption2).foregroundStyle(.secondary)
                }
                if !compact {
                    if let connection = device.connection {
                        Text(connection.address).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        if connection.connectionCount > 1 { Text("\(connection.connectionCount) connections").font(.caption2).foregroundStyle(.secondary) }
                    } else if let record = device.record {
                        Text("Last connected \(record.lastConnectedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 2)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.plain).help("Name this device")
                .accessibilityLabel("Name this device")
                .disabled(device.identity == nil)
        }
        .font(.system(size: 12))
        .help(device.identity == nil ? "Waiting for this device to verify its identity." : device.name)
        .contextMenu { Button("Name this device", action: edit).disabled(device.identity == nil) }
        .alert("Name this device", isPresented: $naming) {
            TextField("Device name", text: $name)
            Button("Save") { model.nameDevice(device, name: name) }.disabled(!PaneNameRules.isValid(name))
            Button("Use reported name") { model.nameDevice(device, name: "") }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saved on this Mac and kept when this device reconnects.") }
    }
}
