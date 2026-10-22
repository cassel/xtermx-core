import AppKit
import XTermXKit
import XTermXHost

/// Moves text between the Mac's pasteboard and paired devices that opted in.
///
/// The pasteboard has no change notification, so its change count is read once a second while the
/// owner shares the clipboard. Text that just came from a device is not sent back (`ClipboardSync`).
@MainActor
final class MacClipboardBridge {
    private var sync = ClipboardSync()
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private weak var server: RemoteServer?

    func start(server: RemoteServer) {
        self.server = server
        server.onClipboard = { [weak self] text, _ in self?.received(text) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Text a program in a pane asked to copy (OSC 52), once the person allowed that.
    func programCopied(_ text: String) {
        guard ClipboardRules.accepts(text) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // The next poll sees the change and sends it to devices like any other copy.
    }

    private func received(_ text: String) {
        guard let text = sync.incoming(text) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let server, server.permissions.shareClipboard,
              // Password managers mark secrets as concealed or transient; those never leave the Mac.
              !(pasteboard.types ?? []).contains(where: { $0.rawValue == "org.nspasteboard.ConcealedType" || $0.rawValue == "org.nspasteboard.TransientType" }),
              let text = pasteboard.string(forType: .string), let outgoing = sync.outgoing(text) else { return }
        server.shareClipboard(outgoing)
    }
}
