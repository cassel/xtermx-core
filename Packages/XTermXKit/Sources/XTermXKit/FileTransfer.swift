import Foundation

public enum FileTransferRequest: Codable, Sendable {
    case begin(id: UUID, name: String, bytes: Int)
    case chunk(id: UUID, offset: Int, data: Data)
    case finish(id: UUID)
    case cancel(id: UUID)
    public var id: UUID {
        switch self { case .begin(let id, _, _), .chunk(let id, _, _), .finish(let id), .cancel(let id): id }
    }
}
public enum FileTransferReply: Codable, Sendable {
    case progress(id: UUID, bytes: Int)
    case complete(id: UUID, file: ReceivedFile)
    case failed(id: UUID, message: String)
    public var id: UUID {
        switch self { case .progress(let id, _), .complete(let id, _), .failed(let id, _): id }
    }
}

public enum FilePromptReference {
    /// Literal shell-safe path, pasted without Return. No command is executed by the transfer.
    public static func text(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "' "
    }
}
