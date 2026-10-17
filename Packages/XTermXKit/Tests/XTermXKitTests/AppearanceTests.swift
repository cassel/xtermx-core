import Foundation
import Testing
@testable import XTermXKit
#if os(macOS)
@testable import XTermXHost
#endif

@Suite struct AppearanceTests {
    @Test func contrastChoicesAndPreferencesRoundTrip() throws {
        for theme in AppTheme.presets {
            #expect(theme.terminal.adjusted(minimumContrast: MinimumContrast.off.rawValue) == theme.terminal)
            for choice in MinimumContrast.allCases where choice != .off {
                let adjusted = theme.terminal.adjusted(minimumContrast: choice.rawValue)
                for i in adjusted.ansi.indices where i != 7 && i != 15 {
                    let minimum = i == 8 ? min(3, choice.rawValue) : choice.rawValue
                    #expect(adjusted.ansi[i].contrast(with: adjusted.background) >= minimum - 0.01)
                }
            }
        }
        var preferences = AppearancePreferences()
        preferences.inactiveDim = 2; preferences.messageWidth = -4
        preferences.focusColor = RGB(0x123456); preferences.border = .dashed
        #expect(preferences.dimOpacity == 0.8 && preferences.lineWidth == 0.5)
        #expect(try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    }
    @Test func messagePulsesAreBoundedExpireAndKeepTheirEndpoints() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var flow = PaneMessageFlow()
        flow.record(from: "a", to: "a", now: now)
        #expect(flow.pulses.isEmpty)
        for i in 0..<30 { flow.record(from: "a", to: "\(i)", now: now) }
        #expect(flow.pulses.count == 24)
        #expect(flow.pulses.first?.to == "6")
        #expect(abs((flow.pulses.first?.progress(now: now.addingTimeInterval(0.6)) ?? 0) - 0.5) < 0.000001)
        let from = CGPoint(x: 10, y: 20), to = CGPoint(x: 100, y: 80)
        for curved in [true, false] {
            #expect(PaneMessageFlow.point(from: from, to: to, progress: 0, curved: curved) == from)
            #expect(PaneMessageFlow.point(from: from, to: to, progress: 1, curved: curved) == to)
            #expect(PaneMessageFlow.point(from: from, to: to, progress: 0.5, curved: curved) == CGPoint(x: 55, y: 50))
        }
        flow.expire(now: now.addingTimeInterval(2))
        #expect(flow.pulses.isEmpty)
    }
}
#if os(macOS)
@MainActor @Suite struct PaneMessageSignalTests {
    @Test func onlyRealDistinctPanesCanSignalAMessage() {
        let manager = PaneManager(detectAgents: false)
        let first = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        let second = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        defer { manager.close(first.id); manager.close(second.id) }
        var edges: [String] = []
        manager.onPaneMessage = { edges.append("\($0)>\($1)") }
        manager.signalMessage(from: first.id, to: first.id)
        manager.signalMessage(from: "missing", to: second.id)
        #expect(edges.isEmpty)
        manager.sendLine(second.id, "echo message-flow", from: first.id)
        #expect(edges == ["\(first.id)>\(second.id)"])
        manager.close(second.id)
        manager.signalMessage(from: first.id, to: second.id)
        #expect(edges.count == 1)
    }
}
#endif
