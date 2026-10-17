#if os(macOS) || os(iOS)
import SwiftTerm
import SwiftUI
#if os(iOS)
import CoreText
import UniformTypeIdentifiers
#endif
import XTermXKit

/// The pipe between a terminal view and whatever produces its bytes
/// (a local PTY, a remote pane, an SSH channel).
@MainActor
public final class TerminalFeed {
    /// Bytes typed by the person.
    public var onInput: ((Data) -> Void)?
    /// New size in cells after layout changes.
    public var onResize: ((Int, Int) -> Void)?
    #if os(macOS)
    /// Replays the current screen when SwiftUI creates a replacement AppKit view.
    public var onViewAttached: (() -> Void)?
    #endif
    public var onTitle: ((String) -> Void)?
    /// The person pinched the text to a new size.
    public var onFontSize: ((CGFloat) -> Void)?
    /// Two fingers swiped across the text: +1 for the next pane (to the left), -1 for the previous.
    public var onSwipePane: ((Int) -> Void)?
    /// The program asked for application cursor keys (DECCKM): arrows send ESC O A, not ESC [ A.
    public private(set) var applicationCursor = false
    private var modeTail: [UInt8] = []

    fileprivate weak var view: TerminalView?
    #if os(iOS)
    fileprivate var retainedMobileView: AttachmentTerminalView?
    public func releaseMobileView() { retainedMobileView = nil }
    #endif
    private var pending: [Data] = []

    public init() {}

    /// Bytes from the program, to draw.
    public func receive(_ data: Data) {
        trackModes(data)
        guard let view else {
            pending.append(data)
            return
        }
        view.feed(byteArray: ArraySlice(data))
    }

    /// Clears the screen and scrollback, before a replay (RIS, then erase scrollback).
    public func reset() {
        applicationCursor = false; modeTail.removeAll()
        pending.removeAll()
        view?.feed(byteArray: ArraySlice(Array("\u{1b}c\u{1b}[3J".utf8)))
    }

