import Foundation

public struct SSHTextDocument: Sendable {
    public static let limit = 2 * 1024 * 1024
    public enum Failure: LocalizedError {
        case notText, tooLarge, changed
        public var errorDescription: String? {
            switch self {
            case .notText: "Open a UTF-8 text file without NUL bytes. Download binary files instead."
            case .tooLarge: "The remote editor supports text files up to 2 MB."
            case .changed: "The remote file changed since opening. Your draft is kept; download or reopen the remote version before saving."
            }
        }
    }
    public private(set) var original: Data
    public var text: String
    public var isDirty: Bool { Data(text.utf8) != original }
    public init(data: Data) throws {
        guard data.count <= Self.limit else { throw Failure.tooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw Failure.notText }
        self.original = data; self.text = text
    }
    public func replacement() throws -> Data {
        let data = Data(text.utf8)
        guard data.count <= Self.limit else { throw Failure.tooLarge }
        guard !data.contains(0) else { throw Failure.notText }
        return data
    }
    public func checkRemote(_ data: Data) throws { guard data == original else { throw Failure.changed } }
    public mutating func didSave() { original = Data(text.utf8) }
}
