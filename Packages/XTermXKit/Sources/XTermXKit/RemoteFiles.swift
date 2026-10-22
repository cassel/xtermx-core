import Foundation

public struct SSHRemoteFile: Identifiable, Sendable, Equatable {
    public var name: String
    public var size: UInt64?
    public var permissions: UInt32?
    public var id: String { name }
    public var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    public var isLink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }
    public init(name: String, size: UInt64?, permissions: UInt32?) { self.name = name; self.size = size; self.permissions = permissions }
}

public enum SSHFileRules {
    public static let transferLimit = 64 * 1024 * 1024
    public static let uploadLimit = 1024 * 1024 * 1024
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains(where: { $0 == "/" || $0 == "\\" || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
    }
    public static func joining(_ directory: String, _ name: String) -> String? {
        guard validName(name) else { return nil }
        if directory == "/" { return "/" + name }
        return directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .withRemoteRoot(directory.hasPrefix("/")) + "/" + name
    }
    public static func permissions(_ text: String) -> UInt32? {
        guard (3...4).contains(text.count), text.allSatisfy({ "01234567".contains($0) }) else { return nil }
        return UInt32(text, radix: 8)
    }
    /// Citadel 0.9 does not check status for rename/remove; require visible postconditions too.
    public static func removed(_ name: String, names: [String]) -> Bool { !names.contains(name) }
    public static func renamed(_ old: String, to new: String, names: [String]) -> Bool { old != new && !names.contains(old) && names.contains(new) }

    /// The folder a shell reported with OSC 7 (`file://host/path`, percent-encoded), or nil when it isn't an absolute path.
    public static func directory(fromOSC7 payload: String) -> String? {
        var text = Substring(payload)
        if text.hasPrefix("7;") { text = text.dropFirst(2) }
        let path: String
        if text.hasPrefix("file://") {
            let rest = text.dropFirst("file://".count)
            guard let slash = rest.firstIndex(of: "/"), let decoded = String(rest[slash...]).removingPercentEncoding else { return nil }
            path = decoded
        } else {
            guard !text.contains("://") else { return nil }
            path = String(text)
        }
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return path
    }

    /// `name`, or "name 2.ext", "name 3.ext"… when it is taken: a dropped file never replaces one already there.
    public static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ns = name as NSString
        let ext = name.hasPrefix(".") && !name.dropFirst().contains(".") ? "" : ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}

private extension String {
    func withRemoteRoot(_ rooted: Bool) -> String { (rooted ? "/" : "") + self }
}
