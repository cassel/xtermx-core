import AppKit
import SwiftUI
import XTermXKit
import XTermXTerminalUI

struct SSHFilesPanel: View {
    let session: SSHSession
    @Environment(AppModel.self) private var model
    @State private var path = "."
    @State private var loadedPath = "."
    @State private var entries: [SSHRemoteFile] = []
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var renaming: SSHRemoteFile?
    @State private var changingMode: SSHRemoteFile?
    @State private var removing: SSHRemoteFile?
    @State private var value = ""
    @State private var editingPath: String?
    var body: some View {
        Group {
            if let path = editingPath {
                SSHRemoteEditor(session: session, path: path, close: { model.forgetSSHDraft(session, path: path); self.editingPath = nil }, state: model.sshEditor(session, path: path))
            } else { browser }
        }
    }
    private var browser: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Remote files", systemImage: "folder").font(.headline)
                Spacer()
                Button { refresh(path) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh directory")
            }
            HStack {
                Button { refresh((loadedPath as NSString).deletingLastPathComponent.isEmpty ? ".." : (loadedPath as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }
                TextField("Remote path", text: $path).onSubmit { refresh(path) }
                Button("Go") { refresh(path) }
            }
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let notice { Text(notice).font(.caption).textSelection(.enabled) }
            ForEach(model.sshDraftPaths(session), id: \.self) { draft in
                Button { editingPath = draft } label: { Label("Resume draft: " + (draft as NSString).lastPathComponent, systemImage: "pencil") }
                    .font(.caption)
            }
            List(entries) { file in
                HStack {
                    Image(systemName: file.isLink ? "link" : file.isDirectory ? "folder" : "doc")
                    Text(file.name).lineLimit(1)
                    Spacer()
                    if let size = file.size, !file.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if file.isDirectory, let next = SSHFileRules.joining(loadedPath, file.name) { refresh(next) } }
                .contextMenu {
                    if file.isDirectory {
                        Button("Open directory") { if let next = SSHFileRules.joining(loadedPath, file.name) { refresh(next) } }
                    } else {
                        Button("Edit text…") { editingPath = SSHFileRules.joining(loadedPath, file.name) }.disabled(file.isLink || (file.size ?? 0) > UInt64(SSHTextDocument.limit))
                        Button("Download…") { download(file) }.disabled(file.isLink)
                    }
                    Button("Rename…") { value = file.name; renaming = file }
                    Button("Permissions…") { value = String((file.permissions ?? 0o644) & 0o7777, radix: 8); changingMode = file }.disabled(file.isLink)
                    Button("Delete…", role: .destructive) { removing = file }
                }
            }.listStyle(.plain)
            HStack {
                Button("Upload a file…") { upload() }
                Spacer()
                Text("64 MB per file").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(10).frame(minWidth: 260, idealWidth: 310, maxWidth: 450)
        .disabled(busy || session.status != .connected)
        .task { refresh(path) }
        .alert("Rename remote item", isPresented: presented($renaming)) {
            TextField("New name", text: $value)
            Button("Rename") {
                if let file = renaming { let name = value; run { try await session.renameFile(file, in: loadedPath, to: name); await reload() } }
                renaming = nil
            }.disabled(!SSHFileRules.validName(value))
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("The destination must not already exist.") }
        .alert("Change remote permissions", isPresented: presented($changingMode)) {
            TextField("Octal mode, for example 644", text: $value)
            Button("Apply") {
                if let file = changingMode { let mode = value; run { try await session.changePermissions(file, in: loadedPath, to: mode); await reload() } }
                changingMode = nil
            }.disabled(SSHFileRules.permissions(value) == nil)
            Button("Cancel", role: .cancel) { changingMode = nil }
        } message: { Text("Three or four octal digits. This changes access on the server.") }
        .alert("Delete remote item?", isPresented: presented($removing)) {
            Button("Delete", role: .destructive) {
                if let file = removing { run { try await session.removeFile(file, in: loadedPath); await reload() } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("\(removing?.name ?? "Item") will be removed from the server. Folders must be empty. This cannot be undone here.") }
    }
    private func presented(_ item: Binding<SSHRemoteFile?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
    private func refresh(_ next: String) {
        run {
            let absolute = try await session.resolvedDirectory(next)
            let files = try await session.listFiles(at: absolute)
            loadedPath = absolute; path = absolute; entries = files
        }
    }
    private func reload() async { do { entries = try await session.listFiles(at: loadedPath) } catch { self.error = error.localizedDescription } }
    private func upload() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let target = SSHFileRules.joining(loadedPath, url.lastPathComponent) else { return }
        run {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= SSHFileRules.transferLimit else { throw SSHSession.FileFailureForUI.tooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try await session.uploadFile(data, to: target)
            await reload(); notice = "Uploaded \(url.lastPathComponent). Existing files are never overwritten."
        }
    }
    private func download(_ file: SSHRemoteFile) {
        guard let source = SSHFileRules.joining(loadedPath, file.name) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            let data = try await session.readFile(at: source)
            try data.write(to: url, options: .atomic)
            notice = "Downloaded \(file.name)."
        }
    }
}

private extension SSHSession {
    enum FileFailureForUI: LocalizedError {
        case tooLarge
        var errorDescription: String? { "Transfers are limited to 64 MB per file." }
    }
}
