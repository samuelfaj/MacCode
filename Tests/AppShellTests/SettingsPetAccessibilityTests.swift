import XCTest

/// Source contract for a SwiftUI accessibility propagation trap verified in the
/// packaged app: an identifier on the Pet section container replaced every
/// child control identifier in the runtime AX tree.
final class SettingsPetAccessibilityTests: XCTestCase {
    func test_petControlsKeepDistinctAccessibilityIdentifiers() throws {
        let source = try settingsSource()
        let start = try XCTUnwrap(source.range(of: "private var petSection: some View"))
        let end = try XCTUnwrap(source.range(of: "private var insomniaSection: some View"))
        let section = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            section.contains("DSSectionHeaderG(L(\"Desktop Pet\"))\n                .accessibilityIdentifier(\"settings.pet.section\")"),
            "The section identifier must live on the heading leaf so it cannot replace child control identifiers."
        )
        XCTAssertFalse(
            section.contains(".dsPanel(padding: DS.Space.lg)\n        .accessibilityIdentifier(\"settings.pet.section\")"),
            "A container-level Pet section identifier propagates over every child in the packaged app's accessibility tree."
        )

        let expectedControlIdentifiers = [
            "settings.pet.enabled.toggle",
            "settings.pet.animations.toggle",
            "settings.pet.counter.toggle",
            "settings.pet.reduceMotion.toggle",
            "settings.pet.position.picker",
            "settings.pet.size.picker",
            "settings.pet.filter.picker",
            "settings.pet.resetPosition",
        ]
        for identifier in expectedControlIdentifiers {
            XCTAssertEqual(
                section.components(separatedBy: "\"\(identifier)\"").count - 1,
                1,
                "Pet control '\(identifier)' must remain a unique automation contract."
            )
        }
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
