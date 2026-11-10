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
