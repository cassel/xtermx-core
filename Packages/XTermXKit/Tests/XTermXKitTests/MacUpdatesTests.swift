import Foundation
import Testing
@testable import XTermXKit

@Suite struct MacUpdatesTests {
    private static let page = "https://github.com/cassel/xtermx-core/releases/tag/test"
    private static let metadata = "https://github.com/cassel/xtermx-core/releases/download/test/BUILD_INFO.json"
    private static func fixture(version: String = "1.0.0", build: String = "202610172100", minimum: String = "15.0", prerelease: Bool = true, draft: Bool = false, metadataURL: String = metadata, hasDMG: Bool = true) throws -> [URL: Data] {
        var assets: [[String: String]] = [["name": "BUILD_INFO.json", "browser_download_url": metadataURL]]
        if hasDMG { assets.append(["name": "XTermX.dmg", "browser_download_url": "https://github.com/cassel/xtermx-core/releases/download/test/XTermX.dmg"]) }
        let releases: [[String: Any]] = [["draft": draft, "prerelease": prerelease, "html_url": page, "assets": assets]]
        return [
            URL(string: "https://api.github.com/repos/cassel/xtermx-core/releases?per_page=10")!: try JSONSerialization.data(withJSONObject: releases),
            URL(string: metadataURL)!: try JSONSerialization.data(withJSONObject: ["product": "XTermX for macOS", "version": version, "build": build, "minimum_macos": minimum])
        ]
    }
    private static func find(_ fixtures: [URL: Data], development: Bool = true) async throws -> MacUpdates.Available? {
        try await MacUpdates.find(currentVersion: "1.0.0", currentBuild: "202610172000", macOS: "26.0", includeDevelopment: development) { url in
            guard let data = fixtures[url] else { throw MacUpdates.Failure.invalidResponse }
            return data
        }
    }

    @Test func versionsCompareNumericallyAndRejectInvalidInput() {
        #expect(MacUpdates.Version("1.10")! > MacUpdates.Version("1.9.99")!)
        #expect(MacUpdates.Version("1") == MacUpdates.Version("1.0.0"))
        for value in ["", "?", "1..2", "-1", "1.0-beta", "١", "9999999999999999999999999"] {
            #expect(MacUpdates.Version(value) == nil)
        }
    }
    @Test func detectsNewerDevelopmentBuildUsingMetadata() async throws {
        let found = try await Self.find(Self.fixture())
        #expect(found?.build == "202610172100")
        #expect(found?.page.absoluteString == Self.page)
    }
    @Test func neverOffersEqualOrOlderBuilds() async throws {
        for build in ["202610172000", "202610171857"] {
            #expect(try await Self.find(Self.fixture(build: build)) == nil)
        }
        #expect(try await Self.find(Self.fixture(version: "0.9.0", build: "999999999999")) == nil)
    }
    @Test func newerProductVersionTakesPrecedenceOverBuildCounter() async throws {
        #expect(try await Self.find(Self.fixture(version: "1.1.0", build: "1"))?.version == "1.1.0")
    }
    @Test func picksHighestVersionInsteadOfTrustingReleaseOrder() async throws {
        var fixtures = try Self.fixture(version: "1.2.0", build: "1")
        let second = try Self.fixture(build: "999999999999", metadataURL: "https://github.com/cassel/xtermx-core/releases/download/second/BUILD_INFO.json")
        let endpoint = URL(string: "https://api.github.com/repos/cassel/xtermx-core/releases?per_page=10")!
        let firstList = try JSONSerialization.jsonObject(with: fixtures[endpoint]!) as! [[String: Any]]
        let secondList = try JSONSerialization.jsonObject(with: second[endpoint]!) as! [[String: Any]]
        fixtures.merge(second) { first, _ in first }
        fixtures[endpoint] = try JSONSerialization.data(withJSONObject: secondList + firstList)
        #expect(try await Self.find(fixtures)?.version == "1.2.0")
    }
    @Test func channelExcludesDevelopmentButAllowsStableReleases() async throws {
        #expect(try await Self.find(Self.fixture(), development: false) == nil)
        #expect(try await Self.find(Self.fixture(prerelease: false), development: false) != nil)
    }
    @Test func draftsAndUnsupportedMacOSAreNotOffered() async throws {
        #expect(try await Self.find(Self.fixture(draft: true)) == nil)
        #expect(try await Self.find(Self.fixture(minimum: "27.0")) == nil)
    }
    @Test func ignoresSourceOnlyReleasesAndUntrustedMetadataLinks() async throws {
        #expect(try await Self.find(Self.fixture(hasDMG: false)) == nil)
        #expect(try await Self.find(Self.fixture(metadataURL: "https://example.com/BUILD_INFO.json")) == nil)
    }
    @Test func malformedMetadataAndNetworkFailuresAreErrorsNotUpToDate() async throws {
        await #expect(throws: (any Error).self) { try await Self.find(Self.fixture(build: "unknown")) }
        await #expect(throws: (any Error).self) { try await Self.find([:]) }
    }
    @Test func dailyScheduleHonorsDisableThrottleAndClockChanges() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(MacUpdates.shouldCheck(enabled: true, lastAttempt: nil, now: now))
        #expect(!MacUpdates.shouldCheck(enabled: false, lastAttempt: nil, now: now))
        #expect(!MacUpdates.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(-60), now: now))
        #expect(MacUpdates.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(-86_400), now: now))
        #expect(MacUpdates.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(60), now: now))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XTERMX_LIVE_UPDATE_CHECK"] == "1"))
    func publicGitHubReleaseMetadataIsCompatible() async throws {
        let found = try await MacUpdates.find(currentVersion: "0", currentBuild: "0", macOS: "26.0", includeDevelopment: true)
        #expect(found != nil)
        #expect(found?.page.host == "github.com")
    }
}
