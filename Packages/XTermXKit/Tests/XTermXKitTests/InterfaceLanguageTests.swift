import Foundation
import Testing
import XTermXKit

struct InterfaceLanguageTests {
    @Test func languageSelectionHasPredictableFallbacks() {
        #expect(InterfaceLanguage.system.resolved(preferred: ["pt-PT"]) == .portuguese)
        #expect(InterfaceLanguage.system.resolved(preferred: ["fr-FR", "es-MX"]) == .spanish)
        #expect(InterfaceLanguage.system.resolved(preferred: ["zh-CN"]) == .chinese)
        #expect(InterfaceLanguage.system.resolved(preferred: ["de-DE"]) == .english)
        #expect(InterfaceLanguage.chinese.resolved(preferred: ["en-US"]) == .chinese)
    }
    @Test func explicitLanguageReadsItsOwnBundleAndKeepsUnknownText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        for (code, word) in [("en", "Hello"), ("pt-BR", "Olá"), ("es", "Hola"), ("zh-Hans", "你好")] {
            let folder = root.appendingPathComponent(code + ".lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "\"Hello\" = \"\(word)\";".write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let bundle = try #require(Bundle(url: root))
        #expect(InterfaceLanguage.portuguese.text("Hello", in: bundle) == "Olá")
        #expect(InterfaceLanguage.spanish.text("Hello", in: bundle) == "Hola")
        #expect(InterfaceLanguage.chinese.text("Hello", in: bundle) == "你好")
        #expect(InterfaceLanguage.portuguese.text("User-owned name", in: bundle) == "User-owned name")
    }
    @Test func everyCatalogEntryContainsAllFourLanguagesAndMatchingPlaceholders() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Apps/macOS/Localizable.xcstrings"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        let regex = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:@|lld|ld|llu|lu|d|u|f)"#)
        func placeholders(_ value: String) -> Int { regex.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value)) }
        #expect(strings.count >= 550)
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = try #require(entry["localizations"] as? [String: [String: Any]])
            for language in ["en", "pt-BR", "es", "zh-Hans"] {
                let unit = try #require(localizations[language]?["stringUnit"] as? [String: String])
                let value = try #require(unit["value"])
                #expect(!value.isEmpty, "Missing \(language) for \(key)")
                #expect(placeholders(value) == placeholders(key), "Placeholder mismatch for \(language): \(key)")
            }
        }
    }
}
