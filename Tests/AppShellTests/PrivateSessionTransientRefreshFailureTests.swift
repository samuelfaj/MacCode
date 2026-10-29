import CoreModel
import Foundation
import SocketServer
import XCTest
@testable import AppShell

/// WHY: clearing the stored account session stops the relay host client from
/// authenticating, turns push delivery into `no_session`, and nothing restores
/// it except a manual sign-in on the Mac.
/// A failed token refresh that is not the backend's auth rejection (offline,
/// timeout, 5xx, 429, decode error) must therefore keep the session; only a
/// 401 from the refresh endpoint ends it.
@MainActor
final class PrivateSessionTransientRefreshFailureTests: XCTestCase {
    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    func testPush401ThenOfflineRefreshKeepsSession() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let api = ScriptedPrivateAccountAPI(
            rejectedAccessTokens: [Self.session.accessToken],
            refreshError: URLError(.notConnectedToInternet)
        )
        let bridge = try makeBridge(context: ctx, accountStore: accountStore, api: api)
        let content = try outcomeContent()
        await bridge.deliver(content)

        XCTAssertGreaterThanOrEqual(api.refreshCallCount, 1, "fixture: the 401 must have reached the refresh path")
        XCTAssertEqual(accountStore.load(), Self.session,
                       "an offline refresh is not a sign-out: the session must survive for the next attempt")
    }

    func testPush401ThenNonAuthRefreshFailureKeepsSession() async throws {
        // 403 is included on purpose: on the refresh endpoint only 401 is the
        // backend's auth rejection.
        let failures: [PrivateAccountAPIError] = [.http(503), .http(429), .http(403), .invalidResponse]
        for failure in failures {
            let ctx = try makeContext()
            let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
            let api = ScriptedPrivateAccountAPI(
                rejectedAccessTokens: [Self.session.accessToken],
                refreshError: failure
            )
            let bridge = try makeBridge(context: ctx, accountStore: accountStore, api: api)

            let content = try outcomeContent()
            await bridge.deliver(content)

            XCTAssertGreaterThanOrEqual(api.refreshCallCount, 1, "fixture: refresh must have been attempted for \(failure)")
            XCTAssertEqual(accountStore.load(), Self.session,
                           "a refresh that fails with \(failure) must keep the session for the next attempt")
        }
    }

    /// Guard against over-fixing: the backend's auth rejection still ends the session.
    func testRefreshRejectedWith401StillSignsOut() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let api = ScriptedPrivateAccountAPI(
            rejectedAccessTokens: [Self.session.accessToken],
            refreshError: PrivateAccountAPIError.http(401)
        )
        let bridge = try makeBridge(context: ctx, accountStore: accountStore, api: api)

        let content = try outcomeContent()
        await bridge.deliver(content)

        XCTAssertNil(accountStore.load(), "a refresh token the backend rejects is an unusable session and must be cleared")
        XCTAssertEqual(api.refreshCallCount, 1, "a cleared session must not be refreshed again by the silent fallback")
    }

    func testFailedRefreshAdoptsSessionStoredMeanwhile() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let newer = PrivateAccountSession(
            accessToken: "newer-access-token",
            refreshToken: "newer-refresh-token",
            user: Self.session.user
        )
        // Another writer (the Settings refresh) stores a newer session while
        // this refresh is in flight; the stale refresh token is then rejected.
        let api = ScriptedPrivateAccountAPI(
            rejectedAccessTokens: [Self.session.accessToken],
            refreshError: PrivateAccountAPIError.http(401),
            beforeRefreshFails: { _ = accountStore.save(newer) }
        )
        let bridge = try makeBridge(context: ctx, accountStore: accountStore, api: api)

        let content = try outcomeContent()
        await bridge.deliver(content)

        XCTAssertEqual(accountStore.load(), newer,
                       "a stale refresh failure must not sign out a session another writer just renewed")
        XCTAssertEqual(
            api.alertAttempts.filter { !$0.silent }.map(\.accessToken),
            [Self.session.accessToken, newer.accessToken],
            "the alert must be retried once with the newer session instead of being dropped"
        )
        XCTAssertEqual(api.refreshCallCount, 1)
    }

    /// Each clear posts `.rc2PrivateAccountChanged`, and each post makes the
    /// app reconnect the relay host client.
    /// A refresh rejected after the user already disconnected must not clear
    /// and notify a second time.
    func testRefreshRejectedAfterDisconnectDoesNotClearAgain() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        // The user presses Disconnect while this refresh is in flight; the
        // refresh token is then rejected.
        let api = ScriptedPrivateAccountAPI(
            rejectedAccessTokens: [Self.session.accessToken],
            refreshError: PrivateAccountAPIError.http(401),
            beforeRefreshFails: { _ = accountStore.clear() }
        )
        let bridge = try makeBridge(context: ctx, accountStore: accountStore, api: api)
        // Installed after makeBridge: its fixture save posts as well.
        let posts = AccountChangePostCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .rc2PrivateAccountChanged, object: nil, queue: nil
        ) { _ in posts.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        let content = try outcomeContent()
        await bridge.deliver(content)
        // Clears made off the main thread post through the main queue: let
        // every post queued so far land before counting.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(api.refreshCallCount, 1, "fixture: the 401 must have reached the refresh path once")
        XCTAssertNil(accountStore.load(), "the disconnect must stand")
        XCTAssertEqual(posts.value, 1,
                       "only the disconnect may notify: a refresh rejected afterwards must not clear the session again")
    }

    func testSettingsRefreshWhileOfflineKeepsSession() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        XCTAssertTrue(accountStore.save(Self.session), "fixture: the panel must start signed in")
        let api = ScriptedPrivateAccountAPI(
            currentUserError: URLError(.notConnectedToInternet),
            refreshError: URLError(.notConnectedToInternet)
        )
        let vm = SettingsViewModel(context: ctx, privateAccountAPI: api)

        await vm.refreshPrivateAccount()

        XCTAssertEqual(api.refreshCallCount, 1, "fixture: the refresh fallback must have run")
        XCTAssertEqual(accountStore.load(), Self.session,
                       "pressing Refresh while offline must not sign the Mac out")
        XCTAssertEqual(vm.privateAccountUser, Self.session.user, "the panel must stay signed in")
        XCTAssertEqual(vm.privateAccountStatus, "No internet connection",
                       "the status must name the transient failure instead of 'Session expired'")
    }

    /// Guard against over-fixing: a rejected refresh token still signs out.
    func testSettingsRefreshRejectedWith401SignsOut() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        XCTAssertTrue(accountStore.save(Self.session), "fixture: the panel must start signed in")
        let api = ScriptedPrivateAccountAPI(
            currentUserError: PrivateAccountAPIError.http(401),
            refreshError: PrivateAccountAPIError.http(401)
        )
        let vm = SettingsViewModel(context: ctx, privateAccountAPI: api)

        await vm.refreshPrivateAccount()

        // No await below: the store's change notification schedules reload(),
        // which repaints the status as "Optional" once the main actor yields.
        XCTAssertNil(accountStore.load(), "a refresh token the backend rejects must clear the session")
        XCTAssertNil(vm.privateAccountUser)
        XCTAssertEqual(vm.privateAccountStatus, "Session expired")
    }

    func testSettingsRefreshFailureAdoptsSessionStoredMeanwhile() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        XCTAssertTrue(accountStore.save(Self.session), "fixture: the panel must start signed in")
        let newer = PrivateAccountSession(
            accessToken: "newer-access-token",
            refreshToken: "newer-refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "renewed@example.com",
                id: Self.session.user.id,
                subscribed: true
            )
        )
        // The push refresher renews the session while the Settings refresh is
        // in flight; the stale refresh token is then rejected.
        let api = ScriptedPrivateAccountAPI(
            currentUserError: PrivateAccountAPIError.http(401),
            refreshError: PrivateAccountAPIError.http(401),
            beforeRefreshFails: { _ = accountStore.save(newer) }
        )
        let vm = SettingsViewModel(context: ctx, privateAccountAPI: api)

        await vm.refreshPrivateAccount()

        XCTAssertEqual(accountStore.load(), newer,
                       "a stale refresh failure must not sign out a session the push refresher just renewed")
        XCTAssertEqual(vm.privateAccountUser, newer.user)
        XCTAssertEqual(vm.privateAccountEmail, "renewed@example.com")
        XCTAssertEqual(vm.privateAccountStatus, "Subscription active")
    }

    /// WHY: the relay host socket is the only consumer of the access token
    /// while no push is sent. Without a refresh on the relay's 401 the Mac
    /// retried the expired token forever and phones could not reach it.
    func testRelayRejectedTokenIsRenewedAndStored() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let renewed = PrivateAccountSession(
            accessToken: "renewed-access-token", refreshToken: "renewed-refresh-token", user: Self.session.user
        )
        let api = ScriptedPrivateAccountAPI(refreshError: PrivateAccountAPIError.invalidResponse, refreshedSession: renewed)
        let bridge = try makeBridge(context: ctx, accountStore: accountStore, api: api)

        await bridge.refreshRejectedAccessToken(Self.session.accessToken)

        XCTAssertEqual(api.refreshCallCount, 1)
        XCTAssertEqual(accountStore.load(), renewed, "the relay's next attempt must read the renewed token")
    }

    func testRelayRejectionOfAnOlderTokenDoesNotRefreshAgain() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let api = ScriptedPrivateAccountAPI(refreshError: PrivateAccountAPIError.http(401))
        let bridge = try makeBridge(context: ctx, accountStore: accountStore, api: api)

        await bridge.refreshRejectedAccessToken("token-already-replaced")

        XCTAssertEqual(api.refreshCallCount, 0, "a newer stored token is used as is, without spending the refresh token")
        XCTAssertEqual(accountStore.load(), Self.session)
    }

    func testRelayRejectedTokenWithTransientRefreshFailureKeepsSession() async throws {
        let ctx = try makeContext()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let api = ScriptedPrivateAccountAPI(refreshError: URLError(.notConnectedToInternet))
        let bridge = try makeBridge(context: ctx, accountStore: accountStore, api: api)

        await bridge.refreshRejectedAccessToken(Self.session.accessToken)

        XCTAssertEqual(api.refreshCallCount, 1)
        XCTAssertEqual(accountStore.load(), Self.session, "an offline refresh keeps the session for the next relay attempt")
    }

    private func makeContext() throws -> AppContext {
        let directory = NSTemporaryDirectory() + "RC2PrivateTransientRefresh-" + UUID().uuidString
        directories.append(directory)
        return try AppContext(channel: .debug, appSupportOverride: directory)
    }

    private func makeBridge(
        context: AppContext,
        accountStore: PrivateAccountSessionStore,
        api: PrivateAccountAPI
    ) throws -> PrivateNotificationBridge {
        XCTAssertTrue(accountStore.save(Self.session), "fixture: the Mac must start signed in")
        let targetStore = PrivatePushTargetStore(repo: context.settingsRepo)
        try targetStore.save(
            pushToken: "apns-token", pushTokenType: "apns",
            liveActivityToken: nil, deviceId: "device-1"
        )
        return PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)
    }

    private func outcomeContent() throws -> RemoteCodeNotificationContent {
        try XCTUnwrap(RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-1", title: "Done", phase: .completed
        ))
    }

    private static let session = PrivateAccountSession(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        user: PrivateAccountUser(
            daysRemaing: nil,
            daysRemaining: 30,
            email: "subscriber@example.com",
            id: "account-1",
            subscribed: true
        )
    )
}

