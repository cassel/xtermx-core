#if os(macOS) || os(iOS)
import Citadel
import Foundation
import NIOCore
import XTermXKit

extension SSHSession {
    public struct FileFailure: LocalizedError {
        public var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
    private func files<T>(_ operation: @escaping @Sendable (SFTPClient) async throws -> T) async throws -> T {
        guard status == .connected, let client else { throw FileFailure("Connect to SSH before opening files.") }
        return try await client.withSFTP(operation)
    }
    public func resolvedDirectory(_ path: String) async throws -> String {
        try await files { try await $0.getRealPath(atPath: path) }
    }
    public func listFiles(at path: String) async throws -> [SSHRemoteFile] {
        try await files { sftp in
            try await sftp.listDirectory(atPath: path).flatMap(\.components)
                .filter { SSHFileRules.validName($0.filename) }
                .map { SSHRemoteFile(name: $0.filename, size: $0.attributes.size, permissions: $0.attributes.permissions) }
                .sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        }
    }
    public func readFile(at path: String, limit: Int = SSHFileRules.transferLimit) async throws -> Data {
        guard (1...SSHFileRules.transferLimit).contains(limit) else { throw FileFailure("Invalid transfer limit.") }
        return try await files { sftp in
            try await sftp.withFile(filePath: path, flags: .read) { file in
                if let size = try await file.readAttributes().size, size > UInt64(limit) { throw FileFailure("This file exceeds the transfer limit.") }
                var data = Data()
                while true {
                    let chunk = try await file.read(from: UInt64(data.count), length: UInt32(min(32768, limit - data.count + 1)))
                    if chunk.readableBytes == 0 { return data }
                    guard data.count + chunk.readableBytes <= limit else { throw FileFailure("This file exceeds the transfer limit.") }
                    data.append(contentsOf: chunk.readableBytesView)
                }
            }
        }
    }
    public func uploadFile(_ data: Data, to path: String) async throws {
        guard data.count <= SSHFileRules.transferLimit else { throw FileFailure("Transfers are limited to 64 MB per file.") }
        try await files { sftp in
            // Exclusive create: a concurrent file or symlink can never be overwritten.
            try await sftp.withFile(filePath: path, flags: [.write, .create, .forceCreate]) { file in
                try await file.write(ByteBuffer(bytes: data))
            }
        }
    }
    public func saveTextFile(_ document: SSHTextDocument, at path: String) async throws {
        let replacement = try document.replacement()
        try await files { sftp in
            // Do not truncate until a bounded read verifies the opened file still matches the draft.
            try await sftp.withFile(filePath: path, flags: [.read, .write]) { file in
                var current = Data()
                while true {
                    let chunk = try await file.read(from: UInt64(current.count), length: UInt32(min(32768, SSHTextDocument.limit - current.count + 1)))
                    if chunk.readableBytes == 0 { break }
                    guard current.count + chunk.readableBytes <= SSHTextDocument.limit else { throw SSHTextDocument.Failure.changed }
                    current.append(contentsOf: chunk.readableBytesView)
                }
                try document.checkRemote(current)
                try await file.write(ByteBuffer(bytes: replacement))
                try await file.setAttributes(to: SFTPFileAttributes(size: UInt64(replacement.count)))
            }
        }
    }
    public func renameFile(_ file: SSHRemoteFile, in directory: String, to name: String) async throws {
        guard let old = SSHFileRules.joining(directory, file.name), let new = SSHFileRules.joining(directory, name), old != new else { throw FileFailure("Choose a different file name without slashes.") }
        let names = try await listFiles(at: directory).map(\.name)
        guard !names.contains(name) else { throw FileFailure("A file with that name already exists.") }
        try await files { try await $0.rename(at: old, to: new) }
        guard SSHFileRules.renamed(file.name, to: name, names: try await listFiles(at: directory).map(\.name)) else {
            throw FileFailure("The server did not confirm the rename. Refresh before trying again.")
        }
    }
    public func removeFile(_ file: SSHRemoteFile, in directory: String) async throws {
        guard let path = SSHFileRules.joining(directory, file.name) else { throw FileFailure("Invalid remote name.") }
        try await files { sftp in
            if file.isDirectory { try await sftp.rmdir(at: path) } else { try await sftp.remove(at: path) }
        }
        guard SSHFileRules.removed(file.name, names: try await listFiles(at: directory).map(\.name)) else {
            throw FileFailure("The server did not remove this item. It may be nonempty or permission was denied.")
        }
    }
    public func changePermissions(_ file: SSHRemoteFile, in directory: String, to text: String) async throws {
        guard !file.isLink, let mode = SSHFileRules.permissions(text), let path = SSHFileRules.joining(directory, file.name) else { throw FileFailure("Use three or four octal digits. Links cannot be changed here.") }
        try await files { sftp in
            var attributes = SFTPFileAttributes(); attributes.permissions = mode
            try await sftp.setAttributes(at: path, to: attributes)
        }
    }
}
#endif
