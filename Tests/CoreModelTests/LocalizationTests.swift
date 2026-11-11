import Foundation
import XCTest
@testable import CoreModel

/// The interface language is chosen per string at render time, so a missing
/// entry silently falls back to English. These tests make that visible.
final class LocalizationTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "app_language")
        super.tearDown()
    }

    func testTheCatalogShipsTranslationsForEverySupportedLanguage() {
        let tables = AppLocalization.translatedKeys
        for language in AppLanguage.allCases where language != .en {
            let table = tables[language.rawValue] ?? [:]
            XCTAssertFalse(table.isEmpty, "\(language.rawValue) has no translations at all")
        }
        let english = Set(tables["es"]?.keys ?? [:].keys)
        XCTAssertFalse(english.isEmpty)
        for language in AppLanguage.allCases where language != .en {
            let missing = english.subtracting(Set((tables[language.rawValue] ?? [:]).keys))
            XCTAssertTrue(
                missing.isEmpty,
                "\(language.rawValue) is missing \(missing.count) strings, e.g. \(missing.sorted().prefix(5))"
            )
        }
    }

    func testTranslationsKeepTheirPlaceholders() {
        for (language, table) in AppLocalization.translatedKeys where language != "en" {
            for (key, value) in table {
                let expected = key.matches(of: try! Regex("%[0-9]\\$@")).count
                let actual = value.matches(of: try! Regex("%[0-9]\\$@")).count
                XCTAssertEqual(actual, expected, "\(language) dropped a placeholder in \(key)")
            }
        }
    }

    func testTheChosenLanguageDrivesTheLookup() {
        AppLocalization.setting = "pt-BR"
        XCTAssertEqual(AppLocalization.language, .ptBR)
        XCTAssertEqual(L("Cancel"), AppLocalization.translatedKeys["pt-BR"]?["Cancel"] ?? "Cancel")
        XCTAssertNotEqual(L("Cancel"), "Cancel", "pt-BR must not fall back to English")

        AppLocalization.setting = AppLocalization.automatic
        XCTAssertEqual(AppLocalization.language, AppLanguage.device())
    }

    func testPlaceholdersAreFilledInOrder() {
        let value = L("Open %1$@ in %2$@", "api", "Terminal")
        XCTAssertTrue(value.contains("api"), value)
        XCTAssertTrue(value.contains("Terminal"), value)
        XCTAssertFalse(value.contains("%1$@"), value)
        XCTAssertFalse(value.contains("%2$@"), value)
    }

    /// Every `L("…")` call in the shipped sources must have a non-empty
    /// translation in every language; a missing key silently renders English.
    func testEverySourceKeyIsTranslatedInEveryLanguage() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let call = try Regex(#"(?:^|[^A-Za-z0-9_.])L\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys: Set<String> = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "Localization.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: call) {
                let literal = String(match.output[1].substring ?? "")
                XCTAssertFalse(literal.contains("\\("), "interpolation inside L() in \(file.lastPathComponent): \(literal)")
                keys.insert(Self.unescape(literal))
            }
        }
        XCTAssertGreaterThan(keys.count, 1000, "the scan found too few keys; the regex is broken")
        let tables = AppLocalization.translatedKeys
        for language in AppLanguage.allCases where language != .en {
            let table = tables[language.rawValue] ?? [:]
            let missing = keys.filter { (table[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
            XCTAssertTrue(missing.isEmpty, "\(language.rawValue) lacks \(missing.count) keys, e.g. \(missing.sorted().prefix(5))")
        }
    }

    /// Arabic and Chinese values must be written in their own script; a value
    /// in Latin letters only means the string was left in English.
    func testArabicAndChineseUseTheirOwnScript() {
        let tables = AppLocalization.translatedKeys
        let scripts: [(String, ClosedRange<UInt32>)] = [("ar", 0x0600...0x06FF), ("zh-Hans", 0x4E00...0x9FFF), ("zh-Hant", 0x4E00...0x9FFF)]
        for (language, range) in scripts {
            for (key, value) in tables[language] ?? [:] where key.contains(" ") && key.filter(\.isLetter).count > 12 {
                XCTAssertTrue(value.unicodeScalars.contains { range.contains($0.value) }, "\(language) left \"\(key)\" untranslated: \(value)")
            }
        }
    }

    private static func unescape(_ literal: String) -> String {
        var out = ""
        var iterator = Array(literal)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            guard character == "\\", index + 1 < iterator.count else { out.append(character); index += 1; continue }
            let next = iterator[index + 1]
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "u":
                if let close = iterator[(index + 2)...].firstIndex(of: "}"),
                   let scalar = UInt32(String(iterator[(index + 3)..<close]), radix: 16).flatMap(Unicode.Scalar.init) {
                    out.unicodeScalars.append(scalar)
                    index = close + 1
                    continue
                }
                out.append(next)
            default: out.append(next)
            }
            index += 2
        }
        iterator.removeAll()
        return out
    }

    /// The stored placeholder title stays English so matching code keeps working,
    /// but the rail shows it in the chosen language.
    func testPlaceholderThreadTitleRendersTranslated() {
        AppLocalization.setting = "pt-BR"
        let shown = AgentThreadTitle.display(AgentThreadTitle.defaultTitle)
        XCTAssertEqual(shown, AppLocalization.translatedKeys["pt-BR"]?["New thread"])
        XCTAssertNotEqual(shown, "New thread")
        XCTAssertEqual(AgentThreadTitle.display("Fix login"), "Fix login")
        XCTAssertTrue(AgentThreadTitle.isPlaceholder(AgentThreadTitle.defaultTitle))
        AppLocalization.setting = AppLocalization.automatic
    }

    func testDeviceLanguageWalksThePreferredList() {
        XCTAssertEqual(AppLanguage.device(preferredLanguages: ["pt-BR", "en"]), .ptBR)
        XCTAssertEqual(AppLanguage.device(preferredLanguages: ["es-MX"]), .es)
        XCTAssertEqual(AppLanguage.device(preferredLanguages: ["fr-CA"]), .fr)
        XCTAssertEqual(AppLanguage.device(preferredLanguages: ["ar-SA"]), .ar)
        XCTAssertEqual(AppLanguage.device(preferredLanguages: ["zh-Hant-TW"]), .zhHant)
        XCTAssertEqual(AppLanguage.device(preferredLanguages: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(AppLanguage.device(preferredLanguages: ["de-DE"]), .en)
    }
}
