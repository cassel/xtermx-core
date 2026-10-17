import AppKit
import Observation
import SwiftUI
import XTermXKit
import XTermXTerminalUI

@MainActor @Observable
final class SSHRemoteEditorState {
    var document: SSHTextDocument?
    var error: String?
    var busy = false
}

struct SSHRemoteEditor: View {
    let session: SSHSession
    let path: String
    let close: () -> Void
    @Bindable var state: SSHRemoteEditorState
    @State private var discard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Remote text", systemImage: "doc.text").font(.headline)
                if state.document?.isDirty == true { Text("Edited").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { requestClose() } label: { Image(systemName: "xmark") }.help("Close editor")
            }
            Text(path).font(.caption).lineLimit(2).textSelection(.enabled)
            if state.busy { ProgressView().controlSize(.small) }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if state.document != nil {
                TextEditor(text: Binding(get: { state.document?.text ?? "" }, set: { state.document?.text = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .disableAutocorrection(true)
                HStack {
                    Button("Save draft locally…") { exportDraft() }
                    Spacer()
                    Button("Save to server") { save() }.disabled(state.document?.isDirty != true || session.status != .connected)
                }
                Text("UTF-8 · 2 MB limit. Saving writes the existing file after checking it has not changed. Drafts stay in memory while XTermX is open. Keep a local copy before editing important files.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { Spacer() }
        }.padding(10).frame(minWidth: 280, idealWidth: 380, maxWidth: 600)
        .disabled(state.busy)
        .task {
            guard state.document == nil else { return }
            state.busy = true; defer { state.busy = false }
            do { state.document = try SSHTextDocument(data: await session.readFile(at: path, limit: SSHTextDocument.limit)) }
            catch { state.error = error.localizedDescription }
        }
        .alert("Discard this draft?", isPresented: $discard) {
            Button("Discard draft", role: .destructive) { close() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("Changes have not been saved to the server. You can save a local copy first.") }
    }
    private func requestClose() { if state.document?.isDirty == true { discard = true } else { close() } }
    private func save() {
        guard let draft = state.document else { return }
        state.busy = true; state.error = nil
        Task { @MainActor in
            defer { state.busy = false }
            do { try await session.saveTextFile(draft, at: path); state.document?.didSave() }
            catch { state.error = error.localizedDescription }
        }
    }
    private func exportDraft() {
        guard let document = state.document else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = (path as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try document.replacement().write(to: url, options: .atomic) } catch { state.error = error.localizedDescription }
    }
}
