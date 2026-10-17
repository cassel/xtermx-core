import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public Mac releases only. No credentials, terminal content or machine IDs are sent.
public enum MacUpdates {
    public struct Version: Comparable, Sendable {
        private let numbers: [UInt64]
        public init?(_ value: String) {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
            let numbers = parts.compactMap { UInt64($0) }
            guard numbers.count == parts.count else { return nil }
            self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
        }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
    }

    public struct Available: Equatable, Sendable {
        public let version: String
        public let build: String
        public let page: URL
        public var identity: String { version + "/" + build }
    }
    private struct Release: Decodable {
        let draft: Bool
        let prerelease: Bool
        let html_url: URL
        let assets: [Asset]
    }
    private struct Asset: Decodable { let name: String; let browser_download_url: URL }
    private struct BuildInfo: Decodable {
        let version: String
        let build: String
        let minimum_macos: String
        let product: String
    }
    public enum Failure: Error { case invalidVersion, invalidResponse }
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static func shouldCheck(enabled: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= 86_400
    }

    private static func official(_ url: URL, prefix: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil && url.path.hasPrefix(prefix)
    }

    public static func find(currentVersion: String, currentBuild: String, macOS: String,
                            includeDevelopment: Bool, fetch: Fetch = download) async throws -> Available? {
        guard let installed = Version(currentVersion), let installedBuild = Version(currentBuild), let system = Version(macOS) else { throw Failure.invalidVersion }
        let endpoint = URL(string: "https://api.github.com/repos/cassel/xtermx-core/releases?per_page=10")!
        let data = try await fetch(endpoint)
        guard data.count <= 1_048_576 else { throw Failure.invalidResponse }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        var newest: Available?
        for release in releases where !release.draft && (includeDevelopment || !release.prerelease) {
            guard official(release.html_url, prefix: "/cassel/xtermx-core/releases/tag/"),
                  release.assets.contains(where: { $0.name.hasSuffix(".dmg") && official($0.browser_download_url, prefix: "/cassel/xtermx-core/releases/download/") }),
                  let info = release.assets.first(where: { $0.name == "BUILD_INFO.json" }),
                  official(info.browser_download_url, prefix: "/cassel/xtermx-core/releases/download/") else { continue }
            let metadata = try await fetch(info.browser_download_url)
            guard metadata.count <= 65_536 else { throw Failure.invalidResponse }
            let build = try JSONDecoder().decode(BuildInfo.self, from: metadata)
            guard build.product == "XTermX for macOS", let version = Version(build.version),
                  let number = Version(build.build), let minimum = Version(build.minimum_macos) else { throw Failure.invalidResponse }
            guard minimum <= system, version > installed || (version == installed && number > installedBuild) else { continue }
            if let newest, let previous = Version(newest.version), let previousBuild = Version(newest.build),
               version < previous || (version == previous && number <= previousBuild) { continue }
            newest = Available(version: build.version, build: build.build, page: release.html_url)
        }
        return newest
    }

    public static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("XTermX-Update-Checker", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw Failure.invalidResponse }
        return data
    }
}
