import Foundation
import CoreModel
import Persistence
import os

public struct PrivateAccountUser: Codable, Equatable, Sendable {
    // Backend spelling: the API ships a misspelled `daysRemaing` key alongside
    // the correct `daysRemaining`. Keep this property name exactly as-is — it
    // must match the wire format until the backend is renamed.
    public let daysRemaing: Int?
    public let daysRemaining: Int
    public let email: String
    public let id: String
    public let subscribed: Bool
}

public struct PrivateAccountSession: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let user: PrivateAccountUser
}

public struct PrivateSubscriptionSnapshot: Codable, Equatable, Sendable {
    public let daysRemaing: Int?
    public let daysRemaining: Int
    public let email: String
    public let endsAt: String?
    public let portalUrl: String?
    public let renewsAt: String?
    public let status: String
    public let subscribed: Bool
    public let trialEndsAt: String?
}

public struct PrivateBillingOverview: Codable, Equatable, Sendable {
    public struct Plan: Codable, Equatable, Sendable {
        public let billingPeriod: String
        public let priceUsd: Double
        public let provider: String
        public let trialDays: Int
    }

    public let plan: Plan
    public let subscription: PrivateSubscriptionSnapshot
}

public struct PrivatePushDeliveryResult: Codable, Equatable, Sendable {
    public let delivered: Bool
    public let errorCode: String?
    public let shouldDropSubscription: Bool
}

// MARK: - Live Activity push content-state contract (host <-> iOS)
//
// CONTRACT PIN: an APNs Live Activity push carries a `content-state` dictionary
// that the iOS ActivityKit runtime decodes DIRECTLY into the on-device
// `RemoteCodeActivityAttributes.ContentState` via that struct's synthesized
// `Codable`. The keys below MUST therefore match that struct's stored-property
// names exactly (title, statusLine, preview, phase, activeThreadCount,
// updatedAt, runStartDate?, workspaceId?, threadId?, petState?, petFrame?). `phase` is the raw
// ThreadLiveActivityPhase string ("running" / "completed" / "failed"). This is
// the single schema both platforms agree on; the older chatId/chatTitle/
// elapsedSeconds shape (T025) is retired in favour of this one.
public struct PrivateLiveActivityContentState: Codable, Equatable, Sendable {
    public let title: String
    public let statusLine: String
    public let preview: String
    /// "running" | "completed" | "failed" -- the ThreadLiveActivityPhase raw value.
    public let phase: String
    public let activeThreadCount: Int
    /// Seconds since 1970 (UNIX epoch) so JS/native backends and the iOS decode
    /// agree on a single absolute time base regardless of JSONEncoder defaults.
    public let updatedAt: Double
    /// Run start (seconds since 1970) when a single thread is active; nil otherwise.
    public let runStartDate: Double?
    public let workspaceId: String?
    public let threadId: String?
    public let petState: String?
    public let petFrame: Int?
    public let titioFocus: TitioLiveActivityFocus?

    public init(
        title: String,
        statusLine: String,
        preview: String,
        phase: String,
        activeThreadCount: Int,
        updatedAt: Double,
        runStartDate: Double? = nil,
        workspaceId: String? = nil,
        threadId: String? = nil,
        petState: String? = nil,
        petFrame: Int? = nil,
        titioFocus: TitioLiveActivityFocus? = nil
    ) {
        self.title = title
        self.statusLine = statusLine
        self.preview = preview
        self.phase = phase
        self.activeThreadCount = activeThreadCount
        self.updatedAt = updatedAt
        self.runStartDate = runStartDate
        self.workspaceId = workspaceId
        self.threadId = threadId
        self.petState = petState
        self.petFrame = petFrame
        self.titioFocus = titioFocus
    }
}

/// Host-side equivalent of the iOS `ThreadLiveActivitySnapshot`: the minimal,
/// pure input the host has at a run-lifecycle boundary, from which the
/// Live Activity push payload (`PrivateLiveActivityContentState`) is built.
public struct PrivateLiveActivitySnapshot: Equatable, Sendable {
    public let title: String
    public let statusLine: String
    public let preview: String
    public let phase: String
    public let activeThreadCount: Int
    public let updatedAt: Date
    public let runStartDate: Date?
    public let workspaceId: String?
    public let threadId: String?
    public let petState: String
    public let petFrame: Int

    public init(
        title: String,
        statusLine: String,
        preview: String,
        phase: String,
        activeThreadCount: Int,
        updatedAt: Date,
        runStartDate: Date? = nil,
        workspaceId: String? = nil,
        threadId: String? = nil,
        petState: String? = nil,
        petFrame: Int = 0
    ) {
        self.title = title
        self.statusLine = statusLine
        self.preview = preview
        self.phase = phase
        self.activeThreadCount = activeThreadCount
        self.updatedAt = updatedAt
        self.runStartDate = runStartDate
        self.workspaceId = workspaceId
        self.threadId = threadId
        self.petState = petState ?? Self.fallbackPetState(for: phase)
        self.petFrame = petFrame
    }

    /// Pure payload builder (the host-side seam unit-tested in isolation):
    /// projects this snapshot into the wire content-state both platforms decode.
    public func contentState() -> PrivateLiveActivityContentState {
        PrivateLiveActivityContentState(
            title: title,
            statusLine: statusLine,
            preview: preview,
            phase: phase,
            activeThreadCount: activeThreadCount,
            updatedAt: updatedAt.timeIntervalSince1970,
            runStartDate: runStartDate?.timeIntervalSince1970,
            workspaceId: workspaceId,
            threadId: threadId,
            petState: petState,
            petFrame: petFrame
        )
    }

    /// Builds a mid-run "running" snapshot for a Live Activity `.update` heartbeat.
    /// Extracted (like `terminal`) so the title fallback, preview selection and
    /// 140-char clamp are unit-testable without driving the coordinator.
    /// `lastUpdatePreview` (alias of historical `finalMessage`) is the latest
    /// assistant/tool progress line for the single-active description.
    public static func running(
        threadId: String,
        workspaceId: String?,
        title: String?,
        finalMessage: String?,
        runStartDate: Date?,
        now: Date = Date()
    ) -> PrivateLiveActivitySnapshot {
        running(
            threadId: threadId,
            workspaceId: workspaceId,
            title: title,
            lastUpdatePreview: finalMessage,
            runStartDate: runStartDate,
            now: now
        )
    }

    /// Single-active mid-run snapshot with explicit last-update preview text.
    public static func running(
        threadId: String,
        workspaceId: String?,
        title: String?,
        lastUpdatePreview: String?,
        runStartDate: Date?,
        now: Date = Date()
    ) -> PrivateLiveActivitySnapshot {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (normalizedTitle?.isEmpty == false) ? normalizedTitle! : "Thread"
        let updateText = lastUpdatePreview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (updateText?.isEmpty == false) ? String(updateText!.prefix(140)) : displayTitle
        return PrivateLiveActivitySnapshot(
            title: displayTitle,
            statusLine: "Working…",
            preview: preview,
            phase: "running",
            activeThreadCount: 1,
            updatedAt: now,
            runStartDate: runStartDate,
            workspaceId: workspaceId,
            threadId: threadId,
            petState: "coding"
        )
    }

    /// Maps a terminal `AgentRunStatus` to a running/terminal Live Activity
    /// snapshot, reusing the same English copy the alert path ships. Returns nil
    /// for non-terminal phases (pending/running) so only real lifecycle ends
    /// fire a terminal Live Activity push.
    public static func terminal(
        threadId: String,
        title: String?,
        phase: AgentRunStatus,
        now: Date = Date()
    ) -> PrivateLiveActivitySnapshot? {
        let displayTitle = "Run"
        let mappedPhase: String
        let petState: String
        let statusLine: String
        let previewSuffix: String
        switch phase {
        case .completed:
            mappedPhase = "completed"
            petState = "success"
            statusLine = "Finished"
            previewSuffix = "response is ready."
        case .cancelled:
            mappedPhase = "failed"
            petState = "interrupted"
            statusLine = "Stopped"
            previewSuffix = "was stopped."
        case .interrupted:
            mappedPhase = "failed"
            petState = "interrupted"
            statusLine = "Interrupted"
            previewSuffix = "was interrupted."
        case .failed:
            mappedPhase = "failed"
            petState = "failed"
            statusLine = "Failed"
            previewSuffix = "ended with an error."
        case .pending, .running:
            return nil
        }
        return PrivateLiveActivitySnapshot(
            title: displayTitle,
            statusLine: statusLine,
            preview: "\(displayTitle) \(previewSuffix)",
            phase: mappedPhase,
            activeThreadCount: 0,
            updatedAt: now,
            workspaceId: nil,
            threadId: threadId,
            petState: petState
        )
    }

    private static func fallbackPetState(for phase: String) -> String {
        switch phase {
        case "completed": return "success"
        case "failed": return "failed"
        default: return "coding"
        }
    }
}

/// Idempotency-key namespace for Live Activity pushes, parallel to the
/// `thread.<id>.<outcome>` keys the alert path uses. Kept distinct so a Live
/// Activity update and an alert for the same run never collide on the backend.
public enum PrivateLiveActivityEvent: String, Codable, Equatable, Sendable {
    case start
    case update
    case end
}

