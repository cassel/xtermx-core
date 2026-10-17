import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import XTermXHost
import XTermXKit

@MainActor @Observable
final class LayoutLibrary {
    private(set) var layouts: [SavedLayout] = []
    private(set) var loaded = false
    var error: String?
    private let url = FileSecretStore.defaultDirectory.appendingPathComponent("layouts.json")

    func load() {
        do { layouts = try SavedLayoutStore.load(from: url); loaded = true; error = nil }
        catch { loaded = false; self.error = error.localizedDescription }
    }

    func save(name: String, session: SavedSession) throws {
        try update([try SavedLayout(name: name, session: session)] + layouts)
    }

    func rename(_ layout: SavedLayout, to name: String) throws {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }) else { throw SavedLayoutError.missingLayout }
        var next = layouts
        next[index] = try SavedLayout(id: layout.id, name: name, session: layout.session)
        try update(next)
    }

    func delete(_ layout: SavedLayout) throws { try update(layouts.filter { $0.id != layout.id }) }

    private func update(_ next: [SavedLayout]) throws {
        guard loaded else { throw SavedLayoutError.missingLayout }
        try SavedLayoutStore.save(next, to: url)
        layouts = next
    }
}

extension AppModel {
    /// Explicitly opening a named layout starts its agents afresh; never replays commands or prompts.
    func openLayout(_ layout: SavedLayout) async throws {
        let saved = try layout.session.freshCopy()
        var prepared: [String: PreparedPaneSpawn] = [:]
        for pane in saved.panes {
            let agentID = pane.agentID.flatMap { id in manager.agents.first { $0.id == id && $0.installed }?.id }
            prepared[pane.id] = try await manager.prepareSpawn(SpawnRequest(kind: .shell, agentID: agentID, cwd: pane.cwd))
        }
        spawningLocally = true
        defer { spawningLocally = false }
        var opened: [Workspace] = []
        for tab in saved.tabs {
            for id in tab.layout.leaves {
                _ = manager.spawnPrepared(prepared[id]!, id: id)
                if let name = saved.panes.first(where: { $0.id == id })?.customName { _ = try? manager.rename(id, to: name) }
            }
            opened.append(Workspace(name: tab.name, layout: tab.layout, focused: tab.focused))
        }
        workspaces += opened
        if !balanceOnOpen { splitFractions.merge(saved.fractions.mapValues { $0.map { CGFloat($0) } }) { _, new in new } }
        let tab = opened[saved.active ?? 0]
        activeID = tab.id
        composing = false
        maximized = nil
        focus(tab.focused)
    }
}

