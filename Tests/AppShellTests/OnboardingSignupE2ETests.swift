import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence

/// WHY: setup's "Create account" is the only way a new Mac user gets an account.
/// In production the backend refused every sign-up with a 409 and the app told
/// each new user "An account with this email already exists", so nobody could
/// sign up and nobody noticed. These tests drive the real view model through the
/// real HTTP client so that regression fails here.
@MainActor
final class OnboardingSignupE2ETests: XCTestCase {
    private final class Accounts: DistillAccountManaging, @unchecked Sendable {
        func statuses() -> [DistillAccountStatus] { [] }
        func loadState() async throws -> DistillAccountsState { .init(accounts: [], routing: DistillAutoRouting()) }
        func add(id: String, provider: DistillAccountProvider, label: String) async throws {}
        func rename(id: String, label: String) async throws {}
        func remove(id: String) async throws {}
        func login(id: String, onURL: @escaping @Sendable (URL) -> Void) async throws {}
        func logout(id: String) async throws {}
        func refreshUsage(id: String) async throws -> DistillAccountQuota { throw DistillAccountError.failed("n/a") }
        func saveRouting(_ routing: DistillAutoRouting) async throws {}
    }

    /// Account calls go through `URLSessionPrivateAccountAPI` exactly like
    /// `OnboardingLiveServices`; everything else is inert.
    private final class HTTPServices: OnboardingServices {
        let api: URLSessionPrivateAccountAPI
        let accountsController = DistillAccountsController(accounts: Accounts(), installer: { "/tmp/distill" }, resolveBinary: { "/tmp/distill" })
        var sessions: [PrivateAccountSession] = []

        init(api: URLSessionPrivateAccountAPI) { self.api = api }
        func loadModels() async -> [AgentModelDescriptor] { [] }
        func signIn(email: String, password: String) async throws -> PrivateAccountUser {
            let session = try await api.login(email: email, password: password)
            sessions.append(session)
            return session.user
        }
        func register(email: String, password: String) async throws -> PrivateAccountUser {
            let session = try await api.register(email: email, password: password)
            sessions.append(session)
            return session.user
        }
        func signedInUser() -> PrivateAccountUser? { nil }
        func workspaceExists(_ id: WorkspaceID) -> Bool { false }
        func botExists(_ id: BotID) -> Bool { false }
        func openWorkspace(folder: URL) throws -> WorkspaceID { WorkspaceID() }
        func createDeveloper(name: String, workspace: WorkspaceID) throws -> BotID { BotID() }
        func bindDeveloper(_ bot: BotID, workspace: WorkspaceID) throws {}
        func handOff(workspace: WorkspaceID, developer: BotID?, prompt: String) {}
        func openInBrowser(_ url: URL) {}
    }

