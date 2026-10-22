#if os(macOS) || os(iOS)
import Crypto
import Foundation
import NIOSSH
import XTermXKit

/// A host an `~/.ssh/config` import would add, or update when a saved host has the same name.
public struct SSHImportCandidate: Identifiable, Sendable {
    public var host: SSHHost
    public var isUpdate: Bool
    public var id: UUID { host.id }
}

extension SSHHost {
    /// Maps config entries to hosts. Saved hosts with the same name keep their id, auth, command and palette.
    public static func importCandidates(_ entries: [SSHConfigEntry], from path: String, existing: [SSHHost],
                                        defaultUser: String) -> [SSHImportCandidate] {
        entries.map { entry in
            let match = existing.first { $0.name == entry.alias }
            var host = match ?? SSHHost(name: entry.alias, host: "", username: defaultUser)
            host.host = entry.hostName ?? entry.alias
            host.port = entry.port ?? 22
            host.username = entry.user ?? defaultUser
            host.identityFile = entry.identityFile
            host.proxyJump = entry.proxyJump
            host.importedFrom = path
            return SSHImportCandidate(host: host, isUpdate: match != nil)
        }
    }

    /// Replaces hosts with the same id and appends the rest, keeping the saved order.
    public static func merging(_ imported: [SSHHost], into existing: [SSHHost]) -> [SSHHost] {
        var all = existing
        for host in imported {
            if let i = all.firstIndex(where: { $0.id == host.id }) { all[i] = host } else { all.append(host) }
        }
        return all
    }

    /// The key text, only for an unencrypted OpenSSH Ed25519 key no larger than 64 KB.
    public static func loadableKey(at path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= 65536,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              (try? Curve25519.Signing.PrivateKey(sshEd25519: text)) != nil else { return nil }
        return text
    }
}
#endif
