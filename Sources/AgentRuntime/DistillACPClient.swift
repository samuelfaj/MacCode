import Foundation
import CoreModel
import Persistence

public enum DistillACPError: Error, LocalizedError, CustomStringConvertible {
    case missingBinary(String)
    case spawnFailed(String)
    case invalidJSON(String)
    /// `detail` / `httpStatus` come from JSON-RPC `error.data`, where the peer puts
    /// the provider's real failure behind a generic `-32603 Internal error`.
    case rpcError(code: Int?, message: String, detail: String? = nil, httpStatus: Int? = nil)
    case processExited(reason: Process.TerminationReason, status: Int32, stderrTail: String)
    case responseTypeMismatch(String)
    case unsupported(String)
    case requestTimedOut(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .missingBinary(let binary): return "Distill ACP binary not found: \(binary)"
        case .spawnFailed(let message): return "Failed to spawn Distill ACP: \(message)"
        case .invalidJSON(let line): return "Distill ACP emitted invalid JSON: \(line)"
        case .rpcError(_, let message, let detail, _):
            return "Distill ACP RPC error: \(ACPRPCErrorPayload.describe(message: message, detail: detail))"
        case .processExited(let reason, let status, let stderr):
            let suffix = stderr.isEmpty ? "" : ". Last stderr (may precede the exit): \(stderr)"
            return "Distill ACP process exited (\(reason == .exit ? "exit" : "signal") \(status))\(suffix)"
        case .responseTypeMismatch(let method): return "Distill ACP \(method) response had an unexpected shape"
        case .unsupported(let message): return message
        case .requestTimedOut(let method): return "Distill ACP \(method) timed out"
        }
    }
}

enum DistillACPFailureContext: Sendable {
    case start
    case resume
    case turn
}

enum DistillACPFailureCategory: String, Sendable {
    case authRequired
    case rateLimited
    case network
    case timeout
    case invalidResume
    /// The provider rejected the session's own history (e.g. unsigned reasoning
    /// from another model family replayed to Anthropic as a `thinking` block).
    /// Re-sending into the same Distill session fails identically, so the
    /// adapter retires it and the next turn opens a fresh session.
    case incompatibleHistory
    case nonRecoverable
}

struct DistillACPFailure: Error, CustomStringConvertible, LocalizedError, Sendable {
    let category: DistillACPFailureCategory
    let message: String

    var description: String { message }
    var errorDescription: String? { message }
}

enum DistillACPFailureTaxonomy {
    static let authRequiredMarker = "[auth-required]"
    static let rateLimitedMarker = "[retryable:rate-limit]"
    static let networkMarker = "[retryable:network]"
    static let timeoutMarker = "[retryable:timeout]"
    static let invalidResumeMarker = "[start-fresh:invalid-resume]"
    /// Retry is safe because the adapter replaces the poisoned session; the
    /// thread (and any bot desk link) is kept.
    static let incompatibleHistoryMarker = "[fresh-session:incompatible-history]"
    static let incompatibleHistoryMarkers = [
        "invalid `signature` in `thinking` block", "invalid signature in thinking block",
        "encrypted_content", "encrypted content could not be decrypted or parsed",
        "history is incompatible", "history incompatible"
    ]
    /// Distill reports every account for the model as used up or unusable as
    /// "Authentication required"; signing in again cannot fix it.
    static let accountRouteMarkers = [
        "no available account route", "saved account route is unavailable"
    ]

    static func normalize(_ error: Error, context: DistillACPFailureContext) -> DistillACPFailure {
        if let failure = error as? DistillACPFailure { return failure }
        return normalizedFailure(
            category: category(for: error, context: context),
            diagnostic: String(describing: error)
        )
    }

    static func normalize(diagnostic: String, context: DistillACPFailureContext) -> DistillACPFailure {
        normalizedFailure(
            category: category(forDiagnostic: diagnostic, context: context),
            diagnostic: diagnostic
        )
    }

    private static func normalizedFailure(
        category: DistillACPFailureCategory,
        diagnostic: String
    ) -> DistillACPFailure {
        let safeDiagnostic = sanitize(diagnostic)
        let prefix: String
        switch category {
        case .authRequired:
            prefix = "\(authRequiredMarker) Distill authentication failed"
        case .rateLimited where accountRouteMarkers.contains(where: diagnostic.lowercased().contains):
            prefix = "\(rateLimitedMarker) No Distill account can serve this model now (quota used up or unavailable). Choose Auto or another model, or wait for the quota reset"
        case .rateLimited:
            prefix = "\(rateLimitedMarker) Distill rate limit"
        case .network:
            prefix = "\(networkMarker) Distill network failure"
        case .timeout:
            prefix = "\(timeoutMarker) Distill request timed out"
        case .invalidResume:
            prefix = "\(invalidResumeMarker) Distill invalid resume"
        case .incompatibleHistory:
            prefix = "\(incompatibleHistoryMarker) The model rejected this Distill session's history; Retry starts a new Distill session"
        case .nonRecoverable:
            prefix = "Distill ACP failure"
        }
        return DistillACPFailure(category: category, message: "\(prefix): \(safeDiagnostic)")
    }

    private static func category(
        for error: Error,
        context: DistillACPFailureContext
    ) -> DistillACPFailureCategory {
        if let error = error as? DistillACPError {
            switch error {
            case .requestTimedOut:
                return .timeout
            case .processExited(let reason, let status, _)
                where reason == .uncaughtSignal || (128...255).contains(status):
                // A killed process may retain a recovered API error in stderr.
                // The signal (including docker's 128 + signal exit) is authoritative.
                return .nonRecoverable
            case .rpcError(let code, let message, let detail, let httpStatus):
                let described = ACPRPCErrorPayload.describe(message: message, detail: detail).lowercased()
                if accountRouteMarkers.contains(where: described.contains) { return .rateLimited }
                // The JSON-RPC code is -32603 for every provider failure; the
                // provider's HTTP status rides in error.data.http_status.
                for status in [httpStatus, code].compactMap({ $0 }) {
                    if status == 401 || status == 403 { return .authRequired }
                    if status == 429 { return .rateLimited }
                    // Provider outage or overload: transient, resumed automatically.
                    if [500, 502, 503, 504, 529].contains(status) { return .network }
                }
                return category(
                    forDiagnostic: ACPRPCErrorPayload.describe(message: message, detail: detail),
                    context: context
                )
            default:
                break
            }
        }
        return category(forDiagnostic: String(describing: error), context: context)
    }

    private static func category(
        forDiagnostic diagnostic: String,
        context: DistillACPFailureContext
    ) -> DistillACPFailureCategory {
        let normalized = diagnostic.lowercased()
        if normalized.contains(incompatibleHistoryMarker) { return .incompatibleHistory }
        if normalized.contains(invalidResumeMarker) { return .invalidResume }
        if normalized.contains(authRequiredMarker) { return .authRequired }
        if normalized.contains(rateLimitedMarker) { return .rateLimited }
        if normalized.contains(timeoutMarker) { return .timeout }
        if normalized.contains(networkMarker) { return .network }
        if incompatibleHistoryMarkers.contains(where: normalized.contains) { return .incompatibleHistory }
        if accountRouteMarkers.contains(where: normalized.contains) { return .rateLimited }
        let invalidResumeMarkers = [
            "invalid resume", "invalid_resume", "invalid-resume", "resume invalid",
            "resume is invalid", "resume cursor", "failed to resume",
            "could not be resumed", "session/load failed", "session not found"
        ]
        if invalidResumeMarkers.contains(where: normalized.contains) {
            return .invalidResume
        }
        if context == .resume,
           normalized.contains("invalid session") || normalized.contains("unknown session") {
            return .invalidResume
        }
        // 402 Payment Required: harness balance exhausted is not retryable
        // or auth-required — surface it verbatim so the host can circuit-break
        // and the mirror can show the real cause. Must precede auth/rate checks
        // so "402 Payment" isn't mis-tagged as auth.
        if normalized.contains("402") && normalized.contains("payment") {
            return .nonRecoverable
        }
        if normalized.contains("balance exhausted") || normalized.contains("usage balance") {
            return .nonRecoverable
        }
        if normalized.contains("payment required") {
            return .nonRecoverable
        }
        let authMarkers = [
            "unauthorized", "unauthenticated", "authentication required", "login required",
            "sign in required", "token expired", "credential expired", "invalid_api_key",
            "invalid api key", "forbidden"
        ]
        if authMarkers.contains(where: normalized.contains) { return .authRequired }
        let rateLimitMarkers = ["rate limit", "rate_limit", "too many requests", "http 429"]
        if rateLimitMarkers.contains(where: normalized.contains) { return .rateLimited }
        let timeoutMarkers = ["timed out", "timeout", "deadline exceeded"]
        if timeoutMarkers.contains(where: normalized.contains) { return .timeout }
        let networkMarkers = [
            "network error", "network failure", "connection refused", "connection reset",
            "connection closed", "host unreachable", "dns failure", "socket error",
            "transport error", "error sending request", "websocket closed", "offline",
            "stream error (overloaded_error)", "stream error (service_unavailable_error)",
            "service unavailable", "temporarily unavailable", "bad gateway", "overloaded",
            "status 500", "status 502", "status 503", "status 504", "status 529"
        ]
        if networkMarkers.contains(where: normalized.contains) { return .network }
        return .nonRecoverable
    }

