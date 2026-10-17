import Foundation

public struct DictatedText: Sendable {
    public var paneID: String
    public var text: String
    /// A paste without Return: even several lines remain for the person to review before executing.
    public var payload: Data { Data(("\u{1b}[200~" + text.replacingOccurrences(of: "\u{1b}", with: "") + "\u{1b}[201~").utf8) }
}

public struct PaneDictationSession: Sendable {
    public enum Phase: Sendable { case idle, requesting, recording, finishing }
    public private(set) var phase = Phase.idle
    public private(set) var id: UUID?
    public private(set) var paneID: String?
    public private(set) var text = ""
    public init() {}
    @discardableResult public mutating func begin(paneID: String) -> UUID {
        let id = UUID(); self.id = id; self.paneID = paneID; text = ""; phase = .requesting
        return id
    }
    public mutating func ready(_ id: UUID) -> Bool {
        guard self.id == id, phase == .requesting else { return false }
        phase = .recording; return true
    }
    public mutating func update(_ id: UUID, text: String) {
        guard self.id == id, phase == .recording || phase == .finishing else { return }
        self.text = text
    }
    public mutating func stop() {
        if phase == .requesting { cancel() }
        else if phase == .recording { phase = .finishing }
    }
    public mutating func commit(_ id: UUID) -> DictatedText? {
        guard self.id == id, phase == .recording || phase == .finishing, let paneID else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        return text.isEmpty ? nil : DictatedText(paneID: paneID, text: text)
    }
    public mutating func cancel() { phase = .idle; id = nil; paneID = nil; text = "" }
}

public enum DictationHoldKey: String, CaseIterable, Sendable, Identifiable {
    case rightOption, rightControl, rightShift
    public var id: Self { self }
    public var title: String {
        switch self { case .rightOption: "Right Option"; case .rightControl: "Right Control"; case .rightShift: "Right Shift" }
    }
    public func pressed(keyCode: UInt16, flags: UInt) -> Bool? {
        let code: UInt16
        let mask: UInt
        // macOS device-specific masks from IOLLEvent.h, not the aggregate modifier flags.
        switch self {
        case .rightOption: code = 61; mask = 0x00000040
        case .rightControl: code = 62; mask = 0x00002000
        case .rightShift: code = 60; mask = 0x00000004
        }
        return keyCode == code ? flags & mask != 0 : nil
    }
}