private final class AccountChangePostCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// Every push with a rejected access token answers 401, and `refresh` always
/// fails with the scripted error. Methods these tests do not reach throw.
private final class ScriptedPrivateAccountAPI: PrivateAccountAPI, @unchecked Sendable {
    struct AlertAttempt: Equatable {
        let accessToken: String
        let silent: Bool
    }

    private let lock = NSLock()
    private let rejectedAccessTokens: Set<String>
    private let currentUserError: Error
    private let refreshError: Error
    private let beforeRefreshFails: (@Sendable () -> Void)?
    private let refreshedSession: PrivateAccountSession?
    private var alerts: [AlertAttempt] = []
    private var refreshCount = 0

    var alertAttempts: [AlertAttempt] { lock.withLock { alerts } }
    var refreshCallCount: Int { lock.withLock { refreshCount } }

    init(
        rejectedAccessTokens: Set<String> = [],
        currentUserError: Error = PrivateAccountAPIError.invalidResponse,
        refreshError: Error,
        beforeRefreshFails: (@Sendable () -> Void)? = nil,
        refreshedSession: PrivateAccountSession? = nil
    ) {
        self.refreshedSession = refreshedSession
        self.rejectedAccessTokens = rejectedAccessTokens
        self.currentUserError = currentUserError
        self.refreshError = refreshError
        self.beforeRefreshFails = beforeRefreshFails
    }