    /// Follows `ESC [ ? 1 h` / `l` (also inside combined sets such as `ESC [ ? 1 ; 2004 h`), across chunk edges.
    private func trackModes(_ data: Data) {
        let bytes = modeTail + Array(data)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x1b, bytes[i + 1] == 0x63 {
                applicationCursor = false; i += 2; continue
            }
            if i + 3 < bytes.count, bytes[i] == 0x1b, bytes[i + 1] == 0x5b, bytes[i + 2] == 0x3f {
                var j = i + 3
                var params: [Int] = []
                var n = 0
                var digits = false
                while j < bytes.count, j - i < 40 {
                    let b = bytes[j]
                    if b >= 0x30 && b <= 0x39 { n = n * 10 + Int(b - 0x30); digits = true }
                    else if b == 0x3b { params.append(n); n = 0; digits = false }
                    else { if digits { params.append(n) }; break }
                    j += 1
                }
                if j < bytes.count, params.contains(1), bytes[j] == 0x68 || bytes[j] == 0x6c {
                    applicationCursor = bytes[j] == 0x68
                }
                i = j
            } else {
                i += 1
            }
        }
        modeTail = Array(bytes.suffix(16))
    }

    /// Types `data` as if the person had pressed keys (toolbar buttons, dictation).
    public func type(_ data: Data) { onInput?(data) }

    #if os(iOS)
    public var scrollCapabilities: TerminalScrollCapabilities { (view as? AttachmentTerminalView)?.scrollState.read() ?? .init() }
    public var onScrollCapabilitiesChanged: (() -> Void)?
    fileprivate var mousePacketSink: ((Data) -> Void)?
    /// Encode through SwiftTerm's active mouse protocol without sending to the connection.
    public func wheelPacket(up: Bool, at point: CGPoint) -> Data? {
        guard scrollCapabilities.mouseTracking, let view else { return nil }
        let size = view.terminalDimensions
        guard size.cols > 0, size.rows > 0, view.bounds.width > 0, view.bounds.height > 0, view.contentSize.width > 0 else { return nil }
        let x = min(view.bounds.width - 1, max(0, point.x - view.bounds.minX))
        let y = min(view.bounds.height - 1, max(0, point.y - view.bounds.minY))
        // Match the emulator's font grid, excluding unused space at the right/bottom edge.
        let font = view.font as CTFont
        let cellHeight = max(1, ceil((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * view.lineSpacing))
        let cellWidth = max(1, view.contentSize.width / CGFloat(size.cols))
        let col = min(size.cols - 1, Int(x / cellWidth))
        let row = min(size.rows - 1, Int(y / cellHeight))
        var result = Data()
        mousePacketSink = { result.append($0) }
        defer { mousePacketSink = nil }
        let scale = max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
        let pixelX = min(Int(CGFloat(size.cols) * cellWidth * scale) - 1, Int(x * scale))
        let pixelY = min(Int(CGFloat(size.rows) * cellHeight * scale) - 1, Int(y * scale))
        view.sendMouseEvent(button: up ? 4 : 5, release: false, col: col, row: row,
                            pixelX: max(0, pixelX), pixelY: max(0, pixelY))
        return result.isEmpty ? nil : result
    }
    public var onPasteFiles: (([NSItemProvider]) -> Void)?
    /// Optional mobile interaction owner. No desktop behavior changes.
    public var onTouchView: ((UIScrollView) -> Void)? { didSet { if let view { onTouchView?(view) } } }
    public var onCancelTouch: (() -> Void)?
    public var onSelectionStarted: (() -> Void)?
    public var onSelectionFinished: (() -> Void)?
    public var onReviewPaste: ((String) -> Void)?
    public var navigationReady: (() -> Bool)?
    public var onNavigationInput: ((Data) async -> Bool)?
    public var onReviewedInput: (@MainActor (Data) async -> Bool)?
    public var hasSelection: Bool { view?.selectionActive == true }
    public var bracketedPasteEnabled: Bool { view?.terminalStateSnapshot().bracketedPasteMode == true }
    public func setLocalScrollOnly(_ local: Bool) { view?.allowMouseReporting = !local }
    public func setScrollback(_ lines: Int) { view?.changeScrollback(min(100_000, max(100, lines))) }
    public func setTouchFont(_ size: CGFloat) { view?.font = .monospacedSystemFont(ofSize: min(28, max(9, size)), weight: .regular) }
    public var currentFontSize: CGFloat { view?.font.pointSize ?? 13 }
    public func jumpToBottom() {
        guard let view else { return }
        view.setContentOffset(CGPoint(x: 0, y: max(0, view.contentSize.height - view.bounds.height)), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    public func stopTouchInput() { onCancelTouch?() }
    public func setInputModifiers(control: Bool, alt: Bool) {
        view?.controlModifier = control; view?.metaModifier = alt
    }
    public func observeModifierReset(_ callback: @escaping () -> Void) -> [NSObjectProtocol] {
        [Notification.Name.terminalViewControlModifierReset, .terminalViewMetaModifierReset].map { name in
            NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { _ in MainActor.assumeIsolated { callback() } }
        }
    }
    public func useCustomKeyBar() { view?.inputAccessoryView = nil; view?.reloadInputViews() }
    public func pasteText(_ text: String) { view?.pasteText(text) }
    /// User-initiated paste follows the existing attachment and text-review routing.
    public func pasteClipboard() { view?.paste(nil) }
    /// Brings up the keyboard for this terminal (the keyboard button), or puts it away.
    public func showKeyboard(_ show: Bool = true) {
        guard let view else { return }
        _ = show ? view.becomeFirstResponder() : view.resignFirstResponder()
    }
    #endif

    /// Copies the whole scrollback and screen as text.
    public func copyAll() {
        guard let view else { return }
        view.selectAll(view)
        view.copy(view)
    }

    /// A frozen copy of the visible viewport; never selects or sends input to the live terminal.
    public func visibleText() -> String {
        guard let view else { return "" }
        let snapshot = view.terminalStateSnapshot()
        var text = ""
        for (index, row) in snapshot.visibleRows.enumerated() {
            // Soft-wrapped rows belong to the same logical line, including long URLs.
            if index > 0, !row.isWrapped { text += "\n" }
            text += row.text
        }
        return text
    }

    #if os(iOS)
    public func selectText() {
        guard let view = view as? AttachmentTerminalView else { return }
        onCancelTouch?(); onSelectionStarted?()
        view.showTextSelection(visibleText()) { [weak self] in self?.onSelectionFinished?() }
    }
    #endif

    /// Last size the view reported, in cells.
    public fileprivate(set) var size: (cols: Int, rows: Int)?

    func bind(_ view: TerminalView) {
        guard self.view !== view else { return }
        self.view = view
        for chunk in pending { view.feed(byteArray: ArraySlice(chunk)) }
        pending.removeAll()
        #if os(macOS)
        onViewAttached?()
        #endif
    }
}

public struct TerminalSurface {
    let feed: TerminalFeed
    let theme: TerminalTheme
    let fontSize: CGFloat
    /// When true the terminal takes keyboard focus (the pane the person switched to).
    let focused: Bool
    let copyOnSelection: Bool
    let retainMobileState: Bool

    public init(feed: TerminalFeed, theme: TerminalTheme = .default, fontSize: CGFloat = 13, focused: Bool = true, copyOnSelection: Bool = false, retainMobileState: Bool = false) {
        self.feed = feed
        self.theme = theme
        self.fontSize = fontSize
        self.focused = focused
        self.copyOnSelection = copyOnSelection
        self.retainMobileState = retainMobileState
    }

    public final class Coordinator: NSObject, TerminalViewDelegate {
        let feed: TerminalFeed
        var lastTheme: TerminalTheme?
        @MainActor init(feed: TerminalFeed) { self.feed = feed }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                feed.size = (newCols, newRows)
                feed.onResize?(newCols, newRows)
            }
        }
        public func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { feed.onTitle?(title) }
        }
        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                #if os(iOS)
                if let sink = feed.mousePacketSink { sink(Data(data)); return }
                #endif
                feed.onInput?(Data(data))
            }
        }
        public func scrolled(source: TerminalView, position: Double) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            #if os(macOS)
            guard let url = SelectionCopyTerminalView.browserURL(link) else { return }
            NSWorkspace.shared.open(url)
            #else
            guard let url = URL(string: link),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return }
            UIApplication.shared.open(url)
            #endif
        }
        public func bell(source: TerminalView) {}
        public func clipboardCopy(source: TerminalView, content: Data) {
            let text = String(decoding: content, as: UTF8.self)
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        }
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        #if os(iOS)
        /// Long-press arrows; kept alive with the view.
        var arrows: AnyObject?
        private var pinchStart: CGFloat = 13

        /// Pinch to make the text bigger or smaller, 7–24 pt.
        @MainActor @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view as? TerminalView else { return }
            switch gesture.state {
            case .began:
                pinchStart = view.font.pointSize
            case .changed:
                let size = (pinchStart * gesture.scale).rounded().clamped(to: 7...24)
                if size != view.font.pointSize { view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular) }
            case .ended:
                feed.onFontSize?(view.font.pointSize)
            default:
                break
            }
        }

        @MainActor @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            feed.onSwipePane?(gesture.direction == .left ? 1 : -1)
        }
        #endif
    }

    @MainActor public func makeCoordinator() -> Coordinator { Coordinator(feed: feed) }

    @MainActor
    fileprivate func configure(_ view: TerminalView) {
        #if os(macOS)
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        #else
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        #endif
        view.nativeForegroundColor = theme.foreground.platform
        view.nativeBackgroundColor = theme.background.platform
        view.installColors(theme.ansi.map(\.swiftTerm))
    }
}

