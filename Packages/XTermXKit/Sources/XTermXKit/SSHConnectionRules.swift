import Foundation

public enum SSHConnectionRules {
    public static func error(host: String, port: Int, username: String) -> String? {
        if host.isEmpty || host.count > 253 || host.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue == 0 }) || host.contains("://") {
            return "Enter a host name or IP address without a URL scheme or spaces."
        }
        if !(1...65535).contains(port) { return "The port must be between 1 and 65535." }
        if username.isEmpty || username.count > 128 || username.contains(where: { $0.isWhitespace || $0.asciiValue == 0 }) {
            return "Enter the remote user name without spaces."
        }
        return nil
    }
}
