import SwiftUI
import UniformTypeIdentifiers
import XTermXKit
import XTermXTerminalUI

/// Files dropped on an SSH pane go up over SFTP into the shell's folder (OSC 7), else the login folder.
/// A name already there is never replaced: the person keeps both (a numbered copy) or cancels.
@MainActor
@Observable
final class SSHDropUploader {
    struct Conflict: Identifiable {
        let id = UUID()
        let file: URL
        let directory: String
        let freeName: String
    }

    private(set) var current: String?
    private(set) var progress: Double = 0
    private(set) var message: String?
    var conflict: Conflict?
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func drop(_ providers: [NSItemProvider], into session: SSHSession) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty, session.status == .connected else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor [weak self] in self?.enqueue(url, session) }
            }
        }
        return true
    }

    private func enqueue(_ url: URL, _ session: SSHSession) {
        queue.append(url)
        if task == nil, conflict == nil { next(session) }
    }

    private func next(_ session: SSHSession) {
        guard !queue.isEmpty else { task = nil; return }
        let file = queue.removeFirst()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let directory: String
                if let shell = session.shellDirectory { directory = shell } else { directory = try await session.resolvedDirectory(".") }
                let taken = Set(try await session.listFiles(at: directory).map(\.name))
                let name = file.lastPathComponent
                if taken.contains(name) {
                    conflict = Conflict(file: file, directory: directory, freeName: SSHFileRules.freeName(name, taken: taken))
                    task = nil
                    return
                }
                await upload(file, as: name, into: directory, session)
            } catch {
                message = "Couldn't upload \(file.lastPathComponent): \(error.localizedDescription)"
            }
            task = nil
            next(session)
        }
    }

    /// The person chose in the conflict alert.
    func resolve(_ conflict: Conflict, keepBoth: Bool, session: SSHSession) {
        self.conflict = nil
        task = Task { [weak self] in
            guard let self else { return }
            if keepBoth { await upload(conflict.file, as: conflict.freeName, into: conflict.directory, session) }
            task = nil
            next(session)
        }
    }

    private func upload(_ file: URL, as name: String, into directory: String, _ session: SSHSession) async {
        guard let target = SSHFileRules.joining(directory, name) else {
            message = "\(name) isn't a name the server can take."
            return
        }
        current = name
        progress = 0
        defer { current = nil }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            try await session.uploadFile(at: file, to: target) { [weak self] in self?.progress = $0 }
            message = "Uploaded \(name) to \(directory)"
        } catch {
            message = "Couldn't upload \(name): \(error.localizedDescription). A partial file may remain at \(target)."
        }
    }

    func dismissMessage() { message = nil }
}

/// Drop target, progress and conflict question over an SSH pane.
struct SSHDropTarget: ViewModifier {
    let session: SSHSession?
    @State private var uploader = SSHDropUploader()
    @State private var targeted = false

    func body(content: Content) -> some View {
        if let session {
            content
                .onDrop(of: [.fileURL], isTargeted: $targeted) { uploader.drop($0, into: session) }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                            .overlay(alignment: .bottom) {
                                Text("Upload to \(session.shellDirectory ?? "the login folder")")
                                    .font(.caption).padding(6).background(.regularMaterial, in: Capsule()).padding(8)
                            }
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let name = uploader.current {
                        HStack(spacing: 6) {
                            Text(name).font(.caption).lineLimit(1)
                            ProgressView(value: uploader.progress).frame(width: 90)
                        }
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8)
                    } else if let message = uploader.message {
                        Button { uploader.dismissMessage() } label: {
                            Text(message).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8)
                        .frame(maxWidth: 360, alignment: .trailing)
                        .help("Dismiss")
                    }
                }
                .alert(item: Binding(get: { uploader.conflict }, set: { _ in /* the buttons answer */ })) { c in
                    Alert(title: Text("\(c.file.lastPathComponent) already exists"),
                          message: Text("In \(c.directory). The file there is kept either way."),
                          primaryButton: .default(Text("Keep both as \(c.freeName)")) { uploader.resolve(c, keepBoth: true, session: session) },
                          secondaryButton: .cancel(Text("Skip")) { uploader.resolve(c, keepBoth: false, session: session) })
                }
        } else {
            content
        }
    }
}
