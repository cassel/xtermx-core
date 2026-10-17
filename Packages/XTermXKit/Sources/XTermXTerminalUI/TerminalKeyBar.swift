#if os(iOS)
import SwiftTerm
import UIKit

/// Repeat clocks must remain scheduled while UIKit tracks a held finger.
@MainActor enum TerminalRepeatTimer {
    static func schedule(after interval: TimeInterval, repeats: Bool = false, action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// The row above the keyboard, as in Termius: esc, sticky ctrl and alt (tap for the next key,
/// double-tap to lock), tab, arrows that repeat while held, the symbols a phone keyboard hides,
/// paste, and a key to put the keyboard away.
@MainActor
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    private weak var terminal: TerminalView?
    private let feed: TerminalFeed
    private var ctrl: UIButton!
    private var alt: UIButton!
    private var ctrlLocked = false
    private var altLocked = false
    private var repeatTimer: Timer?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    var enableInputClicksWhenVisible: Bool { true }

    init(terminal: TerminalView, feed: TerminalFeed) {
        self.terminal = terminal
        self.feed = feed
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.repeatTimer?.invalidate(); self?.repeatTimer = nil }
        })
        // SwiftTerm clears a modifier after one key; a locked one comes straight back.
        for name in [Notification.Name.terminalViewControlModifierReset, .terminalViewMetaModifierReset] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: terminal, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.modifiersChanged() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        repeatTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { repeatTimer?.invalidate(); repeatTimer = nil }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    // MARK: Layout

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 44),
        ])

        row.addArrangedSubview(key(symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in
            _ = self?.terminal?.resignFirstResponder()
        })
        row.addArrangedSubview(key("⎋", label: "Escape") { [weak self] in self?.send([0x1b]) })
        ctrl = key("⌃", label: "Control") { [weak self] in self?.toggle(ctrl: true) }
        alt = key("⌥", label: "Option") { [weak self] in self?.toggle(ctrl: false) }
        for (button, lock) in [(ctrl!, #selector(lockCtrl)), (alt!, #selector(lockAlt))] {
            let doubleTap = UITapGestureRecognizer(target: self, action: lock)
            doubleTap.numberOfTapsRequired = 2
            button.addGestureRecognizer(doubleTap)
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(key("⇥", label: "Tab") { [weak self] in self?.send([0x09]) })
        for (symbol, label, normal, app) in [
            ("arrow.left", "Left", EscapeSequences.moveLeftNormal, EscapeSequences.moveLeftApp),
            ("arrow.up", "Up", EscapeSequences.moveUpNormal, EscapeSequences.moveUpApp),
            ("arrow.down", "Down", EscapeSequences.moveDownNormal, EscapeSequences.moveDownApp),
            ("arrow.right", "Right", EscapeSequences.moveRightNormal, EscapeSequences.moveRightApp),
        ] {
            row.addArrangedSubview(repeating(symbol: symbol, label: label) { [weak self] in
                guard let self else { return }
                self.send(self.feed.applicationCursor ? app : normal)
            })
        }
        for text in ["~", "/", "|", "-", "_", "\\", "$", "*", "`", "'", "\""] {
            row.addArrangedSubview(key(text) { [weak self] in self?.terminal?.insertText(text) })
        }
        row.addArrangedSubview(key(symbol: "text.cursor", label: NSLocalizedString("Select text and links", comment: "Terminal selection button")) { [weak self] in self?.feed.selectText() })
        row.addArrangedSubview(key(symbol: "doc.on.clipboard", label: "Paste") { [weak self] in self?.terminal?.paste(nil) })
    }

    private func button(_ title: String?, symbol: String?, label: String?) -> UIButton {
        let button = UIButton(configuration: Self.config(title: title, on: false, locked: false))
        if let symbol { button.configuration?.image = UIImage(systemName: symbol) }
        button.accessibilityLabel = label ?? title
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func key(_ title: String? = nil, symbol: String? = nil, label: String? = nil, action: @escaping () -> Void) -> UIButton {
        let b = button(title, symbol: symbol, label: label)
        b.addAction(UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        }, for: .primaryActionTriggered)
        return b
    }

    /// Sends on touch, then repeats while held, like a hardware key.
    private func repeating(symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let b = button(nil, symbol: symbol, label: label)
        b.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            action()
            self?.repeatTimer?.invalidate()
            self?.repeatTimer = TerminalRepeatTimer.schedule(after: 0.4) { [weak self] in
                self?.repeatTimer = TerminalRepeatTimer.schedule(after: 0.07, repeats: true, action: action)
            }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in self?.repeatTimer?.invalidate() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    static func config(title: String?, on: Bool, locked: Bool) -> UIButton.Configuration {
        var config = on ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let title {
            var text = AttributedString(title, attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 15, weight: on ? .bold : .medium)]))
            if locked { text.underlineStyle = .single }
            config.attributedTitle = text
        }
        return config
    }

    // MARK: Keys

    private func send(_ bytes: [UInt8]) {
        guard let terminal else { return }
        // alt + a key is ESC and the key; ctrl only changes letters, so it waits for the next letter.
        if terminal.metaModifier, bytes.first != 0x1b {
            terminal.send([0x1b] + bytes)
            terminal.metaModifier = false
        } else {
            terminal.send(bytes)
        }
        modifiersChanged()
    }

    private func toggle(ctrl isCtrl: Bool) {
        guard let terminal else { return }
        if isCtrl {
            ctrlLocked = false
            terminal.controlModifier.toggle()
        } else {
            altLocked = false
            terminal.metaModifier.toggle()
        }
        if !terminal.isFirstResponder { _ = terminal.becomeFirstResponder() }
        modifiersChanged()
    }

    @objc private func lockCtrl() {
        ctrlLocked.toggle()
        terminal?.controlModifier = ctrlLocked
        modifiersChanged()
    }

    @objc private func lockAlt() {
        altLocked.toggle()
        terminal?.metaModifier = altLocked
        modifiersChanged()
    }

    private func modifiersChanged() {
        guard let terminal else { return }
        if ctrlLocked && !terminal.controlModifier { terminal.controlModifier = true }
        if altLocked && !terminal.metaModifier { terminal.metaModifier = true }
        ctrl.configuration = Self.config(title: "⌃", on: terminal.controlModifier, locked: ctrlLocked)
        alt.configuration = Self.config(title: "⌥", on: terminal.metaModifier, locked: altLocked)
    }
}
#endif
