import Foundation

public enum FeedbackDraft {
    public static let projectURL = URL(string: "https://github.com/cassel/xtermx-core")!
    public static let releasesURL = URL(string: "https://github.com/cassel/xtermx-core/releases")!
    public enum Failure: Error { case invalidTitle, tooLong }
    /// A browser draft, never an API call that creates or submits an issue.
    public static func issueURL(title: String, details: String, diagnostic: DiagnosticSummary? = nil) throws -> URL {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, !title.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else { throw Failure.invalidTitle }
        var body = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if let diagnostic { body += "\n\n## Reviewed diagnostic\n```json\n" + (try diagnostic.preview()) + "\n```" }
        body += "\n\nIf you saved a reviewed XTermX diagnostic file, you can attach it here before submitting."
        var components = URLComponents(url: projectURL.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        guard let url = components.url, url.absoluteString.utf8.count <= 8000 else { throw Failure.tooLong }
        return url
    }
}