#if os(macOS)
/// Native selection takes priority over terminal mouse capture. Option keeps TUI mouse controls.
final class SelectionCopyTerminalView: TerminalView {
    var copyOnSelection = false

    static func browserURL(_ link: String) -> URL? {
        guard let url = URL(string: link),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    override init(frame: CGRect, font: NSFont? = nil) {
        super.init(frame: frame, font: font)
        allowMouseReporting = false
        linkReporting = .implicit
        linkHighlightMode = .hoverWithModifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// SwiftTerm uses Command for links. Translate only pointer/modifier events, never typed keys.
    static func linkEvent(_ event: NSEvent) -> NSEvent {
        guard [.flagsChanged, .leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type),
              event.modifierFlags.contains(.control), let copy = event.cgEvent?.copy() else { return event }
        copy.flags.remove(.maskControl)
        copy.flags.insert(.maskCommand)
        return NSEvent(cgEvent: copy) ?? event
    }

    private var modifierMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        guard window != nil else { return }
        // SwiftTerm's flagsChanged is not open. Scope the adapter to this view's window;
        // keyboard events (including Ctrl+C) retain their original modifiers.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if self.bounds.contains(point) {
                if event.type == .flagsChanged {
                    // Let the original event reach the app's shortcut monitors and the
                    // terminal's keyboard protocol first; never consume Control releases.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let window = self.window,
                              self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
                        self.updateLinkPreview(with: event)
                    }
                } else if event.modifierFlags.contains(.control) {
                    // Entering a pane with Control already held must highlight too.
                    self.updateLinkPreview(with: event)
                }
            }
            return event
        }
    }

    private func updateLinkPreview(with event: NSEvent) {
        // Key code zero is not a modifier key: this updates the link renderer without
        // inventing another keyboard-protocol press/release for the terminal program.
        guard let modifiers = NSEvent.keyEvent(with: .flagsChanged, location: event.locationInWindow,
            modifierFlags: event.modifierFlags, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0) else { return }
        flagsChanged(with: Self.linkEvent(modifiers))
    }

    deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        allowMouseReporting = event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control)
        super.mouseDown(with: Self.linkEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: Self.linkEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        defer { allowMouseReporting = false }
        super.mouseUp(with: Self.linkEvent(event))
        if copyOnSelection, selectionActive, selectedRange().length > 0 { copy(self) }
    }
}