struct PrivateLiveActivityDeliveryRequestBody<ContentState: Encodable>: Encodable {
    let contentState: ContentState
    let event: String
    let liveActivityToken: String
    let pushToken: String
    let pushTokenType: String
    let timestampSeconds: Int64
}

public enum PrivateLiveActivityV2TokenKind: String, Codable, Equatable, Sendable {
    case pushToStart
    case update
}

public struct PrivateLiveActivityV2TokenRegistration: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let activityKey: String
    public let deviceId: String
    public let environment: PrivatePushEnvironment
    public let token: String
    public let tokenKind: PrivateLiveActivityV2TokenKind
    public let hostId: String?
    public let bootEpoch: UInt64?
    public let activityGeneration: UInt64?
    public let activitySessionId: String?
    public let activityId: String?

    public init(
        protocolVersion: Int = 2,
        activityKey: String = "active-threads",
        deviceId: String,
        environment: PrivatePushEnvironment,
        token: String,
        tokenKind: PrivateLiveActivityV2TokenKind,
        hostId: String? = nil,
        bootEpoch: UInt64? = nil,
        activityGeneration: UInt64? = nil,
        activitySessionId: String? = nil,
        activityId: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.activityKey = activityKey
        self.deviceId = deviceId
        self.environment = environment
        self.token = token
        self.tokenKind = tokenKind
        self.hostId = hostId
        self.bootEpoch = bootEpoch
        self.activityGeneration = activityGeneration
        self.activitySessionId = activitySessionId
        self.activityId = activityId
    }
}

public struct LiveActivityTokenOwnership: Codable, Equatable, Hashable, Sendable {
    public let activityId: String
    public let hostId: String
    public let bootEpoch: UInt64
    public let activityGeneration: UInt64
    public let activitySessionId: String

    public init(activityId: String, hostId: String, bootEpoch: UInt64, activityGeneration: UInt64, activitySessionId: String) {
        self.activityId = activityId
        self.hostId = hostId
        self.bootEpoch = bootEpoch
        self.activityGeneration = activityGeneration
        self.activitySessionId = activitySessionId
    }
}

public struct PrivateLiveActivityV2TokenRegistrationAck: Codable, Equatable, Sendable {
    public struct Token: Codable, Equatable, Sendable {
        public let activityKey: String
        public let deviceId: String
        public let environment: PrivatePushEnvironment
        public let tokenKind: PrivateLiveActivityV2TokenKind
        public let hostId: String?
        public let bootEpoch: UInt64?
        public let activityGeneration: UInt64?
        public let activitySessionId: String?
        public let activityId: String?

        public var ownership: LiveActivityTokenOwnership? {
            guard let activityId, let hostId, let bootEpoch, let activityGeneration, let activitySessionId else { return nil }
            return LiveActivityTokenOwnership(
                activityId: activityId, hostId: hostId, bootEpoch: bootEpoch,
                activityGeneration: activityGeneration, activitySessionId: activitySessionId
            )
        }
    }

    public let token: Token
}

/// Flat backend v2 request. This is the single adapter between the internal
/// host projection and `/live-activities/deliver`; ActivityKit content-state
/// nesting remains a backend responsibility.
public struct PrivateLiveActivityV2DeliveryRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let activityKey: String
    public let activitySessionId: String
    public let hostId: String
    public let bootEpoch: UInt64
    public let activityGeneration: UInt64
    public let revision: Int64
    public let event: PrivateLiveActivityEvent
    public let deviceId: String
    public let environment: PrivatePushEnvironment
    public let phase: PrivateLiveActivityProjectionPhase
    public let activeThreadCount: Int
    public let title: String
    public let statusLine: String
    public let preview: String
    public let updatedAtEpochSeconds: Int64
    public let runStartEpochSeconds: Int64?
    public let workspaceId: String?
    public let threadId: String?
    public let petState: String?
    public let titioFocus: TitioLiveActivityFocus?

    public init(delivery: LiveActivitySyncDelivery, target: PrivatePushTargetRecord) {
        protocolVersion = 2
        activityKey = "active-threads"
        activitySessionId = delivery.projection.sessionId
        hostId = delivery.projection.hostId
        bootEpoch = UInt64(delivery.projection.epoch) ?? 0
        activityGeneration = delivery.activityGeneration
        revision = delivery.projection.revision
        event = delivery.event
        deviceId = target.deviceId
        environment = target.environment
        phase = delivery.projection.phase
        activeThreadCount = delivery.projection.activeThreadCount
        title = delivery.projection.title
        statusLine = delivery.projection.statusLine
        preview = delivery.projection.preview
        updatedAtEpochSeconds = Int64(delivery.projection.updatedAt)
        runStartEpochSeconds = delivery.projection.runStartDate.map(Int64.init)
        workspaceId = delivery.projection.workspaceId
        threadId = delivery.projection.threadId
        petState = delivery.projection.petState
        titioFocus = delivery.projection.titioFocus
    }
}

public protocol PrivateAccountAPI: Sendable {
    func login(email: String, password: String) async throws -> PrivateAccountSession
    func currentUser(accessToken: String) async throws -> PrivateAccountUser
    func refresh(refreshToken: String) async throws -> PrivateAccountSession
    func logout(refreshToken: String) async throws
    func billingOverview(accessToken: String) async throws -> PrivateBillingOverview
    func createPortal(accessToken: String) async throws -> URL
    func deliverAlert(accessToken: String, title: String, body: String, data: [String: String], pushToken: String, pushTokenType: String, idempotencyKey: String, silent: Bool) async throws -> PrivatePushDeliveryResult
    func deliverLiveActivity(accessToken: String, event: String, contentState: PrivateLiveActivityContentState, timestampSeconds: Int64, liveActivityToken: String, pushToken: String, pushTokenType: String, idempotencyKey: String) async throws -> PrivatePushDeliveryResult
    func registerLiveActivityTokenV2(accessToken: String, registration: PrivateLiveActivityV2TokenRegistration) async throws -> PrivateLiveActivityV2TokenRegistrationAck
    func deliverLiveActivityV2(accessToken: String, request: PrivateLiveActivityV2DeliveryRequest, idempotencyKey: String) async throws -> PrivateLiveActivityV2DeliveryAck
}

public extension PrivateAccountAPI {
    func registerLiveActivityTokenV2(
        accessToken: String,
        registration: PrivateLiveActivityV2TokenRegistration
    ) async throws -> PrivateLiveActivityV2TokenRegistrationAck {
        throw PrivateAccountAPIError.invalidResponse
    }

    func deliverLiveActivityV2(
        accessToken: String,
        request: PrivateLiveActivityV2DeliveryRequest,
        idempotencyKey: String
    ) async throws -> PrivateLiveActivityV2DeliveryAck {
        throw PrivateAccountAPIError.invalidResponse
    }
}

public enum PrivateAccountAPIError: Error, Equatable {
    case invalidResponse
    case http(Int)
}

public final class URLSessionPrivateAccountAPI: PrivateAccountAPI, @unchecked Sendable {
    static let liveActivityV2DeliveryPath = "/v1/private/push-notification/live-activities/deliver"
    static let liveActivityV2TokensPath = "/v1/private/push-notification/live-activities/tokens"

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL = URL(string: "https://private.remotecode.io")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func login(email: String, password: String) async throws -> PrivateAccountSession {
        struct Body: Encodable { let email: String; let password: String }
        return try await request(path: "/v1/private/auth/login", method: "POST", body: Body(email: email, password: password))
    }

    public func currentUser(accessToken: String) async throws -> PrivateAccountUser {
        struct Response: Decodable { let user: PrivateAccountUser }
        let response: Response = try await request(path: "/v1/private/me", method: "GET", accessToken: accessToken)
        return response.user
    }

    public func refresh(refreshToken: String) async throws -> PrivateAccountSession {
        struct Body: Encodable { let refreshToken: String }
        return try await request(path: "/v1/private/auth/refresh", method: "POST", body: Body(refreshToken: refreshToken))
    }

    public func logout(refreshToken: String) async throws {
        struct Body: Encodable { let refreshToken: String }
        try await requestEmpty(path: "/v1/private/auth/logout", method: "POST", body: Body(refreshToken: refreshToken))
    }

    public func billingOverview(accessToken: String) async throws -> PrivateBillingOverview {
        struct Response: Decodable { let billing: PrivateBillingOverview }
        let response: Response = try await request(path: "/v1/private/billing", method: "GET", accessToken: accessToken)
        return response.billing
    }

    public func createPortal(accessToken: String) async throws -> URL {
        struct Response: Decodable { let portalUrl: URL }
        let response: Response = try await request(path: "/v1/private/billing/portal", method: "POST", accessToken: accessToken)
        return response.portalUrl
    }

