#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// Bounded, ordered transfers bound to a signed RPC identity or one authenticated socket.
@MainActor public final class FileChunkReceiver {
    private struct Transfer {
        var owner: String
        var name: String
        var expected: Int
        var received = 0
        var file: URL
        var touched: Date
    }
    private var pending: [UUID: Transfer] = [:]
    public init() {}
    public func cancel(_ id: UUID, owner: String) {
        guard let item = pending[id], item.owner == owner else { return }
        try? FileManager.default.removeItem(at: item.file); pending[id] = nil
    }
    public func cancelAll(owner: String? = nil) {
        for (id, item) in pending where owner == nil || item.owner == owner { cancel(id, owner: item.owner) }
    }
    public func handle(_ request: FileTransferRequest, owner: String, store: ReceivedFileStore, now: Date = .now) throws -> FileTransferReply {
        let fm = FileManager.default
        for (id, item) in pending where now.timeIntervalSince(item.touched) > 300 { cancel(id, owner: item.owner) }
        func rejected(_ message: String) -> FileTransferReply { .failed(id: request.id, message: message) }
        switch request {
        case .begin(let id, let name, let bytes):
            guard pending[id] == nil, RemoteFileRules.validName(name), (0...RemoteFileRules.maximumTransferBytes).contains(bytes) else { return rejected("Choose a regular file up to 64 MB with a plain filename.") }
            guard pending.count < 4, pending.values.filter({ $0.owner == owner }).count < 2,
                  pending.values.reduce(0, { $0 + $1.expected }) + bytes <= RemoteFileRules.maximumStoredBytes else { return rejected("Another transfer is in progress. Wait or cancel it first.") }
            let directory = store.directory.appendingPathComponent(".incoming", isDirectory: true)
            for path in [store.directory, directory] {
                guard (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return rejected("The received-files path cannot be a symbolic link.") }
            }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Reap only our abandoned staging files, never unfamiliar content.
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) where file.pathExtension == "part" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile == true, values.isSymbolicLink != true, let date = values.contentModificationDate, now.timeIntervalSince(date) > 900 { try fm.removeItem(at: file) }
            }
            let file = directory.appendingPathComponent(id.uuidString + ".part")
            try Data().write(to: file, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            pending[id] = Transfer(owner: owner, name: name, expected: bytes, file: file, touched: now)
            return .progress(id: id, bytes: 0)
        case .cancel(let id):
            cancel(id, owner: owner)
            return .progress(id: id, bytes: 0)
        case .chunk(let id, let offset, let data):
            guard var item = pending[id], item.owner == owner else { return rejected("This transfer is not active for this device.") }
            guard offset == item.received, !data.isEmpty, data.count <= RemoteFileRules.chunkBytes, data.count <= item.expected - item.received else { return rejected("The transfer chunk is out of order or exceeds its size.") }
            let values = try item.file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return rejected("The staging file is not a regular file.") }
            let file = try FileHandle(forWritingTo: item.file); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
            item.received += data.count; item.touched = now; pending[id] = item
            return .progress(id: id, bytes: item.received)
        case .finish(let id):
            guard let item = pending[id], item.owner == owner else { return rejected("This transfer is not active for this device.") }
            guard item.received == item.expected else { return rejected("The transfer is incomplete.") }
            let file = try store.receive(name: item.name, source: item.file)
            cancel(id, owner: owner)
            return .complete(id: id, file: file)
        }
    }
}
#endif
