import SwiftUI
import XTermXHost

struct WorktreeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var records: [GitWorktreeRecord] = []
    @State private var selected: GitWorktreeRecord?
    @State private var error: String?
    var body: some View {
        SettingsCard("Separate agent branches", "Give each new agent its own Git worktree when it starts in a repository.") {
            Toggle("Isolate agents in Git worktrees", isOn: Binding(get: { model.isolateAgents }, set: { model.isolateAgents = $0 }))
                .toggleStyle(.switch)
            Text("Starts from the current commit; uncommitted changes stay in the original folder. Existing panes stay where they are.").font(.caption)
            ForEach(records) { record in
                HStack {
                    VStack(alignment: .leading) {
                        Text(record.branch).fontWeight(.medium)
                        Text(record.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Review worktree") { selected = record }
                }
            }
            Button("Refresh worktrees") { Task { await reload() } }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { await reload() }
        .sheet(item: $selected, onDismiss: { Task { await reload() } }) { record in WorktreeReviewSheet(record: record) }
    }
    private func reload() async {
        do { records = try await model.manager.worktreeStore.records(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct WorktreeReviewSheet: View {
    let record: GitWorktreeRecord
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var review: GitWorktreeReview?
    @State private var error: String?
    @State private var message: String?
    @State private var busy = false
    @State private var removing = false
    @State private var merging = false
    private var live: Bool { model.manager.isolatedPanes.values.contains { $0.id == record.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Review isolated work", systemImage: "arrow.triangle.branch").font(.title2.bold())
            Text(record.branch).font(.headline).textSelection(.enabled)
            Text(record.path).font(.caption).textSelection(.enabled)
            if live { Text("A pane is still using this folder. Close it before removing or merging.").font(.caption) }
            if let review {
                Text("\(review.commitsAhead) commits ahead · \(review.clean ? "working tree clean" : "uncommitted changes")")
                if !review.clean { ScrollView { Text(review.changes).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160) }
            } else if busy { ProgressView() }
            if let message { Text(message).font(.caption) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("Keep is always safe. Removing the clean folder keeps its branch and commits. Merging needs both folders clean and the original branch checked out.").font(.caption)
            HStack {
                Button("Keep worktree") { dismiss() }
                Spacer()
                Button("Remove clean folder…", role: .destructive) { removing = true }.disabled(live || busy || review?.clean != true)
                if let base = record.baseBranch {
                    Button("Merge into \(base)…") { merging = true }.disabled(live || busy || review?.clean != true || review?.commitsAhead == 0)
                }
            }
        }
        .padding(24).frame(width: 660)
        .task { await reload() }
        .alert("Remove this worktree folder?", isPresented: $removing) {
            Button("Remove folder", role: .destructive) {
                Task { await perform { try await model.manager.worktreeStore.remove(record); dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("\(record.path)\nThe branch \(record.branch) is kept.") }
        .alert("Merge committed work into \(record.baseBranch ?? "the original branch")?", isPresented: $merging) {
            Button("Merge commits") {
                Task { await perform { try await model.manager.worktreeStore.merge(record); message = "Commits merged. The worktree is kept."; await reload() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Destination: \(record.repository)\nSource: \(record.branch)\nA conflicted merge is aborted; the worktree is kept.") }
    }
    private func reload() async {
        do { review = try await model.manager.worktreeStore.review(record); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !live else { return }
        busy = true; defer { busy = false }
        do { try await action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