    public func deliverAlert(accessToken: String, title: String, body: String, data: [String: String], pushToken: String, pushTokenType: String, idempotencyKey: String, silent: Bool = false) async throws -> PrivatePushDeliveryResult {
        struct Body: Encodable {
            let body: String
            let data: [String: String]?
            let pushToken: String
            let pushTokenType: String
            let silent: Bool?
            let title: String
        }
        return try await request(
            path: "/v1/private/push-notification/alert",
            method: "POST",
            accessToken: accessToken,
            body: Body(
                body: body,
                data: data.isEmpty ? nil : data,
                pushToken: pushToken,
                pushTokenType: pushTokenType,
                silent: silent ? true : nil,
                title: title
            ),
            idempotencyKey: idempotencyKey
        )
    }

    public func deliverLiveActivity(
        accessToken: String,
        event: String,
        contentState: PrivateLiveActivityContentState,
        timestampSeconds: Int64,
        liveActivityToken: String,
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String
    ) async throws -> PrivatePushDeliveryResult {
        return try await request(
            path: "/v1/private/push-notification/deliver",
            method: "POST",
            accessToken: accessToken,
            body: PrivateLiveActivityDeliveryRequestBody(
                contentState: contentState,
                event: event,
                liveActivityToken: liveActivityToken,
                pushToken: pushToken,
                pushTokenType: pushTokenType,
                timestampSeconds: timestampSeconds
            ),
            idempotencyKey: idempotencyKey,
            timeout: LiveActivityDeliveryPolicy.requestTimeoutSeconds
        )
    }

    public func deliverLiveActivityV2(
        accessToken: String,
        request deliveryRequest: PrivateLiveActivityV2DeliveryRequest,
        idempotencyKey: String
    ) async throws -> PrivateLiveActivityV2DeliveryAck {
        try await request(
            path: Self.liveActivityV2DeliveryPath,
            method: "POST",
            accessToken: accessToken,
            body: deliveryRequest,
            idempotencyKey: idempotencyKey,
            timeout: LiveActivityDeliveryPolicy.requestTimeoutSeconds
        )
    }

    public func registerLiveActivityTokenV2(
        accessToken: String,
        registration: PrivateLiveActivityV2TokenRegistration
    ) async throws -> PrivateLiveActivityV2TokenRegistrationAck {
        try await request(
            path: Self.liveActivityV2TokensPath,
            method: "POST",
            accessToken: accessToken,
            body: registration,
            timeout: LiveActivityDeliveryPolicy.requestTimeoutSeconds
        )
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        accessToken: String? = nil,
        body: (any Encodable)? = nil,
        idempotencyKey: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(normalizedPath))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }
        if let timeout {
            // Explicit 10–12s band so a hung Live Activity HTTPS call cannot
            // pin a device lane indefinitely.
            request.timeoutInterval = timeout
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrivateAccountAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PrivateAccountAPIError.http(http.statusCode) }
        return try decoder.decode(Response.self, from: data)
    }

    private func requestEmpty(
        path: String,
        method: String,
        accessToken: String? = nil,
        body: (any Encodable)? = nil
    ) async throws {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(normalizedPath))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrivateAccountAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PrivateAccountAPIError.http(http.statusCode) }
    }
}

public final class PrivateAccountSessionStore: @unchecked Sendable {
    private static let log = Logger(subsystem: "io.remotecode.app", category: "private-account")
    private let repo: SettingsRepository
    private let key = "private.account.session"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Shared settings store for durable silent-wake outbox persistence.
    public var settingsRepository: SettingsRepository { repo }

    public init(repo: SettingsRepository) {
        self.repo = repo
    }

    public func load() -> PrivateAccountSession? {
        session(fromJSON: loadRawJSON())
    }

    /// Raw settings blob so callers can skip JSONDecoder when the session is unchanged.
    public func loadRawJSON() -> String? {
        try? repo.get(key)
    }

