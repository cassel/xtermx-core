#if os(iOS)
import SwiftTerm
import UIKit

/// Hold two fingers on the text, then drag: arrow keys toward the fingers. The farther the
/// finger goes from where it pressed, the faster they repeat; back at the middle, they stop.
/// One-finger long-press remains available for the native selection and Copy menu.
@MainActor
final class ArrowPadGesture: NSObject {
    enum Direction { case up, down, left, right }

    private let feed: TerminalFeed
    private weak var terminal: TerminalView?
    private var pad: ArrowPadView?
    private var direction: Direction?
    private var distance: CGFloat = 0
    private var timer: Timer?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// How far the finger must go before a key is sent.
    static let deadZone: CGFloat = 16

    init(terminal: TerminalView, feed: TerminalFeed) {
        self.terminal = terminal
        self.feed = feed
        super.init()
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
        press.name = "xtermx-legacy-arrows"
        press.minimumPressDuration = 0.3
        press.numberOfTouchesRequired = 2
        terminal.addGestureRecognizer(press)
        feed.onCancelTouch = { [weak self] in self?.cancel() }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    deinit { timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func cancel() {
        timer?.invalidate(); timer = nil; direction = nil
        pad?.removeFromSuperview(); pad = nil
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard let terminal, let host = terminal.superview else { return }
        let point = gesture.location(in: host)
        switch gesture.state {
        case .began:
            let pad = ArrowPadView(frame: CGRect(x: 0, y: 0, width: 132, height: 132))
            pad.center = point
            host.addSubview(pad)
            self.pad = pad
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard let pad else { return }
            let dx = point.x - pad.center.x, dy = point.y - pad.center.y
            distance = max(abs(dx), abs(dy))
            let now: Direction? = distance < Self.deadZone ? nil
                : abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
            pad.knob(at: CGPoint(x: dx, y: dy))
            guard now != direction else { return }
            direction = now
            pad.highlight(now)
            timer?.invalidate()
            if now != nil {
                send()
                schedule()
            }
        default:
            cancel()
        }
    }

    /// About 4 keys a second just past the dead zone, up to 25 a second 80 points out.
    private func schedule() {
        let interval = max(0.04, 0.25 - Double(distance - Self.deadZone) * 0.0033)
        timer = TerminalRepeatTimer.schedule(after: interval) { [weak self] in
            guard let self, self.direction != nil else { return }
            self.send()
            self.schedule()
        }
    }

    private func send() {
        guard let terminal, let direction else { return }
        let app = feed.applicationCursor
        let bytes: [UInt8] = switch direction {
        case .up: app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        case .down: app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        case .left: app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        case .right: app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
        }
        terminal.send(bytes)
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// The round pad under the finger: four chevrons, the one in use lit, and a knob that follows the finger.
@MainActor
final class ArrowPadView: UIView {
    private var chevrons: [ArrowPadGesture.Direction: UIImageView] = [:]
    private let knobView = UIView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.frame = bounds
        blur.layer.cornerRadius = bounds.width / 2
        blur.clipsToBounds = true
        addSubview(blur)
        layer.cornerRadius = bounds.width / 2
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        let inset: CGFloat = 22
        let places: [(ArrowPadGesture.Direction, String, CGPoint)] = [
            (.up, "chevron.up", CGPoint(x: bounds.midX, y: inset)),
            (.down, "chevron.down", CGPoint(x: bounds.midX, y: bounds.maxY - inset)),
            (.left, "chevron.left", CGPoint(x: inset, y: bounds.midY)),
            (.right, "chevron.right", CGPoint(x: bounds.maxX - inset, y: bounds.midY)),
        ]
        for (direction, symbol, center) in places {
            let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)))
            image.tintColor = UIColor.white.withAlphaComponent(0.55)
            image.center = center
            addSubview(image)
            chevrons[direction] = image
        }
        knobView.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        knobView.layer.cornerRadius = 17
        knobView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        addSubview(knobView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func highlight(_ direction: ArrowPadGesture.Direction?) {
        for (d, image) in chevrons {
            image.tintColor = d == direction ? tintColor : UIColor.white.withAlphaComponent(0.55)
        }
    }

    /// Moves the knob with the finger, kept inside the pad.
    func knob(at offset: CGPoint) {
        let limit = bounds.width / 2 - 20
        let length = max(hypot(offset.x, offset.y), 0.001)
        let scale = min(1, limit / length)
        knobView.center = CGPoint(x: bounds.midX + offset.x * scale, y: bounds.midY + offset.y * scale)
    }
}
#endif
