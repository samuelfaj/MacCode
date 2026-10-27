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

    private func ready(loaded: Bool = true, busy: Bool = false, hasChanges: Bool = false,
                      routing: DistillAutoRouting? = nil, statuses: [DistillAccountStatus]? = nil,
                      validationError: String? = nil, refreshing: Bool = false,
                      stateError: String? = nil) -> Bool {
        DistillAutoUsePolicy.isReady(
            loaded: loaded, busy: busy, hasChanges: hasChanges,
            routing: routing ?? self.routing, statuses: statuses ?? self.statuses,
            validationError: validationError, refreshing: refreshing, stateError: stateError
        )
    }

    func test_readinessRequiresSavedEnabledRouteAndConnectedReferencedAccount() {
        XCTAssertTrue(ready())
        XCTAssertFalse(ready(routing: DistillAutoRouting(enabled: false, options: routing.options)))
        XCTAssertFalse(ready(routing: DistillAutoRouting(enabled: true)))
        XCTAssertFalse(ready(statuses: [DistillAccountStatus(provider: .grok, connected: false, id: "connected")]))
        XCTAssertFalse(ready(statuses: [DistillAccountStatus(provider: .grok, connected: true, id: "other")]))
        let saved = routing
        XCTAssertTrue(ready())
        XCTAssertEqual(routing.options.map(\.id), saved.options.map(\.id), "readiness check must not mutate profile option IDs")
    }

    func test_readinessRejectsUnsavedBusyLoadingRefreshingAndErrors() {
        XCTAssertFalse(ready(loaded: false))
        XCTAssertFalse(ready(busy: true))
        XCTAssertFalse(ready(hasChanges: true), "failed save remains dirty and cannot invoke Use Auto")
        XCTAssertFalse(ready(hasChanges: true, validationError: "invalid"))
        XCTAssertFalse(ready(refreshing: true))
        XCTAssertFalse(ready(stateError: "unavailable"))
        XCTAssertFalse(ready(validationError: "invalid"))
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

    func test_sourceContractsGuardUseAutoAndOpenGuideBeforeSelectingAuto() throws {
        let guide = try source("Sources/AppShell/DistillAutoGuideSheet.swift")
        let button = try XCTUnwrap(guide.range(of: "Button(\"Use Auto\")"))
        let buttonBody = String(guide[button.lowerBound...]).prefix(180)
        XCTAssertTrue(buttonBody.contains("guard canUseAuto else { return }"))
        XCTAssertTrue(buttonBody.range(of: "guard canUseAuto")!.lowerBound < buttonBody.range(of: "onUseAuto()")!.lowerBound)
        XCTAssertTrue(guide.contains("Button(\"Save\") { controller.saveRouting(current) }"))
        XCTAssertTrue(guide.contains(".task { controller.refresh() }"),
                      "opening after a rejected Auto send must recheck the saved profile, including previously loaded state")
        XCTAssertTrue(guide.contains("Button(\"Retry\") { controller.refresh() }"),
                      "guide must offer explicit retry for a state error")
        XCTAssertTrue(guide.contains("agent.autoGuide.retry"))
        XCTAssertTrue(guide.contains("if let stateError = controller.stateError"))

        let picker = try source("Sources/Surfaces/AgentModelPopover.swift")
        let selector = try XCTUnwrap(picker.range(of: "private func selectAuto()"))
        let selectionBody = String(picker[selector.lowerBound...]).prefix(260)
        XCTAssertTrue(selectionBody.range(of: "showingAutoGuide = true")!.lowerBound < selectionBody.range(of: "onSelectMainModel(\"auto\")")!.lowerBound)
        let guideInvocation = try XCTUnwrap(picker.range(of: "makeGuide(close, isDisabled ? nil"))
        XCTAssertTrue(String(picker[guideInvocation.lowerBound...]).prefix(140).contains("isDisabled ? nil"))
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