    public func session(fromJSON json: String?) -> PrivateAccountSession? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(PrivateAccountSession.self, from: data)
    }

    /// Returns whether the session reached settings. Every reader (`load()`)
    /// goes through settings, so `false` means the sign-in is not durable —
    /// callers with a user surface must say so instead of reporting success.
    @discardableResult
    public func save(_ session: PrivateAccountSession) -> Bool {
        guard let data = try? encoder.encode(session),
              let json = String(data: data, encoding: .utf8) else {
            Self.log.error("private account session encode failed")
            return false
        }
        do {
            try repo.set(key, json)
            publishAccountChanged()
            return true
        } catch {
            Self.log.error("private account session save failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Returns whether the stored session was removed. `false` leaves the old
    /// session readable, so a caller must not paint a signed-out state.
    @discardableResult
    public func clear() -> Bool {
        do {
            try repo.set(key, "")
            publishAccountChanged()
            return true
        } catch {
            Self.log.error("private account session clear failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func publishAccountChanged() {
        let publish = {
            NotificationCenter.default.post(name: .rc2PrivateAccountChanged, object: nil)
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }
}

public struct PrivatePushTarget: Codable, Equatable, Sendable {
    public let deviceId: String?
    public let liveActivityToken: String?
    public let pushToken: String
    public let pushTokenType: String
    public let updatedAt: Date
}

public enum PrivatePushTokenPurpose: String, Codable, Equatable, Sendable {
    case alert
    case pushToStart = "push_to_start"
    case activityUpdate = "activity_update"
}

public enum PrivatePushEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

public struct PrivatePushTargetRecord: Codable, Equatable, Sendable {
    public let deviceId: String
    public let serverId: String
    public let purpose: PrivatePushTokenPurpose
    public let environment: PrivatePushEnvironment
    public let token: String
    public let activityGeneration: UInt64?
    public let activityId: String?
    public let bootEpoch: UInt64?
    public let activitySessionId: String?
    public let contractVersion: Int
    public let capabilities: [String]?
    public let updatedAt: Date

    public init(
        deviceId: String,
        serverId: String,
        purpose: PrivatePushTokenPurpose,
        environment: PrivatePushEnvironment,
        token: String,
        activityGeneration: UInt64? = nil,
        activityId: String? = nil,
        bootEpoch: UInt64? = nil,
        activitySessionId: String? = nil,
        contractVersion: Int = 1,
        capabilities: [String]? = nil,
        updatedAt: Date = Date()
    ) {
        self.deviceId = deviceId
        self.serverId = serverId
        self.purpose = purpose
        self.environment = environment
        self.token = token
        self.activityGeneration = activityGeneration
        self.activityId = activityId
        self.bootEpoch = bootEpoch
        self.activitySessionId = activitySessionId
        self.contractVersion = contractVersion
        self.capabilities = capabilities
        self.updatedAt = updatedAt
    }

    public var supportsLiveActivityV2: Bool {
        contractVersion >= 2 && (capabilities ?? []).contains("live_activity_v2")
    }

    public var ownership: LiveActivityTokenOwnership? {
        guard purpose == .activityUpdate,
              let activityId,
              let bootEpoch,
              let activityGeneration,
              let activitySessionId else { return nil }
        return LiveActivityTokenOwnership(
            activityId: activityId,
            hostId: serverId,
            bootEpoch: bootEpoch,
            activityGeneration: activityGeneration,
            activitySessionId: activitySessionId
        )
    }

    public func bound(to ownership: LiveActivityTokenOwnership) -> PrivatePushTargetRecord {
        PrivatePushTargetRecord(
            deviceId: deviceId,
            serverId: ownership.hostId,
            purpose: purpose,
            environment: environment,
            token: token,
            activityGeneration: ownership.activityGeneration,
            activityId: ownership.activityId,
            bootEpoch: ownership.bootEpoch,
            activitySessionId: ownership.activitySessionId,
            contractVersion: contractVersion,
            capabilities: capabilities,
            updatedAt: updatedAt
        )
    }
}

public final class PrivatePushTargetStore: @unchecked Sendable {
    private let repo: SettingsRepository
    private let key = "private.push.target"
    private let recordsKey = "private.push.targets.v2"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let lock = NSLock()

    public init(repo: SettingsRepository) {
        self.repo = repo
    }

    public func load() -> PrivatePushTarget? {
        guard let json = try? repo.get(key),
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(PrivatePushTarget.self, from: data)
    }

    /// Persists the legacy single-device push target used by alert + Live Activity
    /// delivery. **Never clobbers a stored Live Activity token with nil/empty** —
    /// iOS often re-registers APNs alert tokens without re-sending the push-to-
    /// start token (especially after a Mac app update when the phone stays idle).
    /// Throws when the settings store cannot be read or written: swallowing the
    /// failure let `privatePushTokenUpdate` answer `{"ok": true}` to iOS while no
    /// push target was persisted.
    public func save(pushToken: String, pushTokenType: String, liveActivityToken: String?, deviceId: String?) throws {
        // A swallowed read failure would drop `previous` and clear the stored
        // Live Activity token with nil — the case the contract above forbids.
        let previous: PrivatePushTarget?
        if let json = try repo.get(key), let data = json.data(using: .utf8) {
            previous = try? decoder.decode(PrivatePushTarget.self, from: data)
        } else {
            previous = nil
        }
        let resolvedLiveActivityToken: String?
        if let liveActivityToken, !liveActivityToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedLiveActivityToken = liveActivityToken
        } else {
            resolvedLiveActivityToken = previous?.liveActivityToken
        }
        let resolvedDeviceId: String?
        if let deviceId, !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedDeviceId = deviceId
        } else {
            resolvedDeviceId = previous?.deviceId
        }
        let target = PrivatePushTarget(
            deviceId: resolvedDeviceId,
            liveActivityToken: resolvedLiveActivityToken,
            pushToken: pushToken,
            pushTokenType: pushTokenType,
            updatedAt: Date()
        )
        let data = try encoder.encode(target)
        try repo.set(key, String(decoding: data, as: UTF8.self))
    }

    public func clear() {
        try? repo.set(key, "")
    }

    /// True when `save` with these arguments would rewrite only `updatedAt`.
    public func legacyTargetMatches(
        pushToken: String,
        pushTokenType: String,
        liveActivityToken: String?,
        deviceId: String?
    ) -> Bool {
        guard let stored = load(),
              stored.pushToken == pushToken,
              stored.pushTokenType == pushTokenType else { return false }
        if let liveActivityToken,
           !liveActivityToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           stored.liveActivityToken != liveActivityToken {
            return false
        }
        if let deviceId,
           !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           stored.deviceId != deviceId {
            return false
        }
        return true
    }

    /// True when `upsert(record)` would rewrite only `updatedAt`.
    public func containsCurrentRecord(_ record: PrivatePushTargetRecord) -> Bool {
        guard let values = try? records() else { return false }
        return values.contains {
            Self.sameIdentity($0, record) &&
            $0.token == record.token &&
            $0.activityGeneration == record.activityGeneration &&
            $0.activityId == record.activityId &&
            $0.bootEpoch == record.bootEpoch &&
            $0.activitySessionId == record.activitySessionId &&
            $0.contractVersion == record.contractVersion &&
            $0.capabilities == record.capabilities
        }
    }

    /// After a Mac relaunch/update, rebind durable alert + push-to-start records
    /// to the current host `serverId` so Live Activity start pushes still find a
    /// target without requiring the user to open iOS first. Activity-update
    /// tokens stay untouched (they are scoped to a specific activity generation).
    @discardableResult
    public func rebindDurableTokens(toHostServerId serverId: String) throws -> [PrivatePushTargetRecord] {
        try lock.withLock {
            let previous = try loadRecordsUnlocked()
            var rebound: [PrivatePushTargetRecord] = []
            var next: [PrivatePushTargetRecord] = []
            for record in previous {
                switch record.purpose {
                case .alert, .pushToStart:
                    let updated = PrivatePushTargetRecord(
                        deviceId: record.deviceId,
                        serverId: serverId,
                        purpose: record.purpose,
                        environment: record.environment,
                        token: record.token,
                        activityGeneration: record.activityGeneration,
                        activityId: record.activityId,
                        bootEpoch: nil,
                        activitySessionId: nil,
                        contractVersion: record.contractVersion,
                        capabilities: record.capabilities,
                        updatedAt: record.updatedAt
                    )
                    next.append(updated)
                    if record.purpose == .pushToStart, updated.supportsLiveActivityV2 {
                        rebound.append(updated)
                    }
                case .activityUpdate:
                    next.append(record)
                }
            }
            try saveRecordsUnlocked(next)
            return rebound
        }
    }

    public func records() throws -> [PrivatePushTargetRecord] {
        try lock.withLock { try loadRecordsUnlocked() }
    }

    public func upsert(_ record: PrivatePushTargetRecord) throws {
        try lock.withLock {
            var values = try loadRecordsUnlocked()
            values.removeAll { Self.sameIdentity($0, record) }
            values.append(record)
            try saveRecordsUnlocked(values)
        }
    }

    public func invalidate(
        deviceId: String,
        serverId: String,
        purpose: PrivatePushTokenPurpose,
        environment: PrivatePushEnvironment,
        activityGeneration: UInt64? = nil,
        activityId: String? = nil,
        bootEpoch: UInt64? = nil,
        activitySessionId: String? = nil,
        token: String? = nil
    ) throws {
        try lock.withLock {
            var values = try loadRecordsUnlocked()
            values.removeAll {
                $0.deviceId == deviceId &&
                $0.serverId == serverId &&
                $0.purpose == purpose &&
                $0.environment == environment &&
                $0.activityGeneration == activityGeneration &&
                $0.activityId == activityId &&
                (bootEpoch == nil || $0.bootEpoch == bootEpoch) &&
                (activitySessionId == nil || $0.activitySessionId == activitySessionId) &&
                (token == nil || $0.token == token)
            }
            try saveRecordsUnlocked(values)
        }
    }

    /// Remove exactly one dead `.activityUpdate` courier. Scope is owner/server,
    /// device, APNs environment, Activity ID, boot epoch, generation, session,
    /// and rejected token identity. A delayed rejection for historical token A
    /// never removes rotated current token B, other devices, or other
    /// environments.
    public func invalidateActivityUpdateTarget(_ target: PrivatePushTargetRecord) throws {
        guard target.purpose == .activityUpdate else { return }
        try lock.withLock {
            var values = try loadRecordsUnlocked()
            // Only the still-authoritative row for this exact ownership may
            // retire. If the stored token already rotated, leave B alone.
            values.removeAll {
                $0.purpose == .activityUpdate &&
                $0.deviceId == target.deviceId &&
                $0.serverId == target.serverId &&
                $0.environment == target.environment &&
                $0.activityId == target.activityId &&
                $0.bootEpoch == target.bootEpoch &&
                $0.activityGeneration == target.activityGeneration &&
                $0.activitySessionId == target.activitySessionId &&
                $0.token == target.token
            }
            try saveRecordsUnlocked(values)
        }
    }

    /// Age/count prune for stale `.activityUpdate` rows while protecting the
    /// current authoritative token per device + server + APNs environment
    /// (newest `updatedAt`). Alert and push-to-start rows are never candidates.
    @discardableResult
    public func pruneStaleActivityUpdateTargets(
        now: Date = Date(),
        maxAge: TimeInterval = PrivatePushTargetStore.activityUpdateRetention,
        maxCount: Int = PrivatePushTargetStore.activityUpdateCap
    ) throws -> Int {
        try lock.withLock {
            var values = try loadRecordsUnlocked()
            let before = values.count
            let updates = values.filter { $0.purpose == .activityUpdate }
            guard !updates.isEmpty else { return 0 }

            // Newest courier per device/server/environment is the current authority.
            var newestByDeviceEnv: [String: PrivatePushTargetRecord] = [:]
            for record in updates {
                let slot = Self.activityUpdateDeviceEnvironmentIdentity(record)
                if let existing = newestByDeviceEnv[slot] {
                    if record.updatedAt >= existing.updatedAt {
                        newestByDeviceEnv[slot] = record
                    }
                } else {
                    newestByDeviceEnv[slot] = record
                }
            }
            let protectedKeys = Set(newestByDeviceEnv.values.map(Self.activityUpdateExactKey))
            let cutoff = now.addingTimeInterval(-max(0, maxAge))
            let effectiveMaxCount = max(0, maxCount)

            // Age-prune only non-authoritative rows.
            values.removeAll { record in
                guard record.purpose == .activityUpdate else { return false }
                if protectedKeys.contains(Self.activityUpdateExactKey(record)) {
                    return false
                }
                return record.updatedAt < cutoff
            }

            var remainingUpdates = values.filter { $0.purpose == .activityUpdate }
            if remainingUpdates.count > effectiveMaxCount {
                remainingUpdates.sort { $0.updatedAt < $1.updatedAt }
                var dropKeys = Set<String>()
                var liveCount = remainingUpdates.count
                // Prefer dropping non-authoritative first.
                for record in remainingUpdates {
                    guard liveCount > effectiveMaxCount else { break }
                    let key = Self.activityUpdateExactKey(record)
                    if protectedKeys.contains(key) { continue }
                    dropKeys.insert(key)
                    liveCount -= 1
                }
                values.removeAll {
                    $0.purpose == .activityUpdate &&
                    dropKeys.contains(Self.activityUpdateExactKey($0))
                }
            }

            let removed = before - values.count
            if removed > 0 {
                try saveRecordsUnlocked(values)
            }
            return removed
        }
    }

    /// One rollover window plus a small margin for delayed terminal delivery.
    public static let activityUpdateRetention: TimeInterval = 8 * 60 * 60
    /// Historical-row cap after age prune. Current per-device authorities stay
    /// protected even if their device count alone exceeds this soft cap.
    public static let activityUpdateCap = 64

    private static func activityUpdateDeviceEnvironmentIdentity(
        _ record: PrivatePushTargetRecord
    ) -> String {
        [
            record.serverId,
            record.deviceId,
            record.environment.rawValue,
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func activityUpdateExactKey(_ record: PrivatePushTargetRecord) -> String {
        [
            record.serverId,
            record.deviceId,
            record.environment.rawValue,
            record.activityId ?? "",
            record.bootEpoch.map(String.init) ?? "",
            record.activityGeneration.map(String.init) ?? "",
            record.activitySessionId ?? "",
            record.token,
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private func loadRecordsUnlocked() throws -> [PrivatePushTargetRecord] {
        guard let json = try repo.get(recordsKey),
              let data = json.data(using: .utf8),
              !data.isEmpty else { return [] }
        return try decoder.decode([PrivatePushTargetRecord].self, from: data)
    }

    private func saveRecordsUnlocked(_ records: [PrivatePushTargetRecord]) throws {
        let data = try encoder.encode(records)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try repo.set(recordsKey, json)
    }

    /// Durable identity for upsert. Deliberately excludes `bootEpoch`,
    /// `activityGeneration`, and `activitySessionId` so a Mac relaunch/update
    /// (which advances boot epoch) **replaces** the stored token instead of
    /// stacking orphaned rows that break `acceptanceTargets` filters.
    private static func sameIdentity(_ lhs: PrivatePushTargetRecord, _ rhs: PrivatePushTargetRecord) -> Bool {
        lhs.deviceId == rhs.deviceId &&
        lhs.serverId == rhs.serverId &&
        lhs.purpose == rhs.purpose &&
        lhs.environment == rhs.environment &&
        (lhs.purpose != .activityUpdate || lhs.activityId == rhs.activityId)
    }
}

private actor PrivatePushSessionRefresher {
    private let accountStore: PrivateAccountSessionStore
    private let api: PrivateAccountAPI
    private var refreshTask: Task<PrivateAccountSession, Error>?

    init(accountStore: PrivateAccountSessionStore, api: PrivateAccountAPI) {
        self.accountStore = accountStore
        self.api = api
    }

    func perform<Response: Sendable>(
        session fallbackSession: PrivateAccountSession,
        operation: @escaping @Sendable (String) async throws -> Response
    ) async throws -> Response {
        let session = accountStore.load() ?? fallbackSession
        do {
            return try await operation(session.accessToken)
        } catch let error as PrivateAccountAPIError where error == .http(401) {
            let refreshed = try await refreshedSession(replacing: session)
            do {
                return try await operation(refreshed.accessToken)
            } catch let retryError as PrivateAccountAPIError where retryError == .http(401) {
                accountStore.clear()
                throw retryError
            }
        }
    }

    private func refreshedSession(
        replacing staleSession: PrivateAccountSession
    ) async throws -> PrivateAccountSession {
        if let current = accountStore.load(), current.accessToken != staleSession.accessToken {
            return current
        }
        if let refreshTask {
            return try await refreshTask.value
        }

        let api = self.api
        let accountStore = self.accountStore
        let refreshToken = staleSession.refreshToken
        let staleAccessToken = staleSession.accessToken
        // The store is settled inside the shared task so every awaiter resumes
        // after it: a joined caller must not see the stale session and retry.
        let task = Task {
            do {
                let session = try await api.refresh(refreshToken: refreshToken)
                accountStore.save(session)
                return session
            } catch {
                // Another refresher (Settings) may have stored a newer session
                // while this refresh was in flight: use it.
                let current = accountStore.load()
                if let current, current.accessToken != staleAccessToken {
                    return current
                }
                // Only the backend's auth rejection ends the session. Offline,
                // timeout, 5xx, 429 and decode errors keep it for the next try.
                if let apiError = error as? PrivateAccountAPIError, apiError == .http(401),
                   current?.refreshToken == refreshToken {
                    accountStore.clear()
                }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}

public final class PrivateNotificationBridge: @unchecked Sendable {
    private static let log = Logger(subsystem: "io.remotecode.app", category: "private-push")
    private let accountStore: PrivateAccountSessionStore
    private let pushTargetStore: PrivatePushTargetStore
    private let api: PrivateAccountAPI
    private let sessionRefresher: PrivatePushSessionRefresher
    /// Durable retry outbox for failed silent catch-up sends. Gated by
    /// `ConnectionFeatureFlags.wakeOutboxEnabled` at enqueue and drain time.
    private let silentWakeOutbox: SilentWakeOutbox
    /// Indirection so the outbox send closure can bind after `self` exists.
    private let silentWakeSendBox: SilentWakeOutboxSendBox
    private struct ConnectionHintSources {
        var hostId: (@Sendable () -> String?)?
        var watermark: (@Sendable () -> String?)?
        var bootEpoch: (@Sendable () -> String?)?
    }
    private let connectionHintLock = NSLock()
    private var connectionHintSources = ConnectionHintSources()
    /// The resolved settings store. Besides the outbox it holds the hourly
    /// silent-wake budget. Not `UserDefaults.standard`: that store is process-wide.
    private let settings: SettingsRepository
    private static let silentWakeBudgetKey = "private.silentWake.budget.v1"
    private let silentWakeBudgetLock = NSLock()
    /// Silent sends between budget admission and the backend's answer, by device.
    private var silentWakesInFlight: [String: Int] = [:]
    /// Stored budget value, retaining every push-target device's delivered wakes.
    private struct SilentWakeBudgetState: Codable {
        var devices: [String: [TimeInterval]]

        private enum CodingKeys: String, CodingKey { case devices, device, sent }

        init(devices: [String: [TimeInterval]]) {
            self.devices = devices
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let devices = try container.decodeIfPresent([String: [TimeInterval]].self, forKey: .devices) {
                self.devices = devices
            } else {
                let device = try container.decode(String.self, forKey: .device)
                let sent = try container.decode([TimeInterval].self, forKey: .sent)
                self.devices = [device: sent]
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(devices, forKey: .devices)
        }
    }

    /// Holds the outbox → bridge send handler without a process-wide singleton.
    private final class SilentWakeOutboxSendBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (SilentWakeOutboxRecord) async throws -> Void)?

        func bind(_ handler: @escaping @Sendable (SilentWakeOutboxRecord) async throws -> Void) {
            lock.withLock { self.handler = handler }
        }

        func send(_ record: SilentWakeOutboxRecord) async throws {
            let handler = lock.withLock { self.handler }
            guard let handler else { throw SilentWakeOutboxError.bridgeUnavailable }
            try await handler(record)
        }
    }

    public init(
        accountStore: PrivateAccountSessionStore,
        pushTargetStore: PrivatePushTargetStore,
        api: PrivateAccountAPI = URLSessionPrivateAccountAPI(),
        settings: SettingsRepository? = nil,
        silentWakeOutbox: SilentWakeOutbox? = nil
    ) {
        self.accountStore = accountStore
        self.pushTargetStore = pushTargetStore
        self.api = api
        self.sessionRefresher = PrivatePushSessionRefresher(accountStore: accountStore, api: api)
        let resolvedSettings = settings ?? accountStore.settingsRepository
        self.settings = resolvedSettings
        let sendBox = SilentWakeOutboxSendBox()
        self.silentWakeSendBox = sendBox
        if let silentWakeOutbox {
            self.silentWakeOutbox = silentWakeOutbox
        } else {
            let store = SilentWakeOutboxStore(
                settings: resolvedSettings
            )
            self.silentWakeOutbox = SilentWakeOutbox(store: store) { record in
                try await sendBox.send(record)
            }
        }
        sendBox.bind { [weak self] record in
            guard let self else { throw SilentWakeOutboxError.bridgeUnavailable }
            try await self.performSilentCatchUpDelivery(record)
        }
        // Survive Mac relaunch when the flag is canary-on: drain durable backlog.
        self.silentWakeOutbox.resumePending()
    }

    /// Late-bound sources for `PushConnectionHints`. Unset sources contribute nothing.
    func setConnectionHintSources(
        hostId: (@Sendable () -> String?)? = nil,
        watermark: (@Sendable () -> String?)? = nil,
        bootEpoch: (@Sendable () -> String?)? = nil
    ) {
        connectionHintLock.withLock {
            if let hostId { connectionHintSources.hostId = hostId }
            if let watermark { connectionHintSources.watermark = watermark }
            if let bootEpoch { connectionHintSources.bootEpoch = bootEpoch }
        }
    }

    /// Every host -> iOS push goes through this so alert, silent, and outbox
    /// replay carry the same connection and catch-up hints.
    private func withConnectionHints(_ data: [String: String]) async -> [String: String] {
        let sources = connectionHintLock.withLock { connectionHintSources }
        var hints = PushConnectionHints.merge(
            into: data,
            watermark: sources.watermark?(),
            bootEpoch: sources.bootEpoch?()
        )
        if let hostId = sources.hostId?() { hints["host_id"] = hostId }
        return hints
    }

    /// Test seam: observe the durable silent-wake outbox.
    public var silentWakeOutboxForTests: SilentWakeOutbox { silentWakeOutbox }

    /// Whether the paired device has an activity_update courier (active LA
    /// update channel). Pure policy lives on `AgentAppPushPolicy`.
    public func isLiveActivityUpdateChannelArmed() -> Bool {
        let updateTokens = ((try? pushTargetStore.records()) ?? [])
            .filter { $0.purpose == .activityUpdate }
            .map(\.token)
        return RemoteCodeNotificationContent.AgentAppPushPolicy
            .isLiveActivityUpdateChannelArmed(activityUpdateTokens: updateTokens)
    }

    /// F5: a Live Activity card of the push target's device was registered
    /// within ActivityKit's 8 h active limit.
    func isLiveActivityActiveForPushTarget(now: Date = Date()) -> Bool {
        guard let target = pushTargetStore.load() else { return false }
        // A legacy target without a device id keeps today's rule: any card counts.
        let targetDeviceId = target.deviceId ?? ""
        return ((try? pushTargetStore.records()) ?? []).contains { record in
            record.purpose == .activityUpdate
                && !record.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && now.timeIntervalSince(record.updatedAt) < PrivatePushTargetStore.activityUpdateRetention
                && (targetDeviceId.isEmpty || record.deviceId == targetDeviceId)
        }
    }

    /// Terminal main-agent finish remote path: suppress the visible APNs banner
    /// when a Live Activity update channel is already armed (Lock Screen covers
    /// completed/failed). Cancelled still alerts. Always forces silent catch-up
    /// when suppressed so iOS mirrors host state. Attention uses `deliver(_:)`.
    public func deliverThreadOutcomeRemote(
        _ content: RemoteCodeNotificationContent,
        phase: AgentRunStatus
    ) async {
        guard RemoteCodeNotificationContent.AgentAppPushPolicy.shouldNotifyThreadOutcome(phase: phase, isNestedWorker: false) else { return }
        // ponytail: Keep alerts until a durable receipt proves same-occurrence Live Activity coverage.
        await deliver(content)
    }

    /// True when `deliver(_:)` can send a visible alert at all: a subscribed
    /// account and a registered phone push target. Without one, a paired
    /// phone's only alert is its own local notification.
    public var hasAlertPushTarget: Bool {
        guard let session = accountStore.load(), session.user.subscribed else { return false }
        return pushTargetStore.load() != nil
    }

    @discardableResult
    public func deliver(_ content: RemoteCodeNotificationContent) async -> Bool {
        guard let session = accountStore.load() else {
            recordWakeNotSent(reason: "no_session")
            return false
        }
        guard session.user.subscribed else {
            recordWakeNotSent(reason: "unsubscribed")
            return false
        }
        guard let target = pushTargetStore.load() else {
            recordWakeNotSent(reason: "no_push_target")
            return false
        }
        var alertDelivered = false
        var alertData = content.userInfo
        alertData["categoryIdentifier"] = content.categoryIdentifier
        alertData["threadIdentifier"] = content.threadIdentifier
        alertData["soundEnabled"] = content.soundEnabled ? "true" : "false"
        alertData["idempotencyKey"] = content.identifier
        let watermark = connectionHintLock.withLock { connectionHintSources }.watermark?()
        let delta = PushConnectionHints.delta(
            threadId: content.userInfo["threadId"],
            workspaceId: content.userInfo["workspaceId"],
            state: content.userInfo["outcome"],
            kind: "thread_update",
            preview: content.body,
            seq: watermark
        )
        let deliveryData = await withConnectionHints(alertData.merging(delta) { current, _ in current })
        do {
            let result = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverAlert(
                    accessToken: accessToken,
                    title: content.title,
                    body: content.body,
                    // Carry routing keys so a remote alert opens the exact thread.
                    data: deliveryData,
                    pushToken: target.pushToken,
                    pushTokenType: target.pushTokenType,
                    idempotencyKey: content.identifier,
                    silent: false
                )
            }
            if result.shouldDropSubscription {
                pushTargetStore.clear()
            }
            alertDelivered = result.delivered
        } catch {
            Self.log.error("Private push delivery failed: \(String(describing: error), privacy: .public)")
            // Alert failed: still attempt a silent wake so iOS can catch up.
            await deliverSilentCatchUp(
                hostHint: content.userInfo["workspaceId"] ?? content.identifier,
                force: true,
                coalesceClass: .other,
                delta: delta
            )
            return false
        }
        // Prefer silent wake coalescing over a second full alert. Force the
        // wake when the visible alert was not delivered so a rate-limited
        // bucket cannot swallow the only remaining catch-up path.
        await deliverSilentCatchUp(
            hostHint: content.userInfo["workspaceId"] ?? content.identifier,
            force: !alertDelivered,
            coalesceClass: .other,
            delta: delta
        )
        return alertDelivered
    }

    /// Legacy single-bucket key (pre per-class coalesce). Kept for cleanup only.
    private static let silentCatchUpLegacyBucketKey = "private.silentCatchUp.lastBucket"
    /// Per-reason-class last 30s bucket map: [coalesceClass.rawValue: bucketInt].
    private static let silentCatchUpBucketsKey = "private.silentCatchUp.lastBuckets"
    private static let silentCatchUpLock = NSLock()
    private static let silentCatchUpBucketSeconds: TimeInterval = 30

    /// Pure coalesce decision: per-class 30s buckets so attention is never
    /// swallowed by a prior run-progress wake in the same wall-clock window.
    /// Force always admits. Returns updated bucket map when send is allowed.
    public static func shouldAdmitSilentCatchUp(
        force: Bool,
        coalesceClass: MaterialWakeCoalesceClass,
        now: Date = Date(),
        lastBuckets: [String: Int]
    ) -> (shouldSend: Bool, updatedBuckets: [String: Int]) {
        let bucket = Int(now.timeIntervalSince1970 / silentCatchUpBucketSeconds)
        var updated = lastBuckets
        let classKey = coalesceClass.rawValue
        if !force, updated[classKey] == bucket {
            return (false, lastBuckets)
        }
        updated[classKey] = bucket
        return (true, updated)
    }

    /// UserDefaults returns NSNumber for ints; a raw `[String: Int]` cast fails.
    static func loadBucketMap(from defaults: UserDefaults) -> [String: Int] {
        guard let raw = defaults.dictionary(forKey: silentCatchUpBucketsKey) else { return [:] }
        var out: [String: Int] = [:]
        out.reserveCapacity(raw.count)
        for (key, value) in raw {
            if let i = value as? Int {
                out[key] = i
            } else if let n = value as? NSNumber {
                out[key] = n.intValue
            }
        }
        return out
    }

    private func recordWakeNotSent(reason: String) {
        HostWakeMetrics.shared.increment(.wakeNotSent)
        Self.log.info("wake_not_sent reason=\(reason, privacy: .public)")
    }

    /// F5: the card already shows progress, so the run-progress wake is withheld.
    private func withholdsForLiveActivity(_ coalesceClass: MaterialWakeCoalesceClass) -> Bool {
        guard coalesceClass == .runProgress, isLiveActivityActiveForPushTarget() else { return false }
        HostWakeMetrics.shared.increment(.liveActivitySuppressed)
        Self.log.info("silent_wake suppressed reason=live_activity_active class=run_progress")
        return true
    }

    private static func silentWakeBudgetDevice(_ target: PrivatePushTarget) -> String {
        guard let deviceId = target.deviceId, !deviceId.isEmpty else { return "legacy" }
        return deviceId
    }

    /// Stored delivery times of `device`. Call with `silentWakeBudgetLock` held.
    private func storedSilentWakeTimes(device: String) -> [TimeInterval] {
        guard let json = try? settings.get(Self.silentWakeBudgetKey),
              let state = try? JSONDecoder().decode(SilentWakeBudgetState.self, from: Data(json.utf8)) else { return [] }
        return state.devices[device] ?? []
    }

    /// All stored device histories. Call with `silentWakeBudgetLock` held.
    private func storedSilentWakeBudgetDevices() -> [String: [TimeInterval]] {
        guard let json = try? settings.get(Self.silentWakeBudgetKey),
              let state = try? JSONDecoder().decode(SilentWakeBudgetState.self, from: Data(json.utf8)) else { return [:] }
        return state.devices
    }

    /// F5: takes one in-flight slot of the hourly budget, or drops and logs.
    /// An admitted send must end in exactly one `settleSilentWake`.
    private func admitSilentWakeToBudget(_ coalesceClass: MaterialWakeCoalesceClass, device: String) -> Bool {
        let refusedAt: Int? = silentWakeBudgetLock.withLock { () -> Int? in
            // Always the window of the stored list, never its length: three
            // delivered wakes must not silence the phone after their hour.
            let used = MaterialWakeBudget.sentInWindow(storedSilentWakeTimes(device: device), now: Date()).count
                + (silentWakesInFlight[device] ?? 0)
            guard MaterialWakeBudget.admits(coalesceClass, used: used) else { return used }
            silentWakesInFlight[device, default: 0] += 1
            return nil
        }
        guard let refusedAt else { return true }
        HostWakeMetrics.shared.increment(.budgetDropped)
        Self.log.info(
            "silent_wake budget_dropped class=\(coalesceClass.rawValue, privacy: .public) used=\(refusedAt, privacy: .public) limit=\(MaterialWakeBudget.limit(for: coalesceClass), privacy: .public) window_s=\(Int(MaterialWakeBudget.windowSeconds), privacy: .public)"
        )
        return false
    }

    /// F5: one exit of an admitted silent send. Only a delivered one costs a slot.
    private func settleSilentWake(delivered: Bool, device: String) {
        silentWakeBudgetLock.withLock {
            let remaining = max(0, (silentWakesInFlight[device] ?? 0) - 1)
            if remaining == 0 { silentWakesInFlight.removeValue(forKey: device) }
            else { silentWakesInFlight[device] = remaining }
            guard delivered else { return }
            let deliveredAt = Date()
            var devices = storedSilentWakeBudgetDevices()
            devices[device] = MaterialWakeBudget.sentInWindow(storedSilentWakeTimes(device: device), now: deliveredAt)
                + [deliveredAt.timeIntervalSince1970]
            let state = SilentWakeBudgetState(devices: devices)
            do {
                let data = try JSONEncoder().encode(state)
                try settings.set(Self.silentWakeBudgetKey, String(decoding: data, as: UTF8.self))
            } catch {
                Self.log.error("silent_wake budget_write_failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Silent APNs background wake: iOS `didReceiveRemoteNotification` runs
    /// `BackgroundSyncCoordinator` catch-up. Coalesced per reason-class 30s
    /// bucket so an attention wake cannot be suppressed by run-progress traffic.
    /// Payload is `silent_catchup.v1` only (no agent text/titles in data).
    /// F5: every silent wake is also inside the hourly budget (`MaterialWakeBudget`); a forced wake bypasses only the 30 s bucket.
    public func deliverSilentCatchUp(
        hostHint: String = "host",
        force: Bool = false,
        payload: SilentCatchUpV1 = SilentCatchUpV1(reason: "catch_up"),
        coalesceClass: MaterialWakeCoalesceClass = .other,
        delta: [String: String] = [:]
    ) async {
        guard let session = accountStore.load() else {
            recordWakeNotSent(reason: "no_session")
            return
        }
        guard session.user.subscribed else {
            recordWakeNotSent(reason: "unsubscribed")
            return
        }
        guard let target = pushTargetStore.load() else {
            recordWakeNotSent(reason: "no_push_target")
            return
        }
        // F5: before the coalescer and the budget, so it marks no bucket and costs no slot.
        if withholdsForLiveActivity(coalesceClass) { return }
        let now = Date()
        let bucket = Int(now.timeIntervalSince1970 / Self.silentCatchUpBucketSeconds)
        // Serialize check/set: concurrent run outcomes must not both send.
        let shouldSend: Bool = {
            Self.silentCatchUpLock.lock()
            defer { Self.silentCatchUpLock.unlock() }
            let defaults = UserDefaults.standard
            // Drop legacy global key so old installs do not share one bucket forever.
            if defaults.object(forKey: Self.silentCatchUpLegacyBucketKey) != nil {
                defaults.removeObject(forKey: Self.silentCatchUpLegacyBucketKey)
            }
            let stored = Self.loadBucketMap(from: defaults)
            let decision = Self.shouldAdmitSilentCatchUp(
                force: force,
                coalesceClass: coalesceClass,
                now: now,
                lastBuckets: stored
            )
            if decision.shouldSend {
                defaults.set(decision.updatedBuckets, forKey: Self.silentCatchUpBucketsKey)
            }
            return decision.shouldSend
        }()
        if !shouldSend {
            HostWakeMetrics.shared.increment(.outboxCoalesced)
            Self.log.info(
                "silent_catchup coalesced class=\(coalesceClass.rawValue, privacy: .public) hostHint=\(hostHint, privacy: .public)"
            )
            return
        }
        // F5: `force` bypassed the 30 s bucket above; nothing bypasses the hourly budget.
        let budgetDevice = Self.silentWakeBudgetDevice(target)
        guard admitSilentWakeToBudget(coalesceClass, device: budgetDevice) else { return }
        var contract = payload
        contract.catchUp = true
        let data = await withConnectionHints(contract.asPushData().merging(delta) { current, _ in current })
        let idempotencyKey = "catchup.\(coalesceClass.rawValue).\(hostHint).\(bucket)"
        HostWakeMetrics.shared.increment(.silentAttempt)
        do {
            let result = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverAlert(
                    accessToken: accessToken,
                    title: "",
                    body: "",
                    data: data,
                    pushToken: target.pushToken,
                    pushTokenType: target.pushTokenType,
                    idempotencyKey: idempotencyKey,
                    silent: true
                )
            }
            if result.shouldDropSubscription {
                pushTargetStore.clear()
            }
            settleSilentWake(delivered: result.delivered, device: budgetDevice)
            if result.delivered {
                HostWakeMetrics.shared.increment(.silentSent)
            } else {
                // Backend may signal rate limit via non-delivered without throw.
                HostWakeMetrics.shared.increment(.silent429)
            }
        } catch {
            settleSilentWake(delivered: false, device: budgetDevice)
            HostWakeMetrics.shared.increment(.silentFailed)
            Self.log.error("Silent catch-up push failed: \(String(describing: error), privacy: .public)")
            // Durable retry only behind wake_outbox. Flag off preserves log-and-drop.
            if ConnectionFeatureFlags.wakeOutboxEnabled {
                let record = SilentWakeOutboxRecord(
                    coalesceClass: coalesceClass,
                    hostHint: hostHint,
                    force: force,
                    payload: contract,
                    idempotencyKey: idempotencyKey
                )
                do {
                    try silentWakeOutbox.accept(record)
                } catch {
                    Self.log.error(
                        "Silent catch-up outbox enqueue failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    /// Replay a durable silent catch-up record using the original idempotency key.
    func performSilentCatchUpDelivery(_ record: SilentWakeOutboxRecord) async throws {
        guard let session = accountStore.load(), session.user.subscribed else {
            throw SilentWakeOutboxError.missingSessionOrTarget
        }
        guard let target = pushTargetStore.load() else {
            throw SilentWakeOutboxError.missingSessionOrTarget
        }
        // F5: the replay is inside the same two rules. A withheld progress wake
        // is acknowledged and dropped; one the budget refuses stays queued.
        if withholdsForLiveActivity(record.coalesceClassValue) { return }
        let budgetDevice = Self.silentWakeBudgetDevice(target)
        guard admitSilentWakeToBudget(record.coalesceClassValue, device: budgetDevice) else {
            throw SilentWakeOutboxError.notDelivered("budget")
        }
        var contract = record.payload
        contract.catchUp = true
        let data = await withConnectionHints(contract.asPushData())
        HostWakeMetrics.shared.increment(.silentAttempt)
        do {
            let result = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverAlert(
                    accessToken: accessToken,
                    title: "",
                    body: "",
                    data: data,
                    pushToken: target.pushToken,
                    pushTokenType: target.pushTokenType,
                    idempotencyKey: record.idempotencyKey,
                    silent: true
                )
            }
            if result.shouldDropSubscription {
                pushTargetStore.clear()
            }
            settleSilentWake(delivered: result.delivered, device: budgetDevice)
            if result.delivered {
                HostWakeMetrics.shared.increment(.silentSent)
                return
            }
            // Non-throwing rate-limit: retry via outbox without inventing success.
            HostWakeMetrics.shared.increment(.silent429)
            throw SilentWakeOutboxError.notDelivered(result.errorCode)
        } catch let error as SilentWakeOutboxError {
            // Only the `notDelivered` thrown above arrives here, already settled.
            throw error
        } catch {
            settleSilentWake(delivered: false, device: budgetDevice)
            HostWakeMetrics.shared.increment(.silentFailed)
            throw error
        }
    }

    /// Delivers a Live Activity content-state push for a run-lifecycle boundary,
    /// mirroring `deliver(_:)`. Requires the paired iOS device to have registered
    /// a `liveActivityToken` (start-token) via `privatePushTokenUpdate`; without
    /// one there is no activity to address, so the push is skipped. The
    /// `idempotencyKey` namespaces the event (start/update/end) so a Live Activity
    /// push never collides with the alert for the same run.
    public func deliverLiveActivity(
        snapshot: PrivateLiveActivitySnapshot,
        event: PrivateLiveActivityEvent,
        idempotencyKey: String
    ) async {
        guard let session = accountStore.load(), session.user.subscribed,
              let target = pushTargetStore.load(),
              let liveActivityToken = target.liveActivityToken,
              !liveActivityToken.isEmpty else { return }
        do {
            let result = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverLiveActivity(
                    accessToken: accessToken,
                    event: event.rawValue,
                    contentState: snapshot.contentState(),
                    timestampSeconds: Int64(snapshot.updatedAt.timeIntervalSince1970),
                    liveActivityToken: liveActivityToken,
                    pushToken: target.pushToken,
                    pushTokenType: target.pushTokenType,
                    idempotencyKey: idempotencyKey
                )
            }
            if result.shouldDropSubscription {
                pushTargetStore.clear()
            }
        } catch {
            Self.log.error("Private live-activity delivery failed: \(String(describing: error), privacy: .public)")
            return
        }
    }

    public func registerLiveActivityTokenV2(_ target: PrivatePushTargetRecord) async throws {
        guard target.supportsLiveActivityV2,
              let session = accountStore.load(),
              session.user.subscribed else { throw PrivateAccountAPIError.invalidResponse }

        let tokenKind: PrivateLiveActivityV2TokenKind
        switch target.purpose {
        case .pushToStart:
            tokenKind = .pushToStart
        case .activityUpdate:
            guard target.ownership != nil else { throw LiveActivityTokenBindingError.unknownAuthoritativeScope }
            tokenKind = .update
        case .alert:
            throw PrivateAccountAPIError.invalidResponse
        }

        let ack = try await sessionRefresher.perform(session: session) { accessToken in
            try await self.api.registerLiveActivityTokenV2(
                accessToken: accessToken,
                registration: PrivateLiveActivityV2TokenRegistration(
                    deviceId: target.deviceId,
                    environment: target.environment,
                    token: target.token,
                    tokenKind: tokenKind,
                    hostId: target.ownership?.hostId,
                    bootEpoch: target.ownership?.bootEpoch,
                    activityGeneration: target.ownership?.activityGeneration,
                    activitySessionId: target.ownership?.activitySessionId,
                    activityId: target.ownership?.activityId
                )
            )
        }
        if tokenKind == .update, ack.token.ownership != target.ownership {
            throw PrivateAccountAPIError.invalidResponse
        }
    }


    /// Compatibility wrapper for callers outside the durable acceptance outbox.
    public func deliverLiveActivity(_ delivery: LiveActivitySyncDelivery) async {
        do {
            for target in try acceptanceTargets(for: delivery) {
                let record = LiveActivityAcceptanceRecord(delivery: delivery, target: target)
                _ = try await sendLiveActivityAcceptance(record)
            }
        } catch {
            Self.log.error("Private live-activity acceptance failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Resolves which device tokens should receive this delivery.
    ///
    /// Fail-open policy (so Mac updates / iOS-closed still work):
    /// 1. Exact v2 purpose match (start → push_to_start, update/end → activity_update
    ///    with matching ownership session)
    /// 2. Any activity_update for this host (newest) when exact ownership is stale
    /// 3. push_to_start tokens (content refresh when only start token is available)
    /// 4. Legacy single-device token
    ///
    /// Never throw solely because an old activity_update row exists with a dead
    /// boot epoch — that previously blocked legacy fallback after Mac relaunch.
    public func acceptanceTargets(
        for delivery: LiveActivitySyncDelivery
    ) throws -> [LiveActivityAcceptanceTarget] {
        let records = try pushTargetStore.records()
        let hostId = delivery.projection.hostId
        let preferredPurpose: PrivatePushTokenPurpose =
            delivery.event == .start ? .pushToStart : .activityUpdate

        func v2(_ purpose: PrivatePushTokenPurpose) -> [PrivatePushTargetRecord] {
            records.filter {
                $0.supportsLiveActivityV2 &&
                $0.purpose == purpose &&
                $0.serverId == hostId
            }
        }

        let preferred = v2(preferredPurpose)
        if preferredPurpose == .pushToStart {
            if !preferred.isEmpty { return preferred.map(LiveActivityAcceptanceTarget.v2) }
        } else {
            let exact = preferred.filter {
                guard let ownership = $0.ownership else { return false }
                return ownership.bootEpoch == UInt64(delivery.projection.epoch) &&
                    ownership.activityGeneration == delivery.activityGeneration &&
                    ownership.activitySessionId == delivery.projection.sessionId
            }
            if !exact.isEmpty { return exact.map(LiveActivityAcceptanceTarget.v2) }
            // Stale ownership after Mac relaunch: still try the newest update token.
            // Persistence may round adjacent registrations to the same timestamp.
            // In that tie, `upsert` order is the only remaining recency signal, so
            // track the max timestamp in place and keep the LAST record at that
            // max (later upsert order wins) — one pass, no temp array.
            var newest: PrivatePushTargetRecord?
            for record in preferred {
                if newest == nil || record.updatedAt >= newest!.updatedAt {
                    newest = record
                }
            }
            if let newest {
                return [.v2(newest)]
            }
            // No update token yet (iOS app never opened after remote start): use
            // push-to-start so content can still be pushed / re-asserted.
            let starts = v2(.pushToStart)
            if !starts.isEmpty { return starts.map(LiveActivityAcceptanceTarget.v2) }
        }

        if let legacy = pushTargetStore.load(),
           let token = legacy.liveActivityToken,
           !token.isEmpty {
            return [.legacy(legacy)]
        }
        // Last resort: any v2 push-to-start even if serverId drifted pre-rebind.
        let anyStart = records.filter {
            $0.supportsLiveActivityV2 && $0.purpose == .pushToStart
        }
        if !anyStart.isEmpty { return anyStart.map(LiveActivityAcceptanceTarget.v2) }

        throw PrivateAccountAPIError.invalidResponse
    }

    public func sendLiveActivityAcceptance(
        _ record: LiveActivityAcceptanceRecord
    ) async throws -> PrivateLiveActivityV2DeliveryAck {
        let delivery = Self.effectiveDelivery(for: record)
        guard let session = accountStore.load(), session.user.subscribed else {
            throw PrivateAccountAPIError.http(401)
        }
        switch record.target {
        case .legacy(let target):
            let legacyState = delivery.projection.legacyContentState
            guard let liveActivityToken = target.liveActivityToken, !liveActivityToken.isEmpty else {
                throw PrivateAccountAPIError.invalidResponse
            }
            let result = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverLiveActivity(
                    accessToken: accessToken,
                    event: delivery.event.rawValue,
                    contentState: legacyState,
                    timestampSeconds: Int64(legacyState.updatedAt),
                    liveActivityToken: liveActivityToken,
                    pushToken: target.pushToken,
                    pushTokenType: target.pushTokenType,
                    idempotencyKey: delivery.idempotencyKey
                )
            }
            if result.shouldDropSubscription { pushTargetStore.clear() }
            guard result.delivered else {
                throw LiveActivityAcceptanceOutboxError.backendDidNotAccept(
                    result.errorCode ?? "legacy_rejected"
                )
            }
            return PrivateLiveActivityV2DeliveryAck(
                id: delivery.idempotencyKey,
                status: "delivered",
                attempts: 1,
                nextAttemptAt: nil
            )
        case .v2(let target):
            let ack: PrivateLiveActivityV2DeliveryAck
            do {
                let request = PrivateLiveActivityV2DeliveryRequest(delivery: delivery, target: target)
                ack = try await sessionRefresher.perform(session: session) { accessToken in
                    try await self.api.deliverLiveActivityV2(
                        accessToken: accessToken,
                        request: request,
                        idempotencyKey: delivery.idempotencyKey
                    )
                }
                guard ack.isSettled else {
                    throw LiveActivityAcceptanceOutboxError.backendDidNotAccept(ack.status)
                }
            } catch {
                // User dismissed the Lock Screen card or ActivityKit ended it: the
                // activity_update token is dead. Fail over to push-to-start `.start`
                // so the next host update re-opens the Live Activity without the
                // iOS app needing to be foregrounded.
                if target.purpose == .activityUpdate,
                   delivery.event == .update || delivery.event == .start,
                   let startTarget = (try? pushTargetStore.records()).flatMap({ records in
                       records.first(where: {
                           $0.supportsLiveActivityV2 &&
                           $0.purpose == .pushToStart &&
                           $0.serverId == delivery.projection.hostId
                       }) ?? records.first(where: {
                           $0.supportsLiveActivityV2 && $0.purpose == .pushToStart
                       })
                   }) {
                    let startDelivery = LiveActivitySyncDelivery(
                        event: .start,
                        projection: delivery.projection,
                        activityGeneration: delivery.activityGeneration,
                        idempotencyKey: delivery.idempotencyKey + ".dismiss-reopen"
                    )
                    let startRecord = LiveActivityAcceptanceRecord(
                        delivery: startDelivery,
                        target: .v2(startTarget)
                    )
                    Self.log.info(
                        "live-activity update failed; reopening via push-to-start key=\(startDelivery.idempotencyKey, privacy: .public)"
                    )
                    return try await sendLiveActivityAcceptance(startRecord)
                }
                throw error
            }
            // Prune while the current courier is still protected. Doing this
            // before terminal invalidation prevents a stale historical row from
            // becoming the newly "current" protected fallback.
            do {
                _ = try pushTargetStore.pruneStaleActivityUpdateTargets()
            } catch {
                Self.log.error(
                    "Live Activity token prune failed: \(String(describing: error), privacy: .public)"
                )
            }
            // Terminal/end retires only this exact owner/device/env/activity/
            // generation/token. A delayed result for A cannot remove rotated B.
            // Persistence failure stays retryable through the durable outbox.
            if target.purpose == .activityUpdate,
               delivery.event == .end || ack.isTerminal {
                try pushTargetStore.invalidateActivityUpdateTarget(target)
            }
            return ack
        }
    }

    /// When only a push-to-start token is available, ActivityKit cannot apply
    /// content-state `update` pushes. Remap those to `start` so the Lock Screen
    /// card is created/refreshed while the iOS app is closed.
    nonisolated static func effectiveDelivery(
        for record: LiveActivityAcceptanceRecord
    ) -> LiveActivitySyncDelivery {
        let delivery = record.delivery
        guard case .v2(let target) = record.target,
              target.purpose == .pushToStart,
              delivery.event == .update else {
            return delivery
        }
        return LiveActivitySyncDelivery(
            event: .start,
            projection: delivery.projection,
            activityGeneration: delivery.activityGeneration,
            idempotencyKey: delivery.idempotencyKey + ".start-refresh"
        )
    }
}

private struct AnyEncodable: Encodable {
    private let encodeBody: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeBody = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}