extension TerminalSurface: NSViewRepresentable {
    public func makeNSView(context: Context) -> TerminalView {
        let view = SelectionCopyTerminalView(frame: .zero)
        view.copyOnSelection = copyOnSelection
        view.terminalDelegate = context.coordinator
        configure(view)
        context.coordinator.lastTheme = theme
        feed.bind(view)
        if focused { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        return view
    }

    public func updateNSView(_ view: TerminalView, context: Context) {
        (view as? SelectionCopyTerminalView)?.copyOnSelection = copyOnSelection
        if view.font.pointSize != fontSize || context.coordinator.lastTheme != theme { configure(view); context.coordinator.lastTheme = theme }
        if focused, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}
#else
public struct TerminalScrollCapabilities: Equatable, Sendable {
    public var mouseTracking: Bool
    public var alternateScreen: Bool
    public init(mouseTracking: Bool = false, alternateScreen: Bool = false) {
        self.mouseTracking = mouseTracking; self.alternateScreen = alternateScreen
    }
}

/// Terminal callbacks can run under its parser lock. Copy only capability flags here.
fileprivate final class ScrollStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state = TerminalScrollCapabilities()
    func update(_ state: TerminalScrollCapabilities) {
        lock.lock(); defer { lock.unlock() }; self.state = state
    }
    func read() -> TerminalScrollCapabilities {
        lock.lock(); defer { lock.unlock() }; return state
    }
}

fileprivate final class AttachmentTerminalView: TerminalView {
    nonisolated let scrollState = ScrollStateBox()
    var scrollCapabilitiesChanged: (() -> Void)?
    nonisolated override func mouseModeChanged(source: Terminal) {
        scrollState.update(.init(mouseTracking: source.mouseMode != .off, alternateScreen: source.isCurrentBufferAlternate))
        super.mouseModeChanged(source: source)
        DispatchQueue.main.async { [weak self] in self?.scrollCapabilitiesChanged?() }
    }
    nonisolated override func bufferActivated(source: Terminal) {
        scrollState.update(.init(mouseTracking: source.mouseMode != .off, alternateScreen: source.isCurrentBufferAlternate))
        super.bufferActivated(source: source)
        DispatchQueue.main.async { [weak self] in self?.scrollCapabilitiesChanged?() }
    }
    var attachmentPaste: (([NSItemProvider]) -> Bool)?
    var reviewPaste: ((String) -> Void)?
    private weak var selectionController: UIViewController?

    func showTextSelection(_ text: String, onClose: @escaping () -> Void) {
        guard selectionController == nil, let root = window?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let reader = TerminalTextSelectionController(text: text, font: font,
            foreground: nativeForegroundColor, background: nativeBackgroundColor)
        reader.onClose = onClose
        let navigation = UINavigationController(rootViewController: reader)
        navigation.modalPresentationStyle = .pageSheet
        selectionController = navigation
        _ = resignFirstResponder()
        presenter.present(navigation, animated: true)
    }

    override func paste(_ sender: Any?) {
        let providers = UIPasteboard.general.itemProviders
        let hasAttachment = providers.contains { provider in
            provider.registeredTypeIdentifiers.contains { id in
                guard let type = UTType(id) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .fileURL)
            }
        }
        if hasAttachment, attachmentPaste?(providers) == true { return }
        if let text = UIPasteboard.general.string, let reviewPaste { reviewPaste(text); return }
        super.paste(sender)
    }
}

