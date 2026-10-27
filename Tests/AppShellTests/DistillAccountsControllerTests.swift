import XCTest
@testable import AppShell
import AgentRuntime
import SocketServer
import CoreModel

@MainActor
final class DistillAccountsControllerTests: XCTestCase {
    private final class Accounts: DistillAccountManaging, @unchecked Sendable {
        var statusesValue = DistillAccountProvider.allCases.map { DistillAccountStatus(provider: $0, connected: false) }
        var loginCount = 0
        var fail = false
        var delay = false

        func statuses() -> [DistillAccountStatus] { statusesValue }
        var routing = DistillAutoRouting()
        var lastID: String?
        var loadContinuation: CheckedContinuation<DistillAccountsState, Error>?
        var holdLoad = false
        var holdSave = false
        var saveCount = 0
        var saveContinuation: CheckedContinuation<Void, Never>?
        func loadState() async throws -> DistillAccountsState {
            if holdLoad { return try await withCheckedThrowingContinuation { loadContinuation = $0 } }
            return .init(accounts: statusesValue, routing: routing)
        }
        func add(id: String, provider: DistillAccountProvider, label: String) async throws {
            lastID = id
            statusesValue.append(.init(provider: provider, connected: false, id: id, label: label, legacy: false))
        }
        func rename(id: String, label: String) async throws { lastID = id }
        func remove(id: String) async throws { lastID = id; statusesValue.removeAll { $0.id == id } }
        func refreshUsage(id: String) async throws -> DistillAccountQuota { lastID = id; throw DistillAccountError.failed("Quota unavailable") }
        func saveRouting(_ routing: DistillAutoRouting) async throws {
            if holdSave { await withCheckedContinuation { saveContinuation = $0 } }
            saveCount += 1
            self.routing = routing
        }
        func login(id: String, onURL: @escaping @Sendable (URL) -> Void) async throws {
            lastID = id
            loginCount += 1
            if delay { try await Task.sleep(nanoseconds: 10_000_000_000) }
            if fail { throw DistillAccountError.failed("login failed") }
            statusesValue = statusesValue.map { $0.id == id ? DistillAccountStatus(provider: $0.provider, connected: true, id: id, label: $0.label, legacy: $0.legacy) : $0 }
        }
        func logout(id: String) async throws {
            lastID = id
            statusesValue = statusesValue.map { $0.id == id ? DistillAccountStatus(provider: $0.provider, connected: false, id: id, label: $0.label, legacy: $0.legacy) : $0 }
        }
    }

    func test_missingDistillInstallsOnceAndRefreshesAfterSuccess() async {
        var installerCalls = 0
        var refreshCalls = 0
        let controller = DistillAccountsController(
            accounts: Accounts(),
            installer: { installerCalls += 1; return "/tmp/distill" },
            resolveBinary: { nil },
            didChange: { _, succeeded in if succeeded { refreshCalls += 1 } }
        )
        controller.ensureDistillInstalled()
        XCTAssertEqual(controller.installState, .installing)
        for _ in 0..<100 where controller.installState == .installing {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.installState, .installed)
        XCTAssertEqual(installerCalls, 1)
        XCTAssertEqual(refreshCalls, 1)
    }

    func test_installIsSingleFlightWhileInstallerWaits() async {
        let entered = expectation(description: "installer started off the main actor")
        let semaphore = DispatchSemaphore(value: 0)
        var installerCalls = 0
        defer { semaphore.signal() }
        let controller = DistillAccountsController(
            accounts: Accounts(),
            installer: {
                installerCalls += 1
                entered.fulfill()
                semaphore.wait()
                return "/tmp/distill"
            },
            resolveBinary: { nil }
        )
        controller.ensureDistillInstalled()
        controller.ensureDistillInstalled()
        controller.ensureDistillInstalled()
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(controller.installState, .installing)
        XCTAssertEqual(installerCalls, 1)
    }

