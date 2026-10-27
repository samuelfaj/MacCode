import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Surfaces

final class DistillAutoGuideReadinessTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var routing: DistillAutoRouting {
        DistillAutoRouting(enabled: true, options: [DistillAutoOption(id: "option", accountID: "connected", mainModel: "grok")])
    }

    private var statuses: [DistillAccountStatus] {
        [DistillAccountStatus(provider: .grok, connected: true, id: "connected")]
    }

    func test_autoOptionVisibilityIncludesSetupAndRetainsSelectedAuto() throws {
        XCTAssertTrue(AgentDistillModelCatalog.shouldShowAutoOption(setupAvailable: true, catalogHasAuto: false, selectedAuto: false))
        XCTAssertTrue(AgentDistillModelCatalog.shouldShowAutoOption(setupAvailable: false, catalogHasAuto: false, selectedAuto: true))
        let picker = try source("Sources/Surfaces/AgentModelPopover.swift")
        let catalogFlag = try XCTUnwrap(picker.range(of: "private var catalogAdvertisesAuto"))
        let catalogBody = String(picker[catalogFlag.lowerBound...]).prefix(140)
        XCTAssertTrue(catalogBody.contains("mainModels.contains(where: { $0.id == \"auto\" })"))
        XCTAssertFalse(catalogBody.contains("mainModel == \"auto\""))
        XCTAssertTrue(AgentDistillModelCatalog.shouldShowAutoOption(setupAvailable: false, catalogHasAuto: true, selectedAuto: false))
        XCTAssertFalse(AgentDistillModelCatalog.shouldShowAutoOption(setupAvailable: false, catalogHasAuto: false, selectedAuto: false))
    }

    func test_sourceContractsSelectAutoOnTapWithoutSecondConfirmation() throws {
        let guide = try source("Sources/AppShell/DistillAutoGuideSheet.swift")
        XCTAssertFalse(guide.contains("Use Auto"), "tapping the Auto card already chose Auto; the guide must not ask again")
        XCTAssertTrue(guide.contains("Button(\"Save\") { controller.saveRouting(current) }"))
        XCTAssertTrue(guide.contains(".task { controller.refresh() }"),
                      "opening after a rejected Auto send must recheck the saved profile, including previously loaded state")
        XCTAssertTrue(guide.contains("Button(\"Retry\") { controller.refresh() }"),
                      "guide must offer explicit retry for a state error")

        let picker = try source("Sources/Surfaces/AgentModelPopover.swift")
        let selector = try XCTUnwrap(picker.range(of: "private func selectAuto()"))
        let body = String(picker[selector.lowerBound...]).prefix(700)
        XCTAssertTrue(body.range(of: "onSelectMainModel(\"auto\")")!.lowerBound < body.range(of: "showingAutoGuide = true")!.lowerBound,
                      "Auto must be selected before any guide opens")
        XCTAssertTrue(body.contains("if catalogAdvertisesAuto"), "a ready profile closes the picker instead of opening the guide")
        XCTAssertTrue(body.contains("AgentAutoGuide.enableProfile"), "tapping Auto turns the shared profile on before any guide opens")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
