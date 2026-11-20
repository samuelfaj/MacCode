import XCTest
@testable import Surfaces
import AgentRuntime
import CoreModel

final class DistillAccountsPanelTests: XCTestCase {
    func test_presentationCarriesAccountIdentityBusyURLAndError() {
        let statuses = DistillAccountProvider.allCases.map {
            DistillAccountStatus(provider: $0, connected: $0 == .grok, email: $0 == .grok ? "user@example.com" : nil)
        }
        let url = URL(string: "https://example.com/login")!
        let presentation = DistillAccountsPanelPresentation(
            statuses: statuses,
            busyProvider: .claude,
            signInURL: url,
            lastError: "Could not sign in"
        )
        XCTAssertEqual(presentation.statuses.first { $0.provider == .grok }?.email, "user@example.com")
        XCTAssertEqual(presentation.busyProvider, .claude)
        XCTAssertEqual(presentation.signInURL, url)
        XCTAssertEqual(presentation.lastError, "Could not sign in")
    }
    func test_namedIdentityAndRouteModelsUseProviderMetadata() throws {
        let accounts: [DistillAccountStatus] = [
            .init(provider: .chatgpt, connected: true, id: "personal", label: "Personal", legacy: false),
            .init(provider: .chatgpt, connected: false, id: "work", label: "Work", legacy: false)
        ]
        let models = [
            AgentModelDescriptor(id: "unrelated-name", label: "Model", provider: .distill, accountProvider: "chatgpt"),
            AgentModelDescriptor(id: "chatgpt-looking", label: "Other", provider: .distill, accountProvider: "claude"),
            AgentModelDescriptor(id: "third-model", label: "Third", provider: .distill, accountProvider: "grok"),
            AgentModelDescriptor(id: "auto", label: "Auto", provider: .distill, accountProvider: "chatgpt")
        ]
        let presentation = DistillAccountsPanelPresentation(statuses: accounts, busyProvider: .chatgpt, signInURL: nil, lastError: nil, busyAccountID: "work")
        XCTAssertEqual(presentation.statuses.map(\.id), ["personal", "work"])
        XCTAssertEqual(presentation.busyAccountID, "work")
        XCTAssertEqual(DistillRoutingValidation.models(for: accounts[1], catalog: models).map(\.id), ["unrelated-name"])
        XCTAssertEqual(DistillRoutingValidation.workerModels(catalog: models).map(\.id), ["unrelated-name", "chatgpt-looking", "third-model"])
        var route = DistillAutoRouting(enabled: true, options: [.init(id: "option", accountID: "work", mainModel: "unrelated-name")])
        XCTAssertNil(DistillRoutingValidation.error(route, saved: .init(), accounts: accounts, models: models))
        route.options[0].workerModel = "chatgpt-looking"
        route.options[0].workerFallbackModel = "third-model"
        XCTAssertNil(DistillRoutingValidation.error(route, saved: .init(), accounts: accounts, models: models))
        let saved = route
        route.options[0].workerModel = "auto"
        XCTAssertEqual(DistillRoutingValidation.error(route, saved: saved, accounts: accounts, models: models),
                       L("Choose an available Worker model or select Same as Main."))
        route.options[0].workerModel = nil
        XCTAssertNil(DistillRoutingValidation.error(route, saved: saved, accounts: accounts, models: models))
        for unavailable in ["auto", "unknown"] {
            route.options[0].workerFallbackModel = unavailable
            XCTAssertEqual(DistillRoutingValidation.error(route, saved: saved, accounts: accounts, models: models),
                           L("Choose an available Worker fallback or select None."))
        }
        route = saved
        route.enabled = false
        XCTAssertNil(DistillRoutingValidation.error(route, saved: saved, accounts: accounts, models: []))
        for ineligible in ["auto", "chatgpt-looking"] {
            route.options[0].mainModel = ineligible
            XCTAssertEqual(DistillRoutingValidation.error(route, saved: saved, accounts: accounts, models: models),
                           L("Choose a Main model from the selected account’s provider."))
        }
        let roundTrip = try JSONDecoder().decode(AgentModelDescriptor.self, from: JSONEncoder().encode(models[0]))
        XCTAssertEqual(roundTrip.accountProvider, "chatgpt")
        XCTAssertNil(try JSONDecoder().decode(AgentModelDescriptor.self, from: Data(#"{"id":"old","label":"Old","provider":"distill"}"#.utf8)).accountProvider)
    }

    func test_quotaUnknownAndStaleAreNotZero() throws {
        XCTAssertEqual(DistillAccountsPanelPresentation.quotaText(nil), "Quota unknown")
        let quota = try JSONDecoder().decode(DistillAccountQuota.self, from: Data(#"{"account_id":"work","checked_at":"2026-10-12T12:00:00Z","fetched_at":"2026-10-12T11:00:00Z","status":"unavailable","remaining_percent":73}"#.utf8))
        let text = DistillAccountsPanelPresentation.quotaText(quota)
        XCTAssertTrue(text.contains("Stale"))
        XCTAssertTrue(text.contains("73%"))
        let updated = try Date("2026-10-12T11:00:00Z", strategy: .iso8601)
        XCTAssertTrue(text.contains(updated.formatted(date: .abbreviated, time: .shortened)))
    }

    func test_fractionalQuotaRequiresFreshConnectedSnapshot() throws {
        let now = try Date("2026-10-12T19:00:00Z", strategy: .iso8601)
        let quota = DistillAccountQuota(accountID: "work", checkedAt: "2026-10-12T18:58:45.174778Z",
                                       fetchedAt: "2026-10-12T18:58:45.174778Z", status: "available", remainingPercent: 73)
        let fresh = DistillAccountsPanelPresentation.quotaPresentation(quota, connected: true, connectionError: nil, now: now)
        XCTAssertEqual(fresh.remainingPercent, 73)
        XCTAssertNil(DistillAccountsPanelPresentation.quotaPresentation(quota, connected: false, connectionError: nil, now: now).remainingPercent)
        let expired = DistillAccountsPanelPresentation.quotaPresentation(quota, connected: true, connectionError: nil, now: now.addingTimeInterval(300))
        XCTAssertNil(expired.remainingPercent)
        XCTAssertTrue(expired.text.hasPrefix("Stale"))
    }

}