    func test_installFailureShowsOfficialCommandAndRetryRunsInstallerAgain() async {
        var installerCalls = 0
        let controller = DistillAccountsController(
            accounts: Accounts(),
            installer: {
                installerCalls += 1
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network unavailable"])
            },
            resolveBinary: { nil }
        )
        controller.ensureDistillInstalled()
        for _ in 0..<100 where controller.installState == .installing {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .failed(let message) = controller.installState else { return XCTFail("expected failed state") }
        XCTAssertTrue(message.contains(DistillProvisioner.installPlan().commandLine))
        controller.retryDistillInstall()
        for _ in 0..<100 where controller.installState == .installing {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(installerCalls, 2)
    }

    func test_alreadyInstalledSkipsInstaller() {
        var installerCalls = 0
        let controller = DistillAccountsController(
            accounts: Accounts(),
            installer: { installerCalls += 1; return "/tmp/distill" },
            resolveBinary: { "/tmp/distill" }
        )
        controller.ensureDistillInstalled()
        XCTAssertEqual(controller.installState, .installed)
        XCTAssertEqual(installerCalls, 0)
    }

    func test_loginAllowsOnlyOneOperationAndCancelClearsBusyState() async {
        let accounts = Accounts()
        accounts.delay = true
        let controller = DistillAccountsController(accounts: accounts)
        controller.login(.grok)
        XCTAssertEqual(controller.busyProvider, .grok)
        for _ in 0..<50 where accounts.loginCount == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        controller.login(.claude)
        XCTAssertEqual(accounts.loginCount, 1)
        controller.cancel()
        XCTAssertNil(controller.busyProvider)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(controller.busyProvider)
    }

    func test_loginSuccessRefreshesStatusAndPublishesProviderUpdate() async throws {
        let accounts = Accounts()
        let providerEvents = expectation(description: "agent.provider.updated carries account operation start, refresh, and end")
        providerEvents.expectedFulfillmentCount = 3
        let eventToken = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.provider.updated",
                  event.payload.objectValue?["provider"] == .string("claude") else { return }
            providerEvents.fulfill()
        }
        defer { EventBus.shared.unsubscribe(eventToken) }
        var successfulRefreshes = 0
        let controller = DistillAccountsController(accounts: accounts) { _, succeeded in
            if succeeded { successfulRefreshes += 1 }
        }
        controller.login(.claude)
        for _ in 0..<50 where controller.busyProvider != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(controller.busyProvider)
        XCTAssertEqual(controller.statuses.first { $0.provider == .claude }?.connected, true)
        XCTAssertEqual(successfulRefreshes, 1)
        await fulfillment(of: [providerEvents], timeout: 2)
    }

    func test_loginFailureSurfacesErrorAndClearsBusyState() async throws {
        let accounts = Accounts()
        accounts.fail = true
        let controller = DistillAccountsController(accounts: accounts)
        controller.login(.grok)
        for _ in 0..<50 where controller.busyProvider != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.lastError, "login failed")
        XCTAssertNil(controller.busyProvider)
    }
    func test_namedRowsUseExactIDAndRejectLateRefreshAfterCancel() async throws {
        let accounts = Accounts()
        accounts.statusesValue = [
            .init(provider: .chatgpt, connected: false, id: "first", label: "Personal", legacy: false),
            .init(provider: .chatgpt, connected: false, id: "second", label: "Work", legacy: false)
        ]
        let controller = DistillAccountsController(accounts: accounts)
        controller.login(accountID: "second")
        XCTAssertEqual(controller.busyAccountID, "second")
        for _ in 0..<50 where controller.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(accounts.lastID, "second")
        XCTAssertFalse(controller.statuses[0].connected)
        XCTAssertTrue(controller.statuses[1].connected)
        accounts.holdLoad = true
        controller.refresh()
        for _ in 0..<50 where accounts.loadContinuation == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let late = accounts.loadContinuation
        accounts.holdLoad = false
        accounts.delay = true
        controller.login(accountID: "first")
        controller.cancel()
        late?.resume(returning: .init(accounts: [], routing: .init(enabled: true)))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.statuses.count, 2)
        XCTAssertFalse(controller.routing.enabled)
        XCTAssertFalse(controller.isBusy)
    }

    func test_addGeneratesNamedIDAndQuotaFailureKeepsIdentity() async throws {
        let accounts = Accounts()
        let controller = DistillAccountsController(accounts: accounts)
        controller.add(provider: .claude, label: "Work")
        XCTAssertTrue(controller.isBusy)
        for _ in 0..<50 where controller.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        let id = try XCTUnwrap(accounts.lastID)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(controller.statuses.last?.label, "Work")
        controller.refreshUsage(accountID: id)
        XCTAssertEqual(controller.busyAccountID, id)
        for _ in 0..<50 where controller.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.lastError, "Quota unavailable")
        XCTAssertFalse(controller.isBusy)
    }

    func test_routingSaveStaysBusyWithoutAccountUntilAuthoritativeRefresh() async throws {
        let accounts = Accounts()
        accounts.holdSave = true
        let controller = DistillAccountsController(accounts: accounts)
        await controller.refreshAndWait()
        _ = await controller.discoverModels {
            [AgentModelDescriptor(id: "discovered", label: "Discovered", provider: .distill, accountProvider: "chatgpt")]
        }
        let draft = DistillAutoRouting(enabled: true, options: [.init(id: "option", accountID: "legacy-chatgpt", mainModel: "discovered")])
        var invalid = draft
        invalid.options[0].mainModel = "auto"
        controller.saveRouting(invalid)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNotNil(controller.lastError)
        XCTAssertNil(accounts.saveContinuation)
        controller.saveRouting(draft)
        XCTAssertTrue(controller.isBusy)
        XCTAssertNil(controller.busyAccountID)
        XCTAssertNil(controller.busyProvider)
        XCTAssertFalse(controller.routing.enabled)
        for _ in 0..<50 where accounts.saveContinuation == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        accounts.saveContinuation?.resume()
        for _ in 0..<50 where controller.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.routing, draft)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.lastError)
    }

    // The Auto profile is shared; tapping Auto must turn it on without a guide round trip.
    func test_enableAutoSavesEnabledProfileWithSavedOptions() async {
        let accounts = Accounts()
        accounts.routing = DistillAutoRouting(enabled: false, options: [.init(id: "option", accountID: "legacy-chatgpt", mainModel: "m")])
        let controller = DistillAccountsController(accounts: accounts)
        let enabled = await controller.enableAuto()
        XCTAssertTrue(enabled)
        XCTAssertEqual(accounts.saveCount, 1)
        XCTAssertTrue(accounts.routing.enabled)
        XCTAssertEqual(accounts.routing.options.count, 1)
        XCTAssertTrue(controller.routing.enabled)
        XCTAssertFalse(controller.isBusy)
    }

    // Without options there is nothing to enable; the caller must open the guide instead.
    func test_enableAutoWithoutOptionsReturnsFalseAndDoesNotSave() async {
        let accounts = Accounts()
        let controller = DistillAccountsController(accounts: accounts)
        let enabled = await controller.enableAuto()
        XCTAssertFalse(enabled)
        XCTAssertEqual(accounts.saveCount, 0)
        XCTAssertFalse(accounts.routing.enabled)
    }

    // Tapping Auto when the profile is already on must not rewrite the shared accounts file.
    func test_enableAutoWhenAlreadyEnabledReturnsTrueWithoutSaving() async {
        let accounts = Accounts()
        accounts.routing = DistillAutoRouting(enabled: true, options: [.init(id: "option", accountID: "legacy-chatgpt", mainModel: "m")])
        let controller = DistillAccountsController(accounts: accounts)
        let enabled = await controller.enableAuto()
        XCTAssertTrue(enabled)
        XCTAssertEqual(accounts.saveCount, 0)
    }
}