    // PERF: compile once — sanitize runs on every distill failure normalize and
    // recompiled 5 NSRegularExpressions via replacingOccurrences each call.
    private static let whitespaceCollapseRegex = try! NSRegularExpression(
        pattern: #"\s+"#
    )
    private static let ansiControlRegex = try! NSRegularExpression(
        pattern: #"\x1B\[[0-?]*[ -/]*[@-~]"#
    )
    private static let diagnosticRedactions: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(
            pattern: #"(authorization\s*[:=]\s*bearer\s+)[^\s,;]+"#,
            options: [.caseInsensitive]
        ), "$1<redacted>"),
        (try! NSRegularExpression(
            pattern: #"\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            options: [.caseInsensitive]
        ), "Bearer <redacted>"),
        (try! NSRegularExpression(
            pattern: #"\b(api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+"#,
            options: [.caseInsensitive]
        ), "$1=<redacted>"),
        (try! NSRegularExpression(
            pattern: #"(?:file://)?/(?:Users|home|private|var|tmp|Volumes|opt|usr|etc)/[^\s,;]+"#,
            options: [.caseInsensitive]
        ), "<path>"),
    ]

    private static func sanitize(_ raw: String) -> String {
        let plainText = replaceAll(ansiControlRegex, in: raw, with: "")
        var text = replaceAll(whitespaceCollapseRegex, in: plainText, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for (regex, template) in diagnosticRedactions {
            text = replaceAll(regex, in: text, with: template)
        }
        if text.isEmpty { text = "Provider reported an error." }
        // Keep the terminal's final cause as well as the error context, after redaction.
        return text.count <= 800 ? text : "\(text.prefix(400)) … \(text.suffix(397))"
    }

    private static func replaceAll(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

public enum DistillACPRequestID: Hashable, Sendable {
    case int(Int)
    case string(String)

    init?(_ value: Any?) {
        if let value = value as? Int { self = .int(value) }
        else if let value = value as? String, !value.isEmpty { self = .string(value) }
        else { return nil }
    }

    public var jsonValue: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    public var stringValue: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// The distill agent stdio advertises `promptCapabilities.image=false` but still
/// accepts `type=image` prompt blocks end-to-end (live canary: 0.2.x, 1.0.x and
/// 2.0.53, which answered an image-only question correctly).
/// Use one effective gate for both capability advertisement and prompt embedding
/// so iOS Camera/Photos stay aligned with the wire path.
/// Copies prompt images to `/tmp/maccode-attachments`, readable by every local
/// user, so a run under another macOS user can still open the path it is given.
public enum DistillPromptImageStaging {
    public static let root = URL(fileURLWithPath: "/tmp/maccode-attachments", isDirectory: true)

    public static func stage(path: String, fileManager: FileManager = .default) throws -> String {
        let source = URL(fileURLWithPath: path)
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw DistillACPError.unsupported("Attached image is missing: \(source.lastPathComponent)")
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        try? fileManager.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: root.path)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        try fileManager.copyItem(at: source, to: target)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        return target.path
    }
}

public enum DistillACPImageCompatibility {
    public static let supportedImageMediaTypes = [
        "image/jpeg", "image/png", "image/gif", "image/webp"
    ]

    /// Prefer the negotiated flag; for known-compatible agent versions override
    /// a false advertisement. Unknown versions fail closed when not advertised.
    public static func effectiveImageEnabled(advertised: Bool, agentVersion: String?) -> Bool {
        if advertised { return true }
        let version = agentVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return false }
        // Verified families accept image blocks despite image=false: 0.2.x, 1.0.x, 2.x.
        return version.hasPrefix("0.2.") || version.hasPrefix("1.0.") || version.hasPrefix("2.")
    }
}

public struct DistillACPInitializeResult: Sendable, Equatable {
    public let protocolVersion: Int
    public let loadSession: Bool
    public let embeddedContext: Bool
    public let image: Bool
    public let audio: Bool
    public let resumeSession: Bool
    /// `x.ai/capabilities.sessionWorkerModel`: per-session Worker model + independent effort.
    public let sessionWorkerModel: Bool
    public let agentVersion: String?
    public let models: [AgentModelDescriptor]
    public let currentModelId: String?

    public init(
        protocolVersion: Int,
        loadSession: Bool,
        embeddedContext: Bool,
        image: Bool = false,
        audio: Bool = false,
        resumeSession: Bool = false,
        sessionWorkerModel: Bool = false,
        agentVersion: String? = nil,
        models: [AgentModelDescriptor] = [],
        currentModelId: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.loadSession = loadSession
        self.embeddedContext = embeddedContext
        self.image = image
        self.audio = audio
        self.resumeSession = resumeSession
        self.sessionWorkerModel = sessionWorkerModel
        self.agentVersion = agentVersion
        self.models = models
        self.currentModelId = currentModelId
    }

    static func parse(_ result: [String: Any]) throws -> DistillACPInitializeResult {
        guard let version = result["protocolVersion"] as? Int, version == 1 else {
            throw DistillACPError.unsupported("Distill ACP protocol version 1 is required")
        }
        let capabilities = result["agentCapabilities"] as? [String: Any] ?? [:]
        let prompt = capabilities["promptCapabilities"] as? [String: Any] ?? [:]
        let sessions = capabilities["sessionCapabilities"] as? [String: Any] ?? [:]
        let capabilityMetadata = capabilities["_meta"] as? [String: Any] ?? [:]
        let xaiCapabilities = capabilityMetadata["x.ai/capabilities"] as? [String: Any] ?? [:]
        let metadata = result["_meta"] as? [String: Any] ?? [:]
        let modelState = metadata["modelState"] as? [String: Any]
        return DistillACPInitializeResult(
            protocolVersion: version,
            loadSession: capabilities["loadSession"] as? Bool ?? false,
            embeddedContext: prompt["embeddedContext"] as? Bool ?? false,
            image: prompt["image"] as? Bool ?? false,
            audio: prompt["audio"] as? Bool ?? false,
            resumeSession: sessions["resume"] != nil,
            sessionWorkerModel: xaiCapabilities["sessionWorkerModel"] as? Bool ?? false,
            agentVersion: metadata["agentVersion"] as? String,
            models: DistillACPClient.modelDescriptors(from: modelState),
            currentModelId: modelState?["currentModelId"] as? String
        )
    }
}

public struct DistillACPAvailableCommand: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let hint: String?

    public init(name: String, description: String?, hint: String? = nil) {
        self.name = name
        self.description = description
        self.hint = hint
    }
}

public struct DistillACPPermissionOption: Sendable, Equatable {
    public let optionId: String
    public let name: String
    public let kind: String
}

public struct DistillACPPermissionRequest: Sendable {
    public let requestId: DistillACPRequestID
    public let sessionId: String
    public let toolCallId: String
    public let title: String
    public let detail: String?
    public let options: [DistillACPPermissionOption]

    static func parse(id: DistillACPRequestID, params: Any?) throws -> DistillACPPermissionRequest {
        guard let params = params as? [String: Any],
              let sessionId = params["sessionId"] as? String,
              let tool = params["toolCall"] as? [String: Any],
              let toolCallId = tool["toolCallId"] as? String else {
            throw DistillACPError.responseTypeMismatch("session/request_permission")
        }
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { raw -> DistillACPPermissionOption? in
            guard let optionId = raw["optionId"] as? String,
                  let name = raw["name"] as? String,
                  let kind = raw["kind"] as? String else { return nil }
            return DistillACPPermissionOption(optionId: optionId, name: name, kind: kind)
        }
        guard !options.isEmpty else { throw DistillACPError.responseTypeMismatch("session/request_permission options") }
        return DistillACPPermissionRequest(
            requestId: id,
            sessionId: sessionId,
            toolCallId: toolCallId,
            title: tool["title"] as? String ?? "Distill tool request",
            detail: Self.jsonString(tool["rawInput"]),
            options: options
        )
    }

    public func optionId(for response: AgentProviderRequestResponse) -> String? {
        let kind: String
        switch response {
        case .approve: kind = "allow_once"
        case .approveForSession: kind = "allow_always"
        case .decline: kind = "reject_once"
        case .cancel: return nil
        }
        return options.first { $0.kind == kind }?.optionId
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return value as? String }
        return String(data: data, encoding: .utf8)
    }
}

struct DistillACPSessionMode: Equatable {
    let id: String
    let name: String
    let description: String?
}

struct DistillACPSessionOpenResult {
    let sessionId: String
    let models: [AgentModelDescriptor]
    var currentModelId: String?
    /// Live current effort: `configOptions.reasoning_effort.currentValue` when
    /// present, else model `_meta.reasoningEffort` (may differ from option default).
    let currentReasoningEffortRaw: String?
    let availableModes: [DistillACPSessionMode]
    let currentModeId: String?
    /// Typed ACP `configOptions` from session/new|load (model + reasoning_effort).
    let configOptions: [[String: Any]]
    /// Set only after the session explicitly acknowledges a role-effort bind.
    var appliedMainEffortSelection: AgentEffortSelection? = nil
    var appliedMainModelId: String? = nil
    /// Set only after the session actor confirms the Worker model and its effort policy.
    var appliedReasoningModelEffortSelection: AgentEffortSelection? = nil

    /// Live catalog efforts for one model; the static policy only knows a few ids.
    func catalogEfforts(for modelId: String?) -> [AgentReasoningEffort] {
        DistillACPClient.advertisedEfforts(
            for: modelId,
            catalog: Dictionary(
                models.map { ($0.id, $0.supportedReasoningEfforts) },
                uniquingKeysWith: { first, _ in first }
            ),
            currentModelId: currentModelId,
            currentModelEfforts: advertisedReasoningEffortIds.compactMap(AgentReasoningEffort.init(rawValue:))
        )
    }

    /// True when session/new|load advertised a selectable `reasoning_effort` option.
    var advertisesReasoningEffortConfig: Bool {
        !advertisedReasoningEffortIds.isEmpty
    }

    var planModeId: String? {
        availableModes.first {
            $0.id.caseInsensitiveCompare("plan") == .orderedSame
                || $0.name.caseInsensitiveCompare("plan") == .orderedSame
        }?.id
    }

    /// Effort ids advertised on the `reasoning_effort` config option, when present.
    /// Live distill builds that list from the *session* current model. When
    /// the process default is not the host model (deepseek `max`/`none` vs
    /// grok-4.6 `low|medium|high|xhigh`), intersect with the current model's
    /// `_meta.reasoningEfforts` so stale ads cannot bind.
    var advertisedReasoningEffortIds: [String] {
        guard let option = configOptions.first(where: {
            (($0["id"] as? String) ?? ($0["configId"] as? String)) == "reasoning_effort"
        }) else { return [] }
        let values = option["options"] as? [[String: Any]]
            ?? option["values"] as? [[String: Any]]
            ?? []
        let fromConfig = values.compactMap { raw -> String? in
            let id = (raw["value"] as? String) ?? (raw["id"] as? String)
            let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let trimmedModel = currentModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelIds = (models.first { $0.id == trimmedModel } ?? models.first)?
            .supportedReasoningEfforts.map(\.rawValue) ?? []
        guard !modelIds.isEmpty else { return fromConfig }
        let allowed = Set(modelIds)
        let intersected = fromConfig.filter { allowed.contains($0) }
        return intersected.isEmpty ? modelIds : intersected
    }
}

public enum DistillACPTerminalClassifier {
    /// ACP session/prompt `stopReason` wire tokens (distill / xai-grok-pager).
    /// Completed-class: end_turn, max_tokens, max_turn_requests, refusal.
    public static func status(stopReason: String) -> AgentRunStatus {
        switch stopReason {
        case "end_turn", "max_tokens", "max_turn_requests", "refusal":
            return .completed
        case "cancelled":
            return .cancelled
        default:
            return .failed
        }
    }

    /// True for stop reasons that successfully complete the turn (not failed/cancelled).
    public static func isCompletedStopReason(_ stopReason: String) -> Bool {
        status(stopReason: stopReason) == .completed
    }

    public static func status(
        promptResolved: Bool,
        cancelRequested: Bool,
        forcedKillByUs: Bool,
        terminationReason: Process.TerminationReason,
        exitStatus: Int32
    ) -> AgentRunStatus {
        if promptResolved { return .completed }
        if cancelRequested && forcedKillByUs { return .cancelled }
        if terminationReason == .uncaughtSignal || exitStatus != 0 { return .failed }
        return .failed
    }
}

public final class DistillACPClient: @unchecked Sendable {
    public typealias JSONObject = [String: Any]
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: Any?) -> Void
    public typealias ServerRequestHandler = @Sendable (_ id: DistillACPRequestID, _ method: String, _ params: Any?) async throws -> Any?

