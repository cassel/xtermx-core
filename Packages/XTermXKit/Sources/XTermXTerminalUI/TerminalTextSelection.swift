#if os(iOS)
import UIKit

/// Static, local text: output updates cannot move the selection and editing cannot reach a PTY.
@MainActor
final class TerminalTextSelectionController: UIViewController, UITextViewDelegate {
    private let text: String
    private let terminalFont: UIFont
    private let foreground: UIColor
    private let background: UIColor

    init(text: String, font: UIFont, foreground: UIColor, background: UIColor) {
        self.text = text
        terminalFont = font
        self.foreground = foreground
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Select text and links", comment: "Terminal selection screen")
        view.backgroundColor = background
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let hint = UILabel()
        hint.text = NSLocalizedString("Hold to select and copy. Tap a web link to open it. This snapshot stays still while your terminal runs.", comment: "Terminal selection instructions")
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = foreground.withAlphaComponent(0.75)
        hint.numberOfLines = 0
        let content = UITextView()
        content.accessibilityIdentifier = "terminal-selection-text"
        content.isEditable = false
        content.isSelectable = true
        content.dataDetectorTypes = .link
        content.delegate = self
        content.font = terminalFont
        content.textColor = foreground
        content.backgroundColor = background
        content.text = text
        content.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.alwaysBounceVertical = true
        for child in [hint, content] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    private func webLink(_ item: UITextItem) -> URL? {
        guard case let .link(url) = item.content,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        webLink(textItem) == nil ? nil : defaultAction
    }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        guard webLink(textItem) != nil else { return nil }
        return UITextItem.MenuConfiguration(preview: nil, menu: defaultMenu)
    }
}
#endif