/// The representable always owns a fresh container. Only its terminal child moves between
/// containers, preserving the emulator/scrollback without reusing SwiftUI-owned view identities.
private final class MobileTerminalContainer: UIView {
    let terminal: AttachmentTerminalView
    init(terminal: AttachmentTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        addSubview(terminal)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func layoutSubviews() { super.layoutSubviews(); terminal.frame = bounds }
}

extension TerminalSurface: UIViewRepresentable {
    public func makeUIView(context: Context) -> UIView {
        if retainMobileState, let view = feed.retainedMobileView {
            view.terminalDelegate = context.coordinator
            let offset = view.contentOffset
            configure(view)
            view.contentOffset = offset
            context.coordinator.lastTheme = theme
            let container = MobileTerminalContainer(terminal: view)
            feed.onTouchView?(view)
            return container
        }
        if !retainMobileState { feed.retainedMobileView = nil }
        let view = AttachmentTerminalView(frame: .zero)
        view.scrollCapabilitiesChanged = { [weak feed] in feed?.onScrollCapabilitiesChanged?() }
        view.accessibilityIdentifier = "terminal-surface"
        // Explicit OSC 8 links stay visible and respond to touch; plain URLs are detected
        // in the frozen text-selection screen without stealing terminal taps.
        view.linkHighlightMode = .always
        view.attachmentPaste = { [weak feed] providers in
            guard let handler = feed?.onPasteFiles else { return false }
            handler(providers); return true
        }
        view.reviewPaste = { [weak feed] text in
            if let review = feed?.onReviewPaste { review(text) } else { feed?.pasteText(text) }
        }
        view.terminalDelegate = context.coordinator
        configure(view)
        context.coordinator.lastTheme = theme
        view.contentInsetAdjustmentBehavior = .never
        if !retainMobileState {
            view.inputAccessoryView = TerminalKeyBar(terminal: view, feed: feed)
            let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched))
            pinch.name = "xtermx-legacy-pinch"
            view.addGestureRecognizer(pinch)
            // Two-finger swipe left or right: next or previous pane. One finger stays for scrolling and selecting.
            view.panGestureRecognizer.maximumNumberOfTouches = 1
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped))
                swipe.direction = direction
                swipe.numberOfTouchesRequired = 2
                pinch.require(toFail: swipe)
                swipe.name = "xtermx-legacy-session-swipe"
                view.addGestureRecognizer(swipe)
            }
            context.coordinator.arrows = ArrowPadGesture(terminal: view, feed: feed)
        }
        feed.bind(view)
        if retainMobileState { feed.retainedMobileView = view }
        feed.onTouchView?(view)
        // The pane the person switched to keeps the keyboard up.
        if focused { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        return MobileTerminalContainer(terminal: view)
    }

    public func updateUIView(_ container: UIView, context: Context) {
        guard let view = (container as? MobileTerminalContainer)?.terminal else { return }
        if view.font.pointSize != fontSize || context.coordinator.lastTheme != theme { configure(view); context.coordinator.lastTheme = theme }
    }
}
#endif

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

public extension RGB {
    #if os(macOS)
    var platform: NSColor { NSColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1) }
    #else
    var platform: UIColor { UIColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1) }
    #endif
    var swiftTerm: SwiftTerm.Color { SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257) }
}
#endif