    private struct Pending {
        let operationId: String?
        let sessionId: String?
        var sequence: Int = 0
        let resume: @Sendable (Result<Any?, Error>) -> Void
    }
    static let operationMethod = "_remotecode/operation"
    private var operationStatusEnabled = false
    private var operationRevision = 0
    public var supportsOperationStatus: Bool { lock.withLock { operationStatusEnabled } }
    var operationPollInterval: TimeInterval = 5
    var operationResponseTimeout: TimeInterval = 10

    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let parseQueue = DispatchQueue(label: "remotecode.distill-acp.parse")
    private let parseQueueKey = DispatchSpecificKey<UInt8>()
    private let writeQueue = DispatchQueue(label: "remotecode.distill-acp.write")
    private let lock = NSLock()
    private let lineBuffer = LineBuffer()
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var stderrBuffer = Data()
    private var modelCatalog: [AgentModelDescriptor] = []
    private var modelCatalogAdvertised = false
    var guestCatalogRecovery: (@Sendable () async throws -> Bool)?
    var guestCatalogRecoveryFinished: (@Sendable (Bool) -> Void)?
    private var stopped = false
    /// Set on `writeQueue` once stdin is closed; later writes fail instead of
    /// reaching a descriptor number the system may have reused.
    private var inputClosed = false
    private let foreignUserUID: uid_t?
    private let mcpEnvironment: [String: String]
    /// Set when this client drives an in-guest run through `docker exec`.
    private let guest: DistillGuestLaunchPlan?
    private static let stderrLimit = 8_192

    public var notificationHandler: NotificationHandler?
    public var serverRequestHandler: ServerRequestHandler?
    public var terminationHandler: (@Sendable (_ reason: Process.TerminationReason, _ status: Int32, _ error: Error) -> Void)?
    public var runningProcess: Process { process }

    /// Exact argv for every Distill ACP stdio launch.
    /// `--no-leader` keeps the worker isolated from shared-leader auth that
    /// requires a `client_id` RemoteCode does not supply (harness 0.2.112+).
    /// Unsupported shared-leader mode must fail through the existing error path.
    public static let launchArguments = ["agent", "--no-leader", "stdio"]

