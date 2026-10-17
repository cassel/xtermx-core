import Foundation

public enum MinimumContrast: Double, Codable, CaseIterable, Sendable, Identifiable {
    case off = 0, gentle = 3, standard = 4.5, strong = 7
    public var id: Self { self }
    public var title: String { self == .off ? "Off" : "\(rawValue.formatted()) : 1" }
}
public enum PaneBorderStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, solid, dashed
    public var id: Self { self }
    public var title: String { rawValue.capitalized }
}
public enum MessageLinePattern: String, Codable, CaseIterable, Sendable, Identifiable {
    case solid, dashed, dotted
    public var id: Self { self }
    public var title: String { rawValue.capitalized }
    public var dash: [CGFloat] {
        switch self { case .solid: []; case .dashed: [8, 5]; case .dotted: [1, 5] }
    }
}
public struct AppearancePreferences: Codable, Sendable, Equatable {
    public var contrast = MinimumContrast.standard
    public var inactiveDim = 0.0
    public var border = PaneBorderStyle.solid
    public var focusColor: RGB?
    public var messageLines = true
    public var curvedMessages = true
    public var messagePattern = MessageLinePattern.dashed
    public var messageWidth = 2.0
    public var messageColor: RGB?
    public init() {}
    public var dimOpacity: Double { min(0.8, max(0, inactiveDim)) }
    public var lineWidth: Double { min(6, max(0.5, messageWidth)) }
}

public struct PaneMessagePulse: Identifiable, Sendable {
    public var id = UUID()
    public var from: String
    public var to: String
    public var at: Date
    public static let duration: TimeInterval = 1.2
    public func progress(now: Date) -> Double? {
        let elapsed = now.timeIntervalSince(at)
        return elapsed >= 0 && elapsed < Self.duration ? elapsed / Self.duration : nil
    }
}
public struct PaneMessageFlow: Sendable {
    public private(set) var pulses: [PaneMessagePulse] = []
    public init() {}
    public mutating func record(from: String, to: String, now: Date = .now) {
        guard from != to else { return }
        expire(now: now)
        pulses.append(PaneMessagePulse(from: from, to: to, at: now))
        if pulses.count > 24 { pulses.removeFirst(pulses.count - 24) }
    }
    public mutating func expire(now: Date = .now) { pulses.removeAll { now.timeIntervalSince($0.at) >= PaneMessagePulse.duration } }
    public static func point(from: CGPoint, to: CGPoint, progress: Double, curved: Bool) -> CGPoint {
        let t = min(1, max(0, progress)), u = 1 - t
        guard curved else { return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t) }
        let middle = (from.x + to.x) / 2
        return CGPoint(x: u * u * u * from.x + 3 * u * u * t * middle + 3 * u * t * t * middle + t * t * t * to.x,
                       y: u * u * u * from.y + 3 * u * u * t * from.y + 3 * u * t * t * to.y + t * t * t * to.y)
    }
}
