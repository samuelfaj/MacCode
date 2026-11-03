import XCTest
@testable import AppShell

private final class AlertRetryStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var statuses: [Int] = []
    private nonisolated(unsafe) static var requestCount = 0

    static func reset(statuses: [Int]) {
        lock.withLock { self.statuses = statuses; requestCount = 0 }
    }

    static var count: Int { lock.withLock { requestCount } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status: Int = Self.lock.withLock {
            Self.requestCount += 1
            return Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body = status == 200 ? Data(#"{"delivered":true,"errorCode":null,"shouldDropSubscription":false}"#.utf8) : Data()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PrivateAlertRetryTests: XCTestCase {
    private func api() -> URLSessionPrivateAccountAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlertRetryStubProtocol.self]
        return URLSessionPrivateAccountAPI(
            baseURL: URL(string: "https://private.example.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func send(_ api: URLSessionPrivateAccountAPI) async throws -> PrivatePushDeliveryResult {
        try await api.deliverAlert(
            accessToken: "token", title: "t", body: "b", data: [:],
            pushToken: "push", pushTokenType: "apns", idempotencyKey: "key-1"
        )
    }

    func test_alert_transient503ThenSuccess_deliversWithoutUserAction() async throws {
        // WHY: a single 503 from the push service must not drop the user's completion alert.
        AlertRetryStubProtocol.reset(statuses: [503, 200])
        let result = try await send(api())
        XCTAssertTrue(result.delivered)
        XCTAssertEqual(AlertRetryStubProtocol.count, 2)
    }

    func test_alert_403FailsImmediately() async {
        // WHY: 403 is an authorization answer; repeating it hammers the backend for nothing.
        AlertRetryStubProtocol.reset(statuses: [403, 200])
        do {
            _ = try await send(api())
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? PrivateAccountAPIError, .http(403))
            XCTAssertEqual(AlertRetryStubProtocol.count, 1)
        }
    }
}
