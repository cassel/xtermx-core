import AppKit
import SwiftUI
import XTermXKit

struct FeedbackSettings: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var details = ""
    @State private var includeDiagnostic = false
    @State private var error: String?
    var body: some View {
        SettingsPage(section: .feedback) {
            SettingsCard("Tell us what happened", "Describe the result you expected and what you saw instead.") {
                TextField("Short title", text: $title)
                TextEditor(text: $details).font(.body).frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                Text("Avoid passwords, pairing links, private paths and terminal content you do not want to make public.").font(.caption)
            }
            SettingsCard("A diagnostic you can review", "Prepare a local preview, then decide whether to include it or attach a saved file yourself.") {
                Button("Prepare diagnostic preview") { Task { includeDiagnostic = false; await model.privacy.prepareDiagnostic(model) } }
                if let preview = model.privacy.diagnostic {
                    ScrollView { Text(preview).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 180)
                    HStack {
                        Button("Save reviewed diagnostic…") { model.privacy.saveDiagnostic() }
                        Spacer()
                        Toggle("Include this preview in the issue draft", isOn: $includeDiagnostic).toggleStyle(.checkbox)
                    }
                }
                Text("Opening the draft sends its title, description and any included diagnostic to GitHub. Review and submit the issue there; attach the saved JSON if needed.").font(.caption)
                Button("Open issue draft in browser") { openDraft() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = model.privacy.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }
    private func openDraft() {
        do {
            let diagnostic: DiagnosticSummary?
            if includeDiagnostic, let preview = model.privacy.diagnostic {
                diagnostic = try JSONDecoder().decode(DiagnosticSummary.self, from: Data(preview.utf8))
            } else { diagnostic = nil }
            let url = try FeedbackDraft.issueURL(title: title, details: details, diagnostic: diagnostic)
            guard NSWorkspace.shared.open(url) else { error = InterfaceLanguage.current.text("The browser could not open. Try again."); return }
            error = nil
        } catch FeedbackDraft.Failure.invalidTitle { error = InterfaceLanguage.current.text("Use a title of up to 120 characters on one line.") }
        catch FeedbackDraft.Failure.tooLong { error = InterfaceLanguage.current.text("The draft is too long for a browser link. Shorten it and attach the saved diagnostic file on GitHub.") }
        catch { self.error = error.localizedDescription }
    }
}