    func login(email: String, password: String) async throws -> PrivateAccountSession {
        throw PrivateAccountAPIError.invalidResponse
    }

    func currentUser(accessToken: String) async throws -> PrivateAccountUser {
        throw currentUserError
    }

    func refresh(refreshToken: String) async throws -> PrivateAccountSession {
        lock.withLock { refreshCount += 1 }
        if let refreshedSession { return refreshedSession }
        beforeRefreshFails?()
        throw refreshError
    }

    func logout(refreshToken: String) async throws {
        throw PrivateAccountAPIError.invalidResponse
    }

    func billingOverview(accessToken: String) async throws -> PrivateBillingOverview {
        throw PrivateAccountAPIError.invalidResponse
    }

    func createPortal(accessToken: String) async throws -> URL {
        throw PrivateAccountAPIError.invalidResponse
    }

    func deliverAlert(
        accessToken: String,
        title: String,
        body: String,
        data: [String: String],
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String,
        silent: Bool
    ) async throws -> PrivatePushDeliveryResult {
        lock.withLock { alerts.append(AlertAttempt(accessToken: accessToken, silent: silent)) }
        if rejectedAccessTokens.contains(accessToken) {
            throw PrivateAccountAPIError.http(401)
        }
        return PrivatePushDeliveryResult(delivered: true, errorCode: nil, shouldDropSubscription: false)
    }

    func deliverLiveActivity(
        accessToken: String,
        event: String,
        contentState: PrivateLiveActivityContentState,
        timestampSeconds: Int64,
        liveActivityToken: String,
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String
    ) async throws -> PrivatePushDeliveryResult {
        throw PrivateAccountAPIError.invalidResponse
    }
}