struct SessionLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var name = ""
    @State private var renaming: SavedLayout?
    @State private var rename = ""
    @State private var deleting: SavedLayout?
    @State private var importing = false
    @State private var incoming: SavedLayout?
    @State private var importName = ""
    @State private var exporting = false
    @State private var exportDocument: LayoutFile?
    @State private var exportName = "XTermX-layout"

    private var library: LayoutLibrary { model.layoutLibrary }
    private var matches: [SavedLayout] { library.layouts.filter { $0.matches(search) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2").font(.title).foregroundStyle(theme.chrome.primary.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your layouts").font(.title.bold())
                    Text("Keep a workspace ready for the next task.").foregroundStyle(theme.chrome.mutedForeground.color)
                }
                Spacer()
                Button("Import JSON…") { importing = true }.disabled(!library.loaded)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Save what's open").font(.headline)
                Text("Local tabs, splits, folders and agent choices. Remote panes stay on their machines.")
                    .font(.callout).foregroundStyle(theme.chrome.mutedForeground.color)
                HStack {
                    TextField("Layout name", text: $name).onSubmit(save)
                    Button("Save layout", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.currentSession() == nil || !library.loaded)
                }
            }
            .padding(16).background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 12))
            TextField("Find a layout, folder or agent", text: $search)
            if let error = library.error {
                HStack {
                    Text(error).foregroundStyle(theme.chrome.destructive.color)
                    Spacer()
                    Button("Reload") { library.load() }
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], spacing: 12) {
                    ForEach(matches) { layout in card(layout) }
                }
                if matches.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No layouts yet" : "No matching layouts",
                                           systemImage: "square.grid.2x2",
                                           description: Text(search.isEmpty ? "Arrange your panes, then save them above." : "Try another name or folder."))
                }
            }
            Text("Open adds new tabs. Agents start fresh; unavailable agents open as shells. Missing folders use your home folder.")
                .font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
        }
        .padding(24).frame(minWidth: 680, minHeight: 500)
        .background(theme.chrome.background.color).foregroundStyle(theme.chrome.foreground.color)
        .onAppear { library.load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size < SavedLayoutTransfer.maximumBytes else { throw SavedLayoutTransfer.TransferError.tooLarge }
                let layout = try SavedLayoutTransfer.decode(Data(contentsOf: url))
                importName = layout.name
                incoming = layout
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: exportName) { result in
            perform { _ = try result.get() }
        }
        .sheet(item: $incoming) { layout in
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a layout").font(.title2.bold())
                Text("Review the folders and agents before keeping this file.")
                    .foregroundStyle(theme.chrome.mutedForeground.color)
                TextField("Layout name", text: $importName)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(layout.session.tabs.enumerated()), id: \.offset) { _, tab in
                            Text(tab.name).font(.headline)
                        }
                        ForEach(layout.session.panes, id: \.id) { pane in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pane.agentID ?? "Shell").font(.headline)
                                Text(pane.cwd ?? "Home folder").font(.caption).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("This adds a copy to your library. Open it later to start fresh terminals.").font(.caption)
                if let error = library.error { Text(error).font(.caption).foregroundStyle(theme.chrome.destructive.color) }
                HStack {
                    Button("Cancel") { incoming = nil }
                    Spacer()
                    Button("Add to library") {
                        perform { try library.save(name: importName, session: layout.session); incoming = nil }
                    }.buttonStyle(.borderedProminent)
                        .disabled(importName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24).frame(width: 480, height: 460)
            .background(theme.chrome.background.color).foregroundStyle(theme.chrome.foreground.color)
        }
        .alert("Rename layout", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $rename)
            Button("Save") { if let layout = renaming { perform { try library.rename(layout, to: rename) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete this layout?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let layout = deleting { perform { try library.delete(layout) } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Open terminals keep running.") }
    }

    private func card(_ layout: SavedLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(layout.name).font(.headline).lineLimit(2)
                Spacer()
                Menu {
                    Button("Export JSON…") {
                        perform {
                            exportDocument = LayoutFile(data: try SavedLayoutTransfer.encode(layout))
                            exportName = "XTermX-layout"
                            exporting = true
                        }
                    }
                    Button("Rename…") { rename = layout.name; renaming = layout }
                    Button("Delete…", role: .destructive) { deleting = layout }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 12) {
                Label("\(layout.session.tabs.count) tabs", systemImage: "rectangle.stack")
                Label("\(layout.session.panes.count) panes", systemImage: "rectangle.split.2x2")
            }.font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
            Text(layout.session.tabs.map(\.name).joined(separator: " · ")).lineLimit(2).font(.callout)
            Text(layout.session.savedAt, format: .dateTime.month().day().hour().minute()).font(.caption)
            Button("Open in new tabs") {
                Task { @MainActor in
                    do { try await model.openLayout(layout); library.error = nil; openWindow(id: "main") }
                    catch { library.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).tint(theme.chrome.primary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.chrome.border.color))
    }

    private func save() {
        guard let session = model.currentSession() else { return }
        perform { try library.save(name: name, session: session); name = "" }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); library.error = nil }
        catch { library.error = error.localizedDescription }
    }
}


private struct LayoutFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw SavedLayoutTransfer.TransferError.unsupported }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