    private func makeStore() throws -> OnboardingStateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.path).run()
        return OnboardingStateStore(repo: SettingsRepository(db: db))
    }

    private func makeViewModel(_ services: HTTPServices, email: String, password: String) throws -> OnboardingViewModel {
        var state = OnboardingState(); state.step = .account
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        vm.creatingAccount = true
        vm.email = email
        vm.password = password
        return vm
    }

    // MARK: Stubbed backend (always runs)

    private func stubbedAPI(status: Int, body: String) -> URLSessionPrivateAccountAPI {
        SignupStubProtocol.set(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignupStubProtocol.self]
        return URLSessionPrivateAccountAPI(baseURL: URL(string: "https://private.example.test")!, session: URLSession(configuration: configuration))
    }

    func test_signupSucceedsAndLeavesAccountStep() async throws {
        let api = stubbedAPI(status: 200, body: #"{"accessToken":"a","refreshToken":"r","user":{"id":"u1","email":"new@example.com","subscribed":false,"daysRemaining":0}}"#)
        let vm = try makeViewModel(HTTPServices(api: api), email: "new@example.com", password: "supersecret")
        await vm.submitAccount()
        XCTAssertNil(vm.accountError)
        XCTAssertEqual(vm.signedInEmail, "new@example.com")
        XCTAssertNotEqual(vm.state.step, .account)
        XCTAssertEqual(SignupStubProtocol.lastPath, "/v1/private/auth/register")
    }

    func test_duplicateEmailConflictPointsToSignIn() async throws {
        let api = stubbedAPI(status: 409, body: #"{"code":"email_already_registered","error":"An account with this email already exists."}"#)
        let vm = try makeViewModel(HTTPServices(api: api), email: "taken@example.com", password: "supersecret")
        await vm.submitAccount()
        XCTAssertEqual(vm.accountError, "An account with this email already exists. Sign in instead.")
        XCTAssertEqual(vm.state.step, .account)
    }

    // The production bug: a 409 that is not a duplicate email must never tell a
    // new user their account already exists.
    func test_otherConflictNeverClaimsTheEmailExists() async throws {
        let api = stubbedAPI(status: 409, body: #"{"code":"direct_registration_disabled","error":"Start your trial before creating a new account."}"#)
        let vm = try makeViewModel(HTTPServices(api: api), email: "new@example.com", password: "supersecret")
        await vm.submitAccount()
        XCTAssertEqual(vm.accountError, "Account could not be created right now. Try again shortly.")
        XCTAssertEqual(vm.state.step, .account)
    }

    // MARK: Real backend (RC_PRIVATE_BACKEND_URL)

    /// Sign up, sign in with the same password, a second sign-up gets the
    /// duplicate message, then the account is deleted so nothing is left behind.
    /// Run against a local backend (`bun run e2e:private-backend` → http://127.0.0.1:8787)
    /// or production (https://private.remotecode.io).
    func test_liveBackend_signupSigninDuplicateAndDelete() async throws {
        guard let raw = ProcessInfo.processInfo.environment["RC_PRIVATE_BACKEND_URL"], let baseURL = URL(string: raw) else {
            throw XCTSkip("set RC_PRIVATE_BACKEND_URL to run the sign-up flow against a real backend")
        }
        let api = URLSessionPrivateAccountAPI(baseURL: baseURL, session: URLSession(configuration: .ephemeral))
        let email = "mac-signup-e2e+\(UUID().uuidString.prefix(8).lowercased())@remotecode.io"
        let password = "mac-e2e-\(UUID().uuidString.prefix(12))"

        let services = HTTPServices(api: api)
        let signup = try makeViewModel(services, email: email, password: password)
        await signup.submitAccount()
        XCTAssertNil(signup.accountError, "A brand-new email must be able to sign up")
        XCTAssertEqual(signup.signedInEmail, email)
        let session = try XCTUnwrap(services.sessions.last)
        addTeardownBlock { try? await Self.deleteAccount(baseURL: baseURL, accessToken: session.accessToken) }

        let duplicate = try makeViewModel(HTTPServices(api: api), email: email, password: password)
        await duplicate.submitAccount()
        XCTAssertEqual(duplicate.accountError, "An account with this email already exists. Sign in instead.")

        let signIn = try makeViewModel(HTTPServices(api: api), email: email, password: password)
        signIn.creatingAccount = false
        await signIn.submitAccount()
        XCTAssertNil(signIn.accountError)
        XCTAssertEqual(signIn.signedInEmail, email)

        try await Self.deleteAccount(baseURL: baseURL, accessToken: session.accessToken)
        do {
            _ = try await api.login(email: email, password: password)
            XCTFail("A deleted account must not sign in")
        } catch {
            XCTAssertEqual(error as? PrivateAccountAPIError, .http(401))
        }
    }

    private static func deleteAccount(baseURL: URL, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/private/account/delete"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 || status == 401 else { throw PrivateAccountAPIError.http(status) }
    }
}

private final class SignupStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var status = 200
    private nonisolated(unsafe) static var body = Data()
    private nonisolated(unsafe) static var path: String?

    static func set(status: Int, body: String) {
        lock.withLock { self.status = status; self.body = Data(body.utf8); path = nil }
    }

    static var lastPath: String? { lock.withLock { path } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock {
            Self.path = request.url?.path
            return (Self.status, Self.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
