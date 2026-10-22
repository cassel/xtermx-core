import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Wake-on-LAN: a "magic packet" (6 × 0xFF, then the MAC 16 times) broadcast over UDP port 9.
public enum WakeOnLAN {
    public static let port: UInt16 = 9

    /// `aa:bb:cc:dd:ee:ff` or `aa-bb-…` → 6 bytes; nil if malformed or all zero.
    public static func parseMAC(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: text.contains("-") ? "-" : ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard p.count == 2, let b = UInt8(p, radix: 16) else { return nil }
            bytes.append(b)
        }
        return bytes.allSatisfy({ $0 == 0 }) ? nil : bytes
    }

    public static func magicPacket(mac: String) -> Data? {
        guard let bytes = parseMAC(mac) else { return nil }
        return Data([UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined()))
    }

    /// Directed broadcast address for an IPv4 address and netmask.
    public static func broadcast(address: String, netmask: String) -> String? {
        guard let a = ipv4(address), let m = ipv4(netmask) else { return nil }
        let b = a | ~m
        return [24, 16, 8, 0].map { String((b >> $0) & 0xFF) }.joined(separator: ".")
    }

    static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let o = UInt8(p) else { return nil }
            v = v << 8 | UInt32(o)
        }
        return v
    }

    public enum SendError: Error, Equatable { case badMAC, socket(Int32) }

    /// Sends the magic packet to `broadcast` (or 255.255.255.255) on port 9. Blocking but brief.
    public static func send(mac: String, broadcast: String?) throws {
        guard let packet = magicPacket(mac: mac) else { throw SendError.badMAC }
        let targets = Set([broadcast, "255.255.255.255"].compactMap { $0 })
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP))
        #else
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard fd >= 0 else { throw SendError.socket(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sent = false
        var lastError: Int32 = 0
        for target in targets {
            var addr = sockaddr_in()
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            let n = packet.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if n == packet.count { sent = true } else { lastError = errno }
        }
        if !sent { throw SendError.socket(lastError) }
    }

    /// The MAC and broadcast address of this machine's primary wired/Wi-Fi interface (en*, with IPv4).
    public static func localTarget() -> (mac: String, broadcast: String?)? {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var macs: [String: String] = [:]
        var v4: [(name: String, broadcast: String?)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en"), ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            switch Int32(sa.pointee.sa_family) {
            case AF_LINK:
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    guard dl.pointee.sdl_alen == 6 else { return }
                    let bytes = withUnsafeBytes(of: dl.pointee.sdl_data) { raw in
                        Array(raw[Int(dl.pointee.sdl_nlen)..<Int(dl.pointee.sdl_nlen) + 6])
                    }
                    macs[name] = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            case AF_INET:
                func text(_ s: UnsafeMutablePointer<sockaddr>?) -> String? {
                    guard let s else { return nil }
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(s, socklen_t(s.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                    return String(cString: buf)
                }
                let bc = text(ifa.ifa_addr).flatMap { a in text(ifa.ifa_netmask).flatMap { broadcast(address: a, netmask: $0) } }
                v4.append((name, bc))
            default: break
            }
        }
        for candidate in v4.sorted(by: { $0.name < $1.name }) {
            if let mac = macs[candidate.name], parseMAC(mac) != nil { return (mac, candidate.broadcast) }
        }
        return nil
        #else
        return nil
        #endif
    }
}