    /// Exact process argv for the closed sam-grok-worker runtime profile.
    /// Every raw guard is enforced by the harness process itself before ACP starts.
    static func launchArguments(for request: AgentRunRequest) throws -> [String] {
        guard request.environment[AgentAppRuntimeProfile.environmentKey]
                == AgentAppRuntimeProfile.samGrokWorkerV1.rawValue else {
            // Regular ACP path: model/effort are AgentArgs under the `agent`
            // subcommand (cli.rs + run_agent_command). Flags before
            // `agent` bind top-level PagerArgs and are discarded on dispatch —
            // live: `grok --reasoning-effort low agent …` stays default high;
            // `grok agent --reasoning-effort low …` seeds low (GROK-ACP-008).
            // Shape: agent [--model M] [--reasoning-effort E] --no-leader stdio.
            var args: [String] = ["agent"]
            let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                args.append(contentsOf: ["--model", model])
            }
            if let effort = request.reasoningEffort,
               DistillRunner.modelSupportsReasoningEffort(model) {
                args.append(contentsOf: DistillRunner.effortArgs(effort, model: model))
            }
            args.append(contentsOf: ["--no-leader", "stdio"])
            return args
        }
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.provider == .distill,
              request.providerThreadId == nil,
              request.permissionMode == .autoAcceptEdits,
              let effort = request.reasoningEffort,
              Self.admitsSamGrokWorker(model: model, effort: effort) else {
            throw DistillACPError.unsupported(
                "invalid sam-grok-worker Agent App runtime profile"
            )
        }
        // Top-level-only flags stay before `agent` (PagerArgs / main.rs
        // no_auto_update handoff). AgentArgs-owned model/effort/yolo must
        // follow `agent` or they never seed the stdio session.
        return [
            "--no-memory",
            "--no-subagents",
            "--disallowed-tools", "Agent",
            "--no-auto-update",
            "--sandbox", "workspace",
            "agent",
            "--model", model,
            "--reasoning-effort", effort.rawValue,
            "--always-approve",
            "--no-leader",
            "stdio"
        ]
    }

    public convenience init(
        binary: String = DistillProvisioner.binaryName,
        cwd: String,
        environment: [String: String] = [:],
        launchArguments: [String] = DistillACPClient.launchArguments,
        runAsUser: AgentRunAsUser? = nil,
        askpassPath: String? = nil,
        tagProcess: Bool = true,
        notificationHandler: NotificationHandler? = nil,
        serverRequestHandler: ServerRequestHandler? = nil
    ) throws {
        let resolved = binary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DistillProvisioner.binaryName
            : binary
        guard let path = ProcessLocator.resolveDistillAgentForRunAsUser(resolved, runAsUser: runAsUser) else {
            throw DistillACPError.missingBinary(resolved)
        }
        let process: Process
        do {
            process = try ProviderSubprocessLauncher.makeProcess(
                provider: .distill,
                executablePath: path,
                arguments: launchArguments,
                currentDirectory: cwd,
                environment: Self.launchEnvironment(environment),
                runAsUser: runAsUser,
                askpassPath: askpassPath
            )
        } catch {
            throw DistillACPError.spawnFailed(error.localizedDescription)
        }
        try self.init(
            process: process,
            foreignUserUID: runAsUser.flatMap { $0.uid == getuid() ? nil : $0.uid },
            mcpEnvironment: environment,
            guest: nil,
            tagProcess: tagProcess,
            notificationHandler: notificationHandler,
            serverRequestHandler: serverRequestHandler
        )
    }

    /// In-guest run: the child is the docker CLI (`plan.dockerArguments`), a
    /// same-user process with the app's own environment, which the CLI needs to
    /// reach the daemon. The run's environment is only in the env file.
    public convenience init(
        guest plan: DistillGuestLaunchPlan,
        notificationHandler: NotificationHandler? = nil,
        serverRequestHandler: ServerRequestHandler? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.dockerExecutable)
        process.arguments = plan.dockerArguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        process.environment = ProcessInfo.processInfo.environment
        try self.init(
            process: process,
            foreignUserUID: nil,
            mcpEnvironment: [:],
            guest: plan,
            tagProcess: true,
            notificationHandler: notificationHandler,
            serverRequestHandler: serverRequestHandler
        )
    }

    private init(
        process: Process,
        foreignUserUID: uid_t?,
        mcpEnvironment: [String: String],
        guest: DistillGuestLaunchPlan?,
        tagProcess: Bool,
        notificationHandler: NotificationHandler?,
        serverRequestHandler: ServerRequestHandler?
    ) throws {
        self.process = process
        self.notificationHandler = notificationHandler
        self.serverRequestHandler = serverRequestHandler
        self.foreignUserUID = foreignUserUID
        self.mcpEnvironment = mcpEnvironment
        self.guest = guest
        parseQueue.setSpecific(key: parseQueueKey, value: 1)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            parseQueue.async {
                for line in self.lineBuffer.take(data) { self.handleLine(line) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            parseQueue.async {
                self.stderrBuffer.append(data)
                if self.stderrBuffer.count > Self.stderrLimit {
                    self.stderrBuffer.removeFirst(self.stderrBuffer.count - Self.stderrLimit)
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let error = DistillACPError.processExited(
                reason: process.terminationReason,
                status: process.terminationStatus,
                stderrTail: self.stderrTail()
            )
            // Settle the turn before waking its prompt waiter. Both paths report
            // transport failure; waking first races two visible error emissions.
            self.terminationHandler?(process.terminationReason, process.terminationStatus, error)
            self.failPending(error)
        }
        do {
            try process.run()
            if tagProcess {
                try ProcessSpawnTagger.tagProcess(
                    process,
                    provider: .distill,
                    foreignUserLaunch: foreignUserUID != nil
                )
            }
        }
        catch { throw DistillACPError.spawnFailed(error.localizedDescription) }
    }

    deinit { stop() }

    /// A bot's computer is its guest (bot-computer/-browser MCPs), not this
    /// Mac, so a bot run must not import the user's Mac-only MCPs (cua,
    /// cua-driver, computer-use-mcp from `~/.claude.json`, plus Cursor's).
    /// Non-bot runs keep the user's MCPs untouched.
    ///
    /// Known gap: MCPs declared in `~/.distill/config.toml` (mac-use,
    /// playwright, ...) still load on this Mac-side launch path; no env toggle
    /// or GROK_CONFIG overlay disables them. They go away with the guest-only
    /// DISTILL_HOME planned for in-VM execution, not a per-bot home here
    /// (that would copy the user's provider credentials).
    ///
    /// Bot runs also pin Distill's reply style over any host value: `full`
    /// for a caveman Bot, `lite` (articles, full sentences) otherwise.
    static func launchEnvironment(_ environment: [String: String]) -> [String: String] {
        guard BotRunMCPAdmission.isBotRun(environment: environment) else { return environment }
        return environment
            .merging(BotRunMCPAdmission.distillUserMCPImportOffEnvironment) { _, off in off }
            .merging(BotRunMCPAdmission.distillBotReplyStyleEnvironment(environment: environment)) { _, forced in forced }
    }

    public static func initializeParams(clientVersion: String) -> JSONObject {
        [
            "protocolVersion": 1,
            "clientCapabilities": ["_meta": ["remotecode/operationStatusV1": true]],
            "clientInfo": ["name": "RemoteCode", "title": "RemoteCode", "version": clientVersion]
        ]
    }

    public func initialize(clientVersion: String = "0.0.0", timeout: TimeInterval = 15) async throws -> DistillACPInitializeResult {
        var result = try await requestJSONObject(method: "initialize", params: Self.initializeParams(clientVersion: clientVersion), timeout: timeout)
        if let meta = result["_meta"] as? JSONObject,
           meta["remotecode/operationStatusV1"] as? Bool == true {
            lock.withLock { operationStatusEnabled = true }
            if meta["remotecode/readyRequired"] as? Bool == true {
                result = try await requestJSONObject(method: "_remotecode/ready", params: [:], timeout: timeout)
            }
        }
        let initialized = try DistillACPInitializeResult.parse(result)
        lock.withLock {
            modelCatalog = initialized.models
            modelCatalogAdvertised = !initialized.models.isEmpty
                || (result["_meta"] as? JSONObject)?["modelState"] != nil
        }
        return initialized
    }

    static let modelCatalogListMethod = "_x.ai/models/list"

    func refreshModelCatalog() async throws -> [AgentModelDescriptor] {
        let result = try await requestJSONObject(method: Self.modelCatalogListMethod, params: [:], timeout: 10)
        let descriptors = Self.modelDescriptors(from: (result["result"] as? JSONObject) ?? result)
        guard !descriptors.isEmpty else {
            throw DistillACPError.unsupported("Distill model catalog refresh returned no models")
        }
        lock.withLock { modelCatalog = descriptors; modelCatalogAdvertised = true }
        return descriptors
    }

    func resolveSelectedModel(_ selected: String?, catalog: [AgentModelDescriptor]) async throws -> String? {
        let value = selected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        return try await resolveSelectedModels([value], catalog: catalog)[value]
    }

    private func takeGuestCatalogRecovery() -> (@Sendable () async throws -> Bool)? {
        lock.withLock {
            defer { guestCatalogRecovery = nil }
            return guestCatalogRecovery
        }
    }

    private func resolveSelectedModels(_ selections: [String], catalog: [AgentModelDescriptor] = []) async throws -> [String: String] {
        let snapshot = lock.withLock { (catalog.isEmpty ? modelCatalog : catalog, modelCatalogAdvertised) }
        if selections.isEmpty {
            if snapshot.1 && snapshot.0.isEmpty {
                do { _ = try await refreshModelCatalog() }
                catch {
                    let originalError = error
                    let category = DistillACPFailureTaxonomy.normalize(error, context: .start).category
                    guard category != .authRequired, category != .rateLimited,
                          let guestCatalogRecovery = takeGuestCatalogRecovery() else { throw originalError }
                    do {
                        try Task.checkCancellation()
                        guard try await guestCatalogRecovery() else { throw originalError }
                        try Task.checkCancellation()
                        _ = try await refreshModelCatalog()
                        guestCatalogRecoveryFinished?(true)
                    } catch is CancellationError { throw CancellationError() }
                    catch { guestCatalogRecoveryFinished?(false); throw originalError }
                }
            }
            return [:]
        }
        guard snapshot.1 || !snapshot.0.isEmpty else {
            return Dictionary(uniqueKeysWithValues: Set(selections).map { ($0, $0) })
        }
        var models = snapshot.0
        var resolutionError: Error?
        if selections.contains(where: { Self.matchingModels($0, in: models).isEmpty }) {
            do {
                models = try await refreshModelCatalog()
            } catch {
                resolutionError = DistillACPError.unsupported("Could not refresh the Distill catalog for the selected model. Retry while connected. (\(error.localizedDescription))")
            }
        }
        func validate(_ catalog: [AgentModelDescriptor]) throws -> [String: String] {
            var resolved = [String: String]()
            for selection in selections {
                let matches = Self.matchingModels(selection, in: catalog)
                guard matches.count == 1, let model = matches.first else {
                    if selection == "auto" {
                        throw DistillACPError.unsupported("Auto is not available in this Distill session. Open Auto profile to check that it is enabled, saved, and has a connected account.")
                    }
                    if matches.isEmpty, guest != nil {
                        throw DistillACPError.unsupported("The Distill in this bot's Linux VM does not list the model '\(selection)'. The model picker shows the Mac's catalog, which can list models the Linux VM does not. Select another model for this bot.")
                    }
                    let reason = matches.isEmpty ? "is not advertised" : "matches multiple advertised models"
                    throw DistillACPError.unsupported("Selected Distill model '\(selection)' \(reason). Refresh the model catalog and select one exact model.")
                }
                resolved[selection] = model.id
            }
            return resolved
        }
        do {
            if let resolutionError { throw resolutionError }
            return try validate(models)
        } catch {
            let originalError = resolutionError ?? error
            let selectedMissingModel = selections.contains { selection in
                Self.matchingModels(selection, in: models).isEmpty
            }
            let category = DistillACPFailureTaxonomy.normalize(originalError, context: .start).category
            guard category != .authRequired, category != .rateLimited,
                  selectedMissingModel || (snapshot.1 && models.isEmpty),
                  selections.allSatisfy({ Self.matchingModels($0, in: models).count <= 1 }),
                  let guestCatalogRecovery = takeGuestCatalogRecovery() else { throw originalError }
            do {
                try Task.checkCancellation()
                guard try await guestCatalogRecovery() else { throw originalError }
                try Task.checkCancellation()
                models = try await refreshModelCatalog()
                let resolved = try validate(models)
                guestCatalogRecoveryFinished?(true)
                return resolved
            } catch is CancellationError { throw CancellationError() }
            catch { guestCatalogRecoveryFinished?(false); throw originalError }
        }
    }

    public static func sessionMCPServers(
        existing: [Any] = [],
        command: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Any] {
        let resolved = command
            ?? AgentSkillInstaller.resolveServiceBinary()?.path
            ?? ComputerUseMCPAdmit.fallbackCommand
        // Both providers use ACP's stdio MCP server format and preserve the
        // current host-authoritative bot grants.
        let withSelfConfig = BotSelfConfigMCPAdmit.admitGrokACP(
            existing: existing,
            command: resolved,
            environment: environment
        )
        // bot-computer/-browser/-web only work for a bot caller; a non-bot
        // Agent App session must not be offered tools that always fail.
        let isBotRun = BotRunMCPAdmission.isBotRun(environment: environment)
        let withBrowser = isBotRun
            ? BotBrowserMCPAdmit.admitGrokACP(
                existing: withSelfConfig,
                command: resolved,
                environment: environment
            )
            : withSelfConfig
        let withWeb = isBotRun
            ? BotWebMCPAdmit.admitGrokACP(
                existing: withBrowser,
                command: resolved,
                environment: environment
            )
            : withBrowser
        let withComputer = isBotRun
            ? BotComputerMCPAdmit.admitGrokACP(
                existing: withWeb,
                command: resolved,
                environment: environment
            )
            : withWeb
        guard environment[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey] == "1" else {
            return withComputer
        }
        return ComputerUseMCPAdmit.admitGrokACP(existing: withComputer, command: resolved)
    }

    /// ACP `session/new` cwd must be an existing absolute path. Empty or
    /// relative values (workspace-less bot threads falling through to
    /// `FileManager.default.currentDirectoryPath`) are `-32602 Invalid params`
    /// (`Path is not absolute`).
    public static func resolvedSessionCwd(
        _ cwd: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/"), fileExists(trimmed) {
            return trimmed
        }
        return home
    }

    /// A guest run's cwd is a guest path (checked by the resolver against the
    /// guest's mounts); the Mac `fileExists` fallback would turn it into the
    /// Mac home.
    private func sessionCwd(_ cwd: String) -> String {
        guest?.guestCwd ?? Self.resolvedSessionCwd(cwd)
    }

    /// A guest run's MCP servers are its `config.toml` (in-guest tools and the
    /// host gateway); the Mac stdio servers cannot run inside the guest.
    private func sessionMCPServers() -> [Any] {
        guest == nil ? Self.sessionMCPServers(environment: mcpEnvironment) : []
    }

    /// Prefix-aware sam-grok-worker admission: grok-4.5 and grok-4.6 only,
    /// with effort taken from `DistillReasoningPolicy.supportedEfforts(for:)`.
    public static func admitsSamGrokWorker(model: String, effort: AgentReasoningEffort) -> Bool {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("grok-4.5") || id.hasPrefix("grok-4.6") else { return false }
        return DistillReasoningPolicy.supportedEfforts(for: model).contains(effort)
    }

    /// ACP `session/new` / `session/load` params. `yoloMode` is spawn-time
    /// always-approve (harness `_meta.yoloMode`); `noReplay` is the existing
    /// load-path skip. Both share one `_meta` object so neither replaces the other.
    /// `autoMode` is intentionally omitted: RemoteCode autoAcceptEdits maps to
    /// `set_mode acceptEdits`, not harness auto. Distill selects the session
    /// model and reasoning effort through the harness `_meta.modelId` / `_meta.reasoningEffort` contract.
    /// `rules` is the harness `_meta.rules` system-prompt append (session/new only).
    static func sessionOpenParams(
        cwd: String,
        mcpServers: [Any],
        sessionId: String? = nil,
        yoloMode: Bool = false,
        noReplay: Bool = false,
        modelId: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil,
        rules: String? = nil
    ) -> JSONObject {
        var params: JSONObject = [
            "cwd": cwd,
            "mcpServers": mcpServers,
        ]
        if let sessionId {
            params["sessionId"] = sessionId
        }
        var meta: JSONObject = [:]
        if yoloMode {
            meta["yoloMode"] = true
        }
        if noReplay {
            meta["noReplay"] = true
        }
        let trimmedModel = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedModel.isEmpty {
            meta["modelId"] = trimmedModel
        }
        if let reasoningEffort,
           let wire = trimmedModel == "auto" ? reasoningEffort.rawValue : wireReasoningEffort(reasoningEffort, modelId: trimmedModel) {
            meta["reasoningEffort"] = wire
        }
        if let rules, !rules.isEmpty {
            meta["rules"] = rules
        }
        if !meta.isEmpty {
            params["_meta"] = meta
        }
        return params
    }

    func newSession(
        cwd: String,
        yoloMode: Bool = false,
        modelId: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil,
        mainEffortSelection: AgentEffortSelection? = nil,
        reasoningModel: String? = nil,
        reasoningModelEffortSelection: AgentEffortSelection? = nil,
        reasoningModelSelectionSupported: Bool = true,
        rules: String? = nil
    ) async throws -> DistillACPSessionOpenResult {
        let requestedMain = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedWorker = reasoningModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selections = [requestedMain, reasoningModelSelectionSupported ? requestedWorker : nil].compactMap { $0 }.filter { !$0.isEmpty }
        let resolved = try await resolveSelectedModels(selections)
        let modelId = requestedMain.flatMap { resolved[$0] ?? ($0.isEmpty ? nil : $0) }
        let reasoningModel = requestedWorker.map { resolved[$0] ?? $0 }
        let result = try await requestJSONObject(
            method: "session/new",
            params: Self.sessionOpenParams(
                cwd: sessionCwd(cwd),
                mcpServers: sessionMCPServers(),
                yoloMode: yoloMode,
                modelId: modelId,
                reasoningEffort: reasoningEffort,
                rules: rules
            ),
            timeout: 20
        )
        var opened = try Self.openResult(result, fallbackSessionId: nil)
        let isAuto = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) == "auto"
        if isAuto { opened.appliedMainModelId = "auto" }
        if let mainEffortSelection {
            let requestedModel = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mainModelId = requestedModel.isEmpty ? (opened.currentModelId ?? "") : requestedModel
            let applied = try await setModel(
                sessionId: opened.sessionId,
                modelId: mainModelId,
                reasoningEffort: mainEffortSelection.effort,
                reasoningEffortAuto: mainEffortSelection.isAutomatic,
                advertisedEfforts: opened.catalogEfforts(for: isAuto ? opened.currentModelId : mainModelId)
            )
            guard !isAuto || applied.canonicalModelId == "auto",
                  applied.isAutomatic == mainEffortSelection.isAutomatic,
                  mainEffortSelection.effort == nil || applied.effort == mainEffortSelection.effort else {
                throw DistillACPError.unsupported("Distill did not confirm the requested Main-model effort")
            }
            opened.currentModelId = applied.activeModelId
            opened.appliedMainModelId = applied.canonicalModelId
            if applied.canonicalModelId != nil {
                opened.appliedMainEffortSelection = mainEffortSelection
            }
        }
        if reasoningModelSelectionSupported && !isAuto {
            let applied = try await setReasoningModel(
                sessionId: opened.sessionId,
                modelId: reasoningModel,
                effortSelection: reasoningModelEffortSelection,
                advertisedEfforts: opened.catalogEfforts(for: reasoningModel)
            )
            if applied.modelId == nil || applied.isAutomatic {
                opened.appliedReasoningModelEffortSelection = .automatic
            } else if let effort = applied.effort {
                opened.appliedReasoningModelEffortSelection = .fixed(effort)
            } else {
                throw DistillACPError.responseTypeMismatch("Worker model effort acknowledgement")
            }
        }
        return opened
    }

    /// When `noReplay` is true, params include `_meta.noReplay` (harness
    /// mvp_agent `parse_no_replay`) so the agent skips gateway history replay.
    /// Default false preserves full replay for recover/readThread paths.
    /// When `yoloMode` is true, params also include `_meta.yoloMode` so cold
    /// load re-stamps always-approve for the resident session.
    func loadSession(
        sessionId: String,
        cwd: String,
        noReplay: Bool = false,
        yoloMode: Bool = false,
        modelId: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil,
        mainEffortSelection: AgentEffortSelection? = nil,
        reasoningModel: String? = nil,
        reasoningModelEffortSelection: AgentEffortSelection? = nil,
        reasoningModelSelectionSupported: Bool = true
    ) async throws -> DistillACPSessionOpenResult {
        let requestedMain = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedWorker = reasoningModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selections = [requestedMain, reasoningModelSelectionSupported ? requestedWorker : nil].compactMap { $0 }.filter { !$0.isEmpty }
        let resolved = try await resolveSelectedModels(selections)
        let modelId = requestedMain.flatMap { resolved[$0] ?? ($0.isEmpty ? nil : $0) }
        let reasoningModel = requestedWorker.map { resolved[$0] ?? $0 }
        let params = Self.sessionOpenParams(
            cwd: sessionCwd(cwd),
            mcpServers: sessionMCPServers(),
            sessionId: sessionId,
            yoloMode: yoloMode,
            noReplay: noReplay,
            modelId: modelId,
            reasoningEffort: reasoningEffort
        )
        let result = try await requestJSONObject(
            method: "session/load",
            params: params,
            timeout: 60
        )
        var opened = try Self.openResult(result, fallbackSessionId: sessionId)
        let isAuto = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) == "auto"
        if isAuto { opened.appliedMainModelId = "auto" }
        if let mainEffortSelection {
            let requestedModel = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mainModelId = requestedModel.isEmpty ? (opened.currentModelId ?? "") : requestedModel
            let applied = try await setModel(
                sessionId: opened.sessionId,
                modelId: mainModelId,
                reasoningEffort: mainEffortSelection.effort,
                reasoningEffortAuto: mainEffortSelection.isAutomatic,
                advertisedEfforts: opened.catalogEfforts(for: isAuto ? opened.currentModelId : mainModelId)
            )
            guard !isAuto || applied.canonicalModelId == "auto",
                  applied.isAutomatic == mainEffortSelection.isAutomatic,
                  mainEffortSelection.effort == nil || applied.effort == mainEffortSelection.effort else {
                throw DistillACPError.unsupported("Distill did not confirm the requested Main-model effort")
            }
            opened.currentModelId = applied.activeModelId
            opened.appliedMainModelId = applied.canonicalModelId
            if applied.canonicalModelId != nil {
                opened.appliedMainEffortSelection = mainEffortSelection
            }
        }
        if reasoningModelSelectionSupported && !isAuto {
            let applied = try await setReasoningModel(
                sessionId: opened.sessionId,
                modelId: reasoningModel,
                effortSelection: reasoningModelEffortSelection,
                advertisedEfforts: opened.catalogEfforts(for: reasoningModel)
            )
            if applied.modelId == nil || applied.isAutomatic {
                opened.appliedReasoningModelEffortSelection = .automatic
            } else if let effort = applied.effort {
                opened.appliedReasoningModelEffortSelection = .fixed(effort)
            } else {
                throw DistillACPError.responseTypeMismatch("Worker model effort acknowledgement")
            }
        }
        return opened
    }

    /// Efforts the live session advertises for `modelId`: its catalog entry
    /// (exact id, else the one canonical/alias match — the catalog says
    /// `chatgpt/gpt-6-luna` while set_model acks `gpt-6-luna`), plus the
    /// session `reasoning_effort` option when `modelId` is the session's
    /// current model (some builds advertise efforts only there).
    static func advertisedEfforts(
        for modelId: String?,
        catalog: [String: [AgentReasoningEffort]],
        currentModelId: String?,
        currentModelEfforts: [AgentReasoningEffort]
    ) -> [AgentReasoningEffort] {
        let id = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { return [] }
        var efforts = catalog[id] ?? {
            let aliases = catalog.filter { modelIdsMatch($0.key, id) }
            return aliases.count == 1 ? aliases.first?.value ?? [] : []
        }()
        if let currentModelId, modelIdsMatch(currentModelId, id) {
            efforts += currentModelEfforts.filter { !efforts.contains($0) }
        }
        return efforts
    }

    static func matchingModels(_ value: String, in models: [AgentModelDescriptor]) -> [AgentModelDescriptor] {
        let exact = models.filter { $0.id == value }
        if !exact.isEmpty { return exact }
        guard !value.contains("/") else { return [] }
        return models.filter { model in
            let id = model.id
            return id.hasSuffix("/" + value) && id.split(separator: "/").count == 2
        }
    }

    /// Same model when equal or when one is the other's provider-qualified form.
    static func modelIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasSuffix("/" + b) || b.hasSuffix("/" + a)
    }

    /// Model-aware ACP value. Nil means the selected model does not advertise
    /// reasoning configuration, so no acknowledgement can honestly be claimed.
    static func wireReasoningEffort(
        _ effort: AgentReasoningEffort,
        modelId: String = "",
        advertisedEfforts: [AgentReasoningEffort] = []
    ) -> String? {
        if advertisedEfforts.contains(effort) {
            return effort.rawValue
        }
        return DistillRunner.normalizedReasoningEffort(effort, model: modelId)?.rawValue
    }

    /// The result is the selection actually applied by the Distill session actor.
    struct ReasoningModelSelectionResult: Equatable {
        let modelId: String?
        let effort: AgentReasoningEffort?
        let isAutomatic: Bool
    }

    /// Distill extension that forks a saved session into a new session id.
    /// ACP extension methods travel with a leading `_` (the agent strips it
    /// before dispatch); without it Distill answers "Method not found".
    static let sessionForkMethod = "_x.ai/session/fork"
    /// Distill extension that deletes a session (used to compensate a fork).
    static let sessionDeleteMethod = "_x.ai/session/delete"
    /// Distill extension that answers a side question without interrupting the turn.
    static let btwMethod = "_x.ai/btw"

    /// Forks `sourceSessionId` into `newSessionId`. `kind` is `"fork"` or `"side"`.
    /// Passing an existing `newSessionId` is what makes a retried fork converge.
    func forkSession(
        sourceSessionId: String,
        sourceCwd: String,
        newCwd: String,
        newSessionId: String,
        kind: String = "fork",
        targetPromptIndex: Int? = nil
    ) async throws -> String {
        var params: JSONObject = [
            "sourceSessionId": sourceSessionId,
            "sourceCwd": sourceCwd,
            "newCwd": newCwd,
            "newSessionId": newSessionId,
            "sessionKind": kind
        ]
        if let targetPromptIndex { params["targetPromptIndex"] = targetPromptIndex }
        let response = try await requestJSONObject(
            method: Self.sessionForkMethod,
            params: params,
            timeout: 30
        )
        guard let newId = (response["newSessionId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !newId.isEmpty else {
            throw DistillACPError.unsupported("Distill x.ai/session/fork omitted newSessionId")
        }
        return newId
    }

    /// Deletes a session. Distill treats deleting a missing session as success, so this is idempotent.
    func deleteSession(sessionId: String, cwd: String?) async throws {
        var params: JSONObject = ["sessionId": sessionId]
        if let cwd, !cwd.isEmpty { params["cwd"] = cwd }
        _ = try await requestJSONObject(
            method: Self.sessionDeleteMethod,
            params: params,
            timeout: 30
        )
    }

    /// Side question against a live session; returns the answer without touching the active turn.
    func btw(sessionId: String, question: String) async throws -> String {
        let response = try await requestJSONObject(
            method: Self.btwMethod,
            params: ["sessionId": sessionId, "question": question],
            timeout: 180
        )
        // Distill wraps the answer: `{"result": {"answer": "…"}}`.
        let nested = response["result"] as? JSONObject
        guard let answer = (response["answer"] as? String) ?? (nested?["answer"] as? String) else {
            throw DistillACPError.responseTypeMismatch(Self.btwMethod)
        }
        return answer
    }

    /// Distill extension method that toggles this session's Ultracode orchestration mode.
    static let ultracodeSetMethod = "_x.ai/session/ultracode/set"
    /// Sets Ultracode on or off; returns the state Distill confirmed.
    @discardableResult
    func setUltracode(sessionId: String, enabled: Bool) async throws -> Bool {
        let response = try await requestJSONObject(
            method: Self.ultracodeSetMethod,
            params: ["sessionId": sessionId, "enabled": enabled],
            timeout: 15
        )
        let nested = response["result"] as? JSONObject
        guard let applied = (response["enabled"] as? Bool) ?? (nested?["enabled"] as? Bool),
              applied == enabled else {
            throw DistillACPError.unsupported("Distill did not confirm the requested Ultracode mode; prompt was not sent.")
        }
        return applied
    }

    /// Distill extension method that selects the session's one exclusive execution mode.
    static let executionModeSetMethod = "_x.ai/session/execution_mode/set"
    /// Selects `mode`; returns the choice Distill confirmed (Auto, Normal, UltraFast, UltraCode or UltraSave).
    /// Auto replies with the effective fixed `mode` plus `choice: "auto"`; older peers send only `mode`.
    @discardableResult
    func setExecutionMode(sessionId: String, mode: DistillExecutionMode) async throws -> DistillExecutionMode {
        let response = try await requestJSONObject(
            method: Self.executionModeSetMethod,
            params: ["sessionId": sessionId, "mode": mode.rawValue],
            timeout: 15
        )
        let nested = response["result"] as? JSONObject
        let raw = (response["choice"] as? String) ?? (nested?["choice"] as? String)
            ?? (response["mode"] as? String) ?? (nested?["mode"] as? String)
        guard let applied = raw.flatMap(DistillExecutionMode.init(rawValue:)), applied == mode else {
            throw DistillACPError.unsupported("Distill did not confirm \(mode.displayName) mode; prompt was not sent.")
        }
        return applied
    }
    /// Distill extension method that deletes a scheduled (`/loop`) task.
    static let schedulerDeleteMethod = "_x.ai/scheduler/delete"
    /// True when Distill deleted the task (`{"result":{"deleted":true}}` nested or flat).
    func schedulerDelete(sessionId: String, taskId: String) async throws -> Bool {
        let response = try await requestJSONObject(
            method: Self.schedulerDeleteMethod,
            params: ["sessionId": sessionId, "taskId": taskId],
            timeout: 15
        )
        if let nested = response["result"] as? JSONObject, let deleted = nested["deleted"] as? Bool { return deleted }
        return response["deleted"] as? Bool ?? false
    }

    /// Distill extension method that binds this session's Worker model.
    static let workerModelSetMethod = "_x.ai/session/worker_model/set"

    /// Selects or explicitly disables (`""`) this conversation's Worker model.
    /// Effort is `"auto"` or a level; nil inherits the Distill config.
    func setReasoningModel(
        sessionId: String,
        modelId: String?,
        effortSelection: AgentEffortSelection? = nil,
        advertisedEfforts: [AgentReasoningEffort] = []
    ) async throws -> ReasoningModelSelectionResult {
        let trimmedModel = try await resolveSelectedModel(modelId, catalog: []) ?? ""
        let effortValue: Any
        if let effortSelection, !trimmedModel.isEmpty {
            if let effort = effortSelection.effort {
                guard let wire = Self.wireReasoningEffort(
                    effort, modelId: trimmedModel, advertisedEfforts: advertisedEfforts
                ) else {
                    throw DistillACPError.unsupported("Selected Worker model does not advertise that effort")
                }
                effortValue = wire
            } else {
                effortValue = "auto"
            }
        } else {
            effortValue = NSNull()
        }
        let response = try await requestJSONObject(
            method: Self.workerModelSetMethod,
            params: ["sessionId": sessionId, "modelId": trimmedModel, "effort": effortValue],
            timeout: 15
        )
        let appliedModel = (response["modelId"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        guard appliedModel == (trimmedModel.isEmpty ? nil : trimmedModel) else {
            throw DistillACPError.unsupported("Distill did not confirm the requested Worker model")
        }
        let acknowledgedEffort = (response["effort"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isAutomatic = acknowledgedEffort == nil || acknowledgedEffort == "auto"
        let appliedEffort = acknowledgedEffort.flatMap(AgentReasoningEffort.init(rawValue:))
        if let effortSelection, !trimmedModel.isEmpty {
            guard acknowledgedEffort != nil,
                  isAutomatic == effortSelection.isAutomatic,
                  effortSelection.effort == nil || appliedEffort == effortSelection.effort else {
                throw DistillACPError.unsupported("Distill did not confirm the requested Worker-model effort")
            }
        }
        return ReasoningModelSelectionResult(modelId: appliedModel, effort: appliedEffort, isAutomatic: isAutomatic)
    }

    struct MainModelSelectionResult: Equatable {
        let canonicalModelId: String?
        let activeModelId: String
        let effort: AgentReasoningEffort?
        let isAutomatic: Bool
    }

    /// Binds a Main model and its concrete or automatic effort policy atomically.
    func setModel(
        sessionId: String,
        modelId: String,
        reasoningEffort: AgentReasoningEffort? = nil,
        reasoningEffortAuto: Bool? = nil,
        advertisedEfforts: [AgentReasoningEffort] = []
    ) async throws -> MainModelSelectionResult {
        let modelId = try await resolveSelectedModel(modelId, catalog: []) ?? modelId
        var params: JSONObject = ["sessionId": sessionId, "modelId": modelId]
        var meta: JSONObject = [:]
        if let reasoningEffortAuto {
            meta["reasoningEffortAuto"] = reasoningEffortAuto
        }
        if let reasoningEffort {
            // Auto chooses its route while binding; the previous route's catalog is not authoritative.
            guard let wireEffort = modelId == "auto" ? reasoningEffort.rawValue : Self.wireReasoningEffort(
                reasoningEffort, modelId: modelId, advertisedEfforts: advertisedEfforts
            ) else {
                throw DistillACPError.unsupported("Selected Main model does not advertise that effort")
            }
            meta["reasoningEffort"] = wireEffort
        }
        if !meta.isEmpty { params["_meta"] = meta }
        // Model binding can await session readiness and account credentials, as session/load does.
        let response = try await requestJSONObject(method: "session/set_model", params: params, timeout: 60)
        let resultMeta = response["_meta"] as? JSONObject ?? response["meta"] as? JSONObject ?? response
        // Distill 2.0.25 serializes the switch result as `{"Ok": "<model>"}` / `{"Err": "<reason>"}`.
        let rawModel = resultMeta["model"]
        if let failure = (rawModel as? JSONObject)?["Err"] {
            throw DistillACPError.unsupported("Distill rejected Main model \(modelId): \(failure)")
        }
        let activeModelId = ((rawModel as? String) ?? ((rawModel as? JSONObject)?["Ok"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let activeModelId, !activeModelId.isEmpty else {
            throw DistillACPError.responseTypeMismatch("session/set_model model acknowledgement")
        }
        let serverCanonicalModelId = (resultMeta["canonicalModelId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let serverCanonicalModelId, serverCanonicalModelId != modelId {
            throw DistillACPError.unsupported("Distill confirmed Main model \(serverCanonicalModelId), not requested \(modelId)")
        }
        // Distill 2.0.24 answers only `{model, contextWindow}`: success is the acknowledgement.
        let canonicalModelId = serverCanonicalModelId ?? modelId
        let acknowledgedAuto = resultMeta["reasoningEffortAuto"] as? Bool
        if let reasoningEffortAuto, let acknowledgedAuto, acknowledgedAuto != reasoningEffortAuto {
            throw DistillACPError.unsupported("Distill did not confirm the requested Main effort mode")
        }
        let acknowledgedEffort = (resultMeta["reasoningEffort"] as? String)
            .flatMap(AgentReasoningEffort.init(rawValue:))
        if let reasoningEffort, let acknowledgedEffort, acknowledgedEffort != reasoningEffort {
            throw DistillACPError.unsupported("Distill did not confirm the requested Main-model effort")
        }
        return MainModelSelectionResult(
            canonicalModelId: canonicalModelId,
            activeModelId: activeModelId,
            effort: acknowledgedEffort ?? reasoningEffort,
            isAutomatic: acknowledgedAuto ?? (reasoningEffortAuto ?? false)
        )
    }

    /// Flat-string `session/set_config_option` (live grok 1.0.25+). Nested
    /// `{value:{value}}` and `optionId` shapes still return `-32602`.
    func setConfigOption(
        sessionId: String,
        configId: String,
        value: String
    ) async throws {
        _ = try await requestJSONObject(
            method: "session/set_config_option",
            params: [
                "sessionId": sessionId,
                "configId": configId,
                "value": value,
            ],
            timeout: 15
        )
    }

    /// Pure routing for model/effort binds before a prompt.
    /// Prefer flat `session/set_config_option` for effort-only binds when the
    /// open result advertised `reasoning_effort` (live grok 1.0.25). Fall back
    /// to `session/set_model` + `_meta.reasoningEffort` for older agents /
    /// missing configOptions (1.0.13 rejected set_config_option).
    enum ModelEffortBind: Equatable {
        case none
        case setModel(modelId: String, reasoningEffort: AgentReasoningEffort?)
        case setConfigOption(configId: String, value: String, effort: AgentReasoningEffort)
    }

    static func modelEffortBind(
        requestModel: String,
        sessionModel: String,
        requestEffort: AgentReasoningEffort?,
        sessionEffort: AgentReasoningEffort?,
        prefersConfigOptionEffort: Bool = false,
        advertisedEfforts: [AgentReasoningEffort] = []
    ) -> ModelEffortBind {
        let model = requestModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetModel = model.isEmpty ? sessionModel : model
        // session/new|load ads are not refreshed after setModel; keep only
        // efforts the target model still supports so grok-4.6 xhigh cannot
        // skip the grok-4.5 clamp. Empty ads still fall through to
        // DistillRunner.normalizedReasoningEffort (muse-spark empty _meta).
        let supported = DistillReasoningPolicy.supportedEfforts(for: targetModel)
        let targetEffort = requestEffort.flatMap { requested -> AgentReasoningEffort? in
            if advertisedEfforts.contains(requested), supported.contains(requested) {
                return requested
            }
            return DistillRunner.normalizedReasoningEffort(requested, model: targetModel)
        }
        let needsModelBind = !model.isEmpty && model != sessionModel
        let needsEffortBind = targetEffort != sessionEffort
        if needsModelBind {
            return .setModel(modelId: targetModel, reasoningEffort: targetEffort)
        }
        if needsEffortBind, let targetEffort,
           let wire = wireReasoningEffort(
            targetEffort, modelId: targetModel, advertisedEfforts: advertisedEfforts
           ) {
            if prefersConfigOptionEffort {
                return .setConfigOption(
                    configId: "reasoning_effort",
                    value: wire,
                    effort: targetEffort
                )
            }
            return .setModel(modelId: targetModel, reasoningEffort: targetEffort)
        }
        return .none
    }

    func setMode(sessionId: String, modeId: String) async throws {
        _ = try await requestJSONObject(method: "session/set_mode", params: ["sessionId": sessionId, "modeId": modeId], timeout: 15)
    }

    func prompt(
        sessionId: String,
        request: AgentRunRequest,
        capabilities: DistillACPInitializeResult,
        writePermit: AgentRunAcceptancePermit,
        contextHandoff: String? = nil,
        beforeWrite: @escaping @Sendable () throws -> Void,
        onAccepted: @escaping @Sendable () throws -> Void
    ) async throws -> JSONObject {
        try await requestJSONObject(
            method: "session/prompt",
            params: ["sessionId": sessionId, "prompt": try Self.promptBlocks(
                for: request,
                capabilities: capabilities,
                contextHandoff: contextHandoff,
                guest: guest != nil
            )],
            timeout: nil,
            acceptancePermit: request.acceptancePermit,
            writePermit: writePermit,
            beforeWrite: beforeWrite,
            onAccepted: onAccepted
        )
    }

    public func cancel(sessionId: String) throws {
        try notify(method: "session/cancel", params: ["sessionId": sessionId])
    }

    /// Serializes generation admission with the physical cancel write. If a
    /// newer prompt has already reached this write queue, `admittedBy` observes
    /// its newer generation and the stale cancel never reaches ACP. If cancel
    /// wins the queue, its line is written before that newer prompt line.
    @discardableResult
    func cancel(
        sessionId: String,
        admittedBy: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        try write(
            ["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionId]],
            admittedBy: admittedBy
        )
    }

    public func notify(method: String, params: Any? = nil) throws {
        var payload: JSONObject = ["jsonrpc": "2.0", "method": method]
        if let params { payload["params"] = params }
        try write(payload)
    }

    public func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        guard shouldStop else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            ProcessTerminator.terminateTree(
                process,
                foreignUserUID: foreignUserUID
            )
        }
        // The guest process outlives its docker exec client.
        if let guest {
            Task.detached { await guest.killGuest() }
        }
    }

    /// Ends the ACP stream with EOF and waits up to `timeout` for the process
    /// to exit by itself. Distill then runs its normal session shutdown, which
    /// flushes the session's durable records; `stop()` (TERM) skips it.
    /// Returns whether the process exited in time.
    @discardableResult
    func closeInputAndWaitForExit(timeout: TimeInterval) async -> Bool {
        writeQueue.sync {
            guard !inputClosed else { return }
            inputClosed = true
            try? stdinPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    public func stopImmediatelyForAppTermination() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        guard shouldStop else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            ProcessTerminator.terminateTreeImmediately(
                process,
                foreignUserUID: foreignUserUID
            )
        }
        guest?.killGuestDetached()
    }

    /// `contextHandoff` seeds the first prompt of a replacement session with the
    /// app's own record of the earlier conversation. It rides in its own block so
    /// a `/command` prompt stays the first block Distill parses.
    /// A `guest` run gets no RemoteCode host-catalog paragraph: the guest
    /// gateway does not offer the `rc_*` tools it names.
    public static func promptBlocks(
        for request: AgentRunRequest,
        capabilities: DistillACPInitializeResult,
        contextHandoff: String? = nil,
        guest: Bool = false
    ) throws -> [JSONObject] {
        var blocks: [JSONObject] = []
        let handoff = contextHandoff?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Distill owns mode semantics natively; send human text without generic provider prose.
        let providerPrompt = request.prompt
        // Additive: background-await self-declare marker so shell-detached
        // orchestration stalls reach the host's [[RC_AWAITING]] recovery path.
        // systemPromptDirective only — NOT alwaysOnClaudeDirectives (MCP rules
        // are Claude-CLI-specific).
        let alwaysOn = BotPeerDelegation.appendingTurnContext(
            to: BackgroundAwaitContinuation.systemPromptDirective
                + "\n\n" + (guest ? BotPeerDelegation.peerDirective : BotPeerDelegation.providerDirective),
            environment: request.environment
        )
        if providerPrompt.drop(while: { $0.isWhitespace }).hasPrefix("/") {
            // Distill parses `/name args` from the FIRST text block only, so the
            // directive rides in its own following block to keep args exact.
            blocks.append(["type": "text", "text": providerPrompt])
            if !handoff.isEmpty { blocks.append(["type": "text", "text": handoff]) }
            if !alwaysOn.isEmpty { blocks.append(["type": "text", "text": alwaysOn]) }
        } else {
            if !handoff.isEmpty { blocks.append(["type": "text", "text": handoff]) }
            let composed = providerPrompt.isEmpty
                ? alwaysOn
                : providerPrompt + "\n\n" + alwaysOn
            if !composed.isEmpty { blocks.append(["type": "text", "text": composed]) }
        }
        var imagePaths: [String] = []
        for attachment in request.attachments {
            switch attachment.kind {
            case .image where !guest:
                // Distill reads the file itself, so the prompt carries only a path.
                imagePaths.append(try DistillPromptImageStaging.stage(path: attachment.path))
            case .image:
                // A guest VM cannot see host paths, so it still gets the bytes.
                guard DistillACPImageCompatibility.effectiveImageEnabled(
                    advertised: capabilities.image,
                    agentVersion: capabilities.agentVersion
                ) else {
                    throw DistillACPError.unsupported(
                        "Distill ACP \(capabilities.agentVersion ?? "v1") does not support image prompts"
                    )
                }
                let payload: AgentAttachmentWireImage.Payload
                do {
                    payload = try AgentAttachmentWireImage.encode(
                        path: attachment.path,
                        mimeType: attachment.mimeType ?? "application/octet-stream"
                    )
                } catch let error as AgentAttachmentWireImage.EncodeError {
                    throw DistillACPError.unsupported(error.description)
                }
                blocks.append([
                    "type": "image",
                    "data": payload.data.base64EncodedString(),
                    "mimeType": payload.mediaType
                ])
            case .file:
                guard capabilities.embeddedContext else {
                    throw DistillACPError.unsupported("Distill ACP does not negotiate embedded file context")
                }
                let prefix: EmbeddedFilePrefix
                do {
                    prefix = try embeddedUTF8FilePrefix(
                        path: attachment.path,
                        displayName: attachment.displayName
                    )
                } catch let error as EmbeddedFilePrefixError {
                    throw DistillACPError.unsupported(error.description)
                }
                blocks.append([
                    "type": "resource",
                    "resource": [
                        "uri": URL(fileURLWithPath: attachment.path).absoluteString,
                        "mimeType": attachment.mimeType ?? "text/plain",
                        "text": prefix.wireText
                    ]
                ])
            }
        }
        if !imagePaths.isEmpty {
            let list = imagePaths.map { "- \($0)" }.joined(separator: "\n")
            blocks.append(["type": "text", "text": "Attached images (read these files):\n" + list])
        }
        return blocks
    }

    static let embeddedFilePrefixBytes = 512 * 1_024

    struct EmbeddedFilePrefix: Equatable {
        let text: String
        let originalByteCount: Int
        let truncated: Bool
        let path: String

        var wireText: String {
            guard truncated else { return text }
            return text
                + "\n\n[truncated: showing first \(DistillACPClient.embeddedFilePrefixBytes) of \(originalByteCount) bytes; full file remains at \(path)]"
        }
    }

    enum EmbeddedFilePrefixError: Error, CustomStringConvertible, Equatable {
        case notUTF8(String)

        var description: String {
            switch self {
            case .notUTF8(let displayName):
                return "Distill ACP embedded context requires UTF-8 text: \(displayName)"
            }
        }
    }

    static func embeddedUTF8FilePrefix(
        path: String,
        displayName: String,
        maxPrefixBytes: Int = embeddedFilePrefixBytes
    ) throws -> EmbeddedFilePrefix {
        let url = URL(fileURLWithPath: path)
        let originalByteCount: Int
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber {
            originalByteCount = size.intValue
        } else {
            originalByteCount = 0
        }
        let maxPrefixBytes = max(1, maxPrefixBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: maxPrefixBytes) ?? Data()
        guard let text = Self.utf8StringAllowingPartialTail(prefix) else {
            throw EmbeddedFilePrefixError.notUTF8(displayName)
        }
        return EmbeddedFilePrefix(
            text: text,
            originalByteCount: max(originalByteCount, prefix.count),
            truncated: originalByteCount > maxPrefixBytes,
            path: path
        )
    }

    private static func utf8StringAllowingPartialTail(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        var trimmed = data
        for _ in 0..<3 {
            guard !trimmed.isEmpty else { break }
            trimmed.removeLast()
            if let text = String(data: trimmed, encoding: .utf8) { return text }
        }
        return nil
    }

    private func requestJSONObject(
        method: String,
        params: Any?,
        timeout: TimeInterval?,
        acceptancePermit: AgentRunAcceptancePermit? = nil,
        writePermit: AgentRunAcceptancePermit? = nil,
        beforeWrite: (@Sendable () throws -> Void)? = nil,
        onAccepted: (@Sendable () throws -> Void)? = nil
    ) async throws -> JSONObject {
        let value: Any? = try await request(
            method: method,
            params: params,
            timeout: timeout,
            acceptancePermit: acceptancePermit,
            writePermit: writePermit,
            beforeWrite: beforeWrite,
            onAccepted: onAccepted
        )
        guard let object = value as? JSONObject else { throw DistillACPError.responseTypeMismatch(method) }
        return object
    }

    private func request(
        method: String,
        params: Any?,
        timeout: TimeInterval?,
        acceptancePermit: AgentRunAcceptancePermit? = nil,
        writePermit: AgentRunAcceptancePermit? = nil,
        beforeWrite: (@Sendable () throws -> Void)? = nil,
        onAccepted: (@Sendable () throws -> Void)? = nil,
        stopOnTimeout: Bool = true
    ) async throws -> Any? {
        let id = reserveId()
        let monitored = supportsOperationStatus && ["_remotecode/ready", "session/new", "session/load", "session/resume", "session/prompt"].contains(method)
        let operationId = monitored ? UUID().uuidString : nil
        var requestParams = params
        if let operationId {
            var object = params as? JSONObject ?? [:]
            var meta = object["_meta"] as? JSONObject ?? [:]
            meta["remotecode/operationId"] = operationId
            object["_meta"] = meta
            requestParams = object
        }
        let sessionId = (requestParams as? JSONObject)?["sessionId"] as? String
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = Pending(operationId: operationId, sessionId: sessionId) { continuation.resume(with: $0) }
            lock.unlock()
            var payload: JSONObject = ["jsonrpc": "2.0", "id": id, "method": method]
            if let requestParams { payload["params"] = requestParams }
            do {
                if let onAccepted {
                    let writeAndAccept = {
                        try beforeWrite?()
                        let queueGuardedWrite = {
                            if let acceptancePermit {
                                try acceptancePermit.withAcceptance(failureOutcome: .notAccepted) {
                                    try self.write(payload)
                                }
                            } else {
                                try self.write(payload)
                            }
                        }
                        if let writePermit {
                            try writePermit.withAcceptance(failureOutcome: .notAccepted, queueGuardedWrite)
                        } else {
                            try queueGuardedWrite()
                        }
                        try onAccepted()
                    }
                    if DispatchQueue.getSpecific(key: parseQueueKey) != nil {
                        try writeAndAccept()
                    } else {
                        try parseQueue.sync(execute: writeAndAccept)
                    }
                } else {
                    try write(payload)
                }
            }
            catch { completePending(id: id, result: .failure(error)) }
            if let operationId {
                Task { [weak self] in await self?.monitorOperation(id: id, operationId: operationId, method: method) }
            } else if let timeout {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    if self.completePending(id: id, result: .failure(DistillACPError.requestTimedOut(method))), stopOnTimeout { self.stop() }
                }
            }
        }
    }

    /// Poll through the real ACP dispatcher. Heartbeats never advance the progress clock.
    private func monitorOperation(id: Int, operationId: String, method: String) async {
        while lock.withLock({ pending[id] != nil && !stopped }) {
            try? await Task.sleep(nanoseconds: UInt64(operationPollInterval * 1_000_000_000))
            guard lock.withLock({ pending[id] != nil && !stopped }) else { return }
            do {
                let result = try await request(
                    method: "_remotecode/status", params: ["operationId": operationId],
                    timeout: operationResponseTimeout, stopOnTimeout: false
                )
                guard lock.withLock({ pending[id] != nil && !stopped }) else { return }
                guard let payload = result as? JSONObject,
                      payload["operationId"] as? String == operationId,
                      payload["state"] as? String == "running",
                      acceptOperationStatus(payload) else {
                    throw DistillACPError.unsupported("Distill did not provide evidence for the pending \(method) operation")
                }
            } catch {
                guard lock.withLock({ pending[id] != nil && !stopped }) else { return }
                let failure = DistillACPError.unsupported(
                    "Distill ACP stopped responding during \(method). Status probe: \(error.localizedDescription)"
                )
                // Claim the terminal before waking request continuations, as on process exit.
                terminationHandler?(.exit, -1, failure)
                failPending(failure)
                stop()
                return
            }
        }
    }

    @discardableResult
    private func acceptOperationStatus(_ payload: JSONObject) -> Bool {
        guard let operationId = payload["operationId"] as? String,
              let sequence = payload["sequence"] as? Int, sequence > 0,
              let phase = payload["phase"] as? String,
              let age = payload["lastProgressAgeMs"] as? Double, age >= 0 else { return false }
        let limit: Double
        switch phase {
        case "loading_configuration", "preparing_session": limit = 60_000
        case "waiting_model": limit = 180_000
        case "executing_tool": limit = 600_000
        case "waiting_authorization": limit = 300_000
        default: return false
        }
        let revision = lock.withLock { () -> Int? in
            guard let id = pending.first(where: { $0.value.operationId == operationId })?.key,
                  var entry = pending[id], sequence >= entry.sequence,
                  entry.sessionId == (payload["sessionId"] as? String) else { return nil }
            entry.sequence = sequence
            pending[id] = entry
            operationRevision += 1
            return operationRevision
        }
        guard let revision else { return false }
        var status = payload
        status["revision"] = revision
        status["stalled"] = age >= limit
        notificationHandler?(Self.operationMethod, status)
        return true
    }

    private func reserveId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
            let error = DistillACPError.invalidJSON(String(line.prefix(500)))
            terminationHandler?(.exit, -1, error)
            failPending(error)
            stop()
            return
        }
        if let id = object["id"] as? Int, object["method"] as? String == nil {
            if let error = object["error"] as? JSONObject {
                let parsed = ACPRPCErrorPayload.parse(error, defaultMessage: "Unknown Distill ACP error")
                completePending(id: id, result: .failure(DistillACPError.rpcError(
                    code: parsed.code,
                    message: parsed.message,
                    detail: parsed.detail,
                    httpStatus: parsed.httpStatus
                )))
            } else {
                completePending(id: id, result: .success(object["result"]))
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        if let id = DistillACPRequestID(object["id"]) {
            Task { [weak self] in await self?.handleServerRequest(id: id, method: method, params: object["params"]) }
        } else {
            if method == Self.operationMethod {
                if let payload = object["params"] as? JSONObject { acceptOperationStatus(payload) }
            } else {
                notificationHandler?(method, object["params"])
            }
        }
    }

    private func handleServerRequest(id: DistillACPRequestID, method: String, params: Any?) async {
        do {
            guard let handler = serverRequestHandler else { throw DistillACPError.unsupported("Unhandled Distill ACP request: \(method)") }
            let result = try await handler(id, method, params)
            try write(["jsonrpc": "2.0", "id": id.jsonValue, "result": result ?? NSNull()])
        } catch {
            try? write(["jsonrpc": "2.0", "id": id.jsonValue, "error": ["code": -32603, "message": String(describing: error)]])
        }
    }

    @discardableResult
    private func completePending(id: Int, result: Result<Any?, Error>) -> Bool {
        lock.lock()
        let request = pending.removeValue(forKey: id)
        lock.unlock()
        request?.resume(result)
        return request != nil
    }

    private func failPending(_ error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for request in all.values { request.resume(.failure(error)) }
    }

    @discardableResult
    private func write(
        _ object: JSONObject,
        admittedBy: (@Sendable () -> Bool)? = nil
    ) throws -> Bool {
        // Foundation defaults escape `/` as `\/` (e.g. `session\/prompt`). The harness
        // documents that form as a historical ACP envelope hazard; emit canonical paths.
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        )
        var line = data
        line.append(0x0A)
        let toWrite = line
        return try writeQueue.sync {
            guard !inputClosed else {
                throw DistillACPError.processExited(reason: .exit, status: -1, stderrTail: "")
            }
            guard admittedBy?() ?? true else { return false }
            try GuardedStdinWrite.write(
                toWrite, to: stdinPipe.fileHandleForWriting, process: process,
                notFound: { DistillACPError.processExited(reason: .exit, status: -1, stderrTail: "") }
            )
            return true
        }
    }

    private func stderrTail() -> String {
        parseQueue.sync {
            String(decoding: stderrBuffer.suffix(Self.stderrLimit), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func openResult(_ result: JSONObject, fallbackSessionId: String?) throws -> DistillACPSessionOpenResult {
        guard let sessionId = result["sessionId"] as? String ?? fallbackSessionId, !sessionId.isEmpty else {
            throw DistillACPError.responseTypeMismatch("session open")
        }
        let state = result["models"] as? JSONObject
        let models = modelDescriptors(from: state)
        let modeState = result["modes"] as? JSONObject
        let availableModes = (modeState?["availableModes"] as? [JSONObject] ?? []).compactMap { raw -> DistillACPSessionMode? in
            guard let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return DistillACPSessionMode(id: id, name: name, description: raw["description"] as? String)
        }
        let configOptions = (result["configOptions"] as? [JSONObject]) ?? []
        let currentModelId = state?["currentModelId"] as? String
        return DistillACPSessionOpenResult(
            sessionId: sessionId,
            models: models,
            currentModelId: currentModelId,
            currentReasoningEffortRaw: currentReasoningEffortRaw(
                from: state,
                currentModelId: currentModelId,
                configOptions: configOptions
            ),
            availableModes: availableModes,
            currentModeId: modeState?["currentModeId"] as? String,
            configOptions: configOptions
        )
    }

    static func modelDescriptors(from state: JSONObject?) -> [AgentModelDescriptor] {
        let rawModels = state?["availableModels"] as? [JSONObject] ?? []
        return rawModels.compactMap { raw -> AgentModelDescriptor? in
            guard let rawID = raw["modelId"] as? String else { return nil }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let metadata = raw["_meta"] as? JSONObject ?? [:]
            let effortEntries = (metadata["reasoningEfforts"] as? [JSONObject])
                ?? (metadata["supportedReasoningEfforts"] as? [JSONObject])
                ?? (raw["reasoningEfforts"] as? [JSONObject])
                ?? (raw["supportedReasoningEfforts"] as? [JSONObject])
                ?? []
            let supported: [AgentReasoningEffort]
            if effortEntries.isEmpty {
                supported = reasoningEfforts(
                    from: metadata["reasoningEfforts"]
                        ?? metadata["supportedReasoningEfforts"]
                        ?? raw["reasoningEfforts"]
                        ?? raw["supportedReasoningEfforts"]
                )
            } else {
                supported = parseReasoningEffortCatalog(
                    entries: effortEntries,
                    currentRaw: metadata["reasoningEffort"] as? String
                ).ordered
            }
            let speedTiers = (metadata["additionalSpeedTiers"] as? [String])
                ?? (metadata["additional_speed_tiers"] as? [String])
                ?? (raw["additionalSpeedTiers"] as? [String])
                ?? (raw["additional_speed_tiers"] as? [String])
                ?? []
            let contextWindow = integer(
                metadata["modelContextWindow"]
                    ?? metadata["contextWindowTokens"]
                    ?? metadata["contextWindow"]
                    ?? raw["modelContextWindow"]
                    ?? raw["contextWindowTokens"]
                    ?? raw["contextWindow"]
                    ?? raw["maxTokens"]
            )
            return AgentModelDescriptor(
                id: id,
                label: (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (raw["name"] as? String ?? id)
                    : id,
                provider: .distill,
                supportsReasoning: metadata["supportsReasoningEffort"] as? Bool
                    ?? raw["supportsReasoningEffort"] as? Bool
                    ?? !supported.isEmpty,
                supportedReasoningEfforts: supported,
                supportsServiceTier: metadata["supportsServiceTier"] as? Bool
                    ?? raw["supportsServiceTier"] as? Bool
                    ?? speedTiers.contains("fast"),
                supportsCustomModel: metadata["supportsCustomModel"] as? Bool
                    ?? raw["supportsCustomModel"] as? Bool
                    ?? true,
                contextWindowTokens: contextWindow,
                accountProvider: (metadata["accountProvider"] as? String)
                    .flatMap { DistillAccountProvider(rawValue: $0)?.rawValue }
            )
        }
    }

    /// Stable effort order with preferred default first so `.first` consumers
    /// (schedulers, drafts) match the agent-advertised default rather than
    /// the raw ACP array order (live grok-4.6 lists `xhigh` first).
    static func parseReasoningEffortCatalog(
        entries: [JSONObject],
        currentRaw: String?
    ) -> (ordered: [AgentReasoningEffort], preferred: AgentReasoningEffort?) {
        var seen: [AgentReasoningEffort] = []
        var flaggedDefault: AgentReasoningEffort?
        for entry in entries {
            // Prefer `id` over `value` so glm aliases (id=medium,value=high)
            // keep distinct catalog identities.
            let raw = ((entry["id"] as? String)
                ?? (entry["reasoningEffort"] as? String)
                ?? (entry["value"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let effort = AgentReasoningEffort(rawValue: raw) else { continue }
            if !seen.contains(effort) { seen.append(effort) }
            if flaggedDefault == nil, (entry["default"] as? Bool) == true {
                flaggedDefault = effort
            }
        }
        let current = currentRaw.flatMap { AgentReasoningEffort(rawValue: $0) }
        let preferred = flaggedDefault
            ?? (current.flatMap { seen.contains($0) ? $0 : nil })
            ?? (seen.contains(.high) ? .high : seen.first)
        guard let preferred else { return ([], nil) }
        let rest = seen.filter { $0 != preferred }
        return ([preferred] + rest, preferred)
    }

    /// Live current effort from typed configOptions when it belongs to the
    /// current model's `_meta.reasoningEfforts`; otherwise that model's
    /// `_meta.reasoningEffort`. Session-global `currentValue` can be the
    /// process-default model's token (`max`/`none` on deepseek) while grok-4.6
    /// `_meta` is `high`.
    static func currentReasoningEffortRaw(
        from state: JSONObject?,
        currentModelId: String?,
        configOptions: [JSONObject] = []
    ) -> String? {
        let rawModels = state?["availableModels"] as? [JSONObject] ?? []
        let trimmed = currentModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let match = rawModels.first { ($0["modelId"] as? String) == trimmed } ?? rawModels.first
        let metadata = match?["_meta"] as? JSONObject ?? [:]
        let modelRaw = (metadata["reasoningEffort"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelEffortIds: [String] = {
            let entries = (metadata["reasoningEfforts"] as? [JSONObject])
                ?? (metadata["supportedReasoningEfforts"] as? [JSONObject])
                ?? []
            if !entries.isEmpty {
                return entries.compactMap { entry in
                    let id = (entry["id"] as? String)
                        ?? (entry["value"] as? String)
                        ?? (entry["reasoningEffort"] as? String)
                    let trimmedId = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmedId.isEmpty ? nil : trimmedId
                }
            }
            if let strings = metadata["reasoningEfforts"] as? [String]
                ?? metadata["supportedReasoningEfforts"] as? [String] {
                return strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            return []
        }()
        if let option = configOptions.first(where: {
            (($0["id"] as? String) ?? ($0["configId"] as? String)) == "reasoning_effort"
        }) {
            let current = (option["currentValue"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !current.isEmpty,
               modelEffortIds.isEmpty || modelEffortIds.contains(current) {
                return current
            }
        }
        return modelRaw.isEmpty ? nil : modelRaw
    }

    /// Seed open-state effort from live current when advertised; else preferred default (`.first`).
    static func seededReasoningEffort(
        models: [AgentModelDescriptor],
        currentModelId: String?,
        currentEffortRaw: String? = nil
    ) -> AgentReasoningEffort? {
        let trimmed = currentModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let match = models.first { $0.id == trimmed } ?? models.first
        let supported = match?.supportedReasoningEfforts ?? []
        if let raw = currentEffortRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let current = AgentReasoningEffort(rawValue: raw),
           supported.contains(current) {
            return current
        }
        return supported.first
    }

    private static func reasoningEfforts(from value: Any?) -> [AgentReasoningEffort] {
        if let strings = value as? [String] {
            return strings.compactMap(AgentReasoningEffort.init(rawValue:))
        }
        if let objects = value as? [JSONObject] {
            return objects.compactMap {
                ($0["id"] as? String
                    ?? $0["reasoningEffort"] as? String
                    ?? $0["value"] as? String)
                    .flatMap(AgentReasoningEffort.init(rawValue:))
            }
        }
        return []
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
