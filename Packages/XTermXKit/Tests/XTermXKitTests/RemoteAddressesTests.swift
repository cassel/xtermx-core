#if os(macOS)
import Testing
@testable import XTermXHost

@Suite struct RemoteAddressesTests {
    @Test func tailscaleRangeHasPreciseBoundaries() {
        for address in ["100.64.0.0", "100.100.100.100", "100.127.255.255"] {
            #expect(HostIdentity.isTailscaleAddress(address))
        }
        for address in ["100.63.255.255", "100.128.0.0", "100.1.2.3", "192.168.1.2", "127.0.0.1", "host.local",
                        "100.64.0.256", "100.64.-1.1", "100..64.1", "100.64.1", "100.64.1.2.3", "100.64.1.x", ""] {
            #expect(!HostIdentity.isTailscaleAddress(address))
        }
    }
}
#endif
