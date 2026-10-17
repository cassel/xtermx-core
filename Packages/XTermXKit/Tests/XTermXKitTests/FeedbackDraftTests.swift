import Foundation
import Testing
import XTermXKit

struct FeedbackDraftTests {
    @Test func draftKeepsTextInQueryItemsAndOnlyIncludesChosenDiagnostic() throws {
        let title = "Falha & teste? 中文 #123"
        let details = "Steps\n1. Open pane\n2. Press ⇧⌘D & inspect = result"
        let plain = try FeedbackDraft.issueURL(title: title, details: details)
        let components = try #require(URLComponents(url: plain, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "github.com")
        #expect(components.path == "/cassel/xtermx-core/issues/new")
        #expect(components.queryItems?.first { $0.name == "title" }?.value == title)
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.hasPrefix(details) && !body.contains("## Reviewed diagnostic"))
        let diagnostic = DiagnosticSummary(version: "1", build: "2", operatingSystem: "Test OS", localPanes: 1, sshPanes: 0, remoteMachinePanes: 0, remoteAccessEnabled: false, connectedDevices: 0, activityEvents: 0)
        let chosen = try FeedbackDraft.issueURL(title: title, details: details, diagnostic: diagnostic)
        let chosenBody = try #require(URLComponents(url: chosen, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        #expect(chosenBody.contains(try diagnostic.preview()))
    }
    @Test func oversizedOrMalformedDraftsAreRejectedBeforeOpeningABrowser() {
        #expect(throws: FeedbackDraft.Failure.self) { try FeedbackDraft.issueURL(title: "  ", details: "") }
        #expect(throws: FeedbackDraft.Failure.self) { try FeedbackDraft.issueURL(title: "bad\ntitle", details: "") }
        #expect(throws: FeedbackDraft.Failure.self) { try FeedbackDraft.issueURL(title: "Test", details: String(repeating: "中文", count: 1000)) }
    }
}
