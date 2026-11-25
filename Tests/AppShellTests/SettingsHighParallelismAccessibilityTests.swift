import XCTest

/// Source contract for the accounts section: an identifier on its container
/// replaced every child control identifier in the packaged AX tree, which hid
/// `settings.accounts.highParallelism.toggle` from automation.
final class SettingsHighParallelismAccessibilityTests: XCTestCase {
    func test_highParallelismToggleKeepsItsIdentifierUnderTheAccountsSection() throws {
        let source = try settingsSource()
        let selectedStart = try XCTUnwrap(source.range(of: "private var selectedSection: some View"))
        let start = try XCTUnwrap(
            source.range(of: "case .accounts:", range: selectedStart.upperBound..<source.endIndex)
        )
        let end = try XCTUnwrap(
            source.range(of: "case .fileAccess:", range: start.upperBound..<source.endIndex)
        )
        let section = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            section.contains(".accessibilityElement(children: .contain)\n            .accessibilityIdentifier(\"settings.section.accounts\")"),
            "The accounts section must stay a container element so its controls keep their identifiers."
        )
        XCTAssertEqual(
            source.components(separatedBy: "\"settings.accounts.highParallelism.toggle\"").count - 1,
            1,
            "The high parallelism toggle keeps one automation contract."
        )
        XCTAssertTrue(section.contains("distillHighParallelismSection"))
    }

    private func settingsSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/AppShell/SettingsWindow.swift"),
            encoding: .utf8
        )
    }
}
