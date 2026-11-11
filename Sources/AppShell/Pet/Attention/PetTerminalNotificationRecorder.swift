import Foundation
import CoreModel
import Persistence
import SocketServer

public struct PetTerminalNotificationRecorder {
    private let repository: NotificationRepository

    // PERF: record/classify run on every pet-bound EventBus event and recovery
    // replay. Array-literal membership reallocated per call; share Sets.
    private static let fileEditResolvedKinds: Set<String> = [
        "files.edit.saved", "files.edit.discarded", "files.edit.closed",
    ]
    private static let sshUnexpectedDisconnectReasons: Set<String> = [
        "unexpected_child_exit", "connection_failed",
    ]

    public init(repository: NotificationRepository) {
        self.repository = repository
    }

    @discardableResult
    public func record(
        eventSequence: Int64,
        kind: PetTerminalNotificationKind,
        workspaceID: WorkspaceID?,
        surfaceID: SurfaceID?,
        createdAt: Date,
        replaying: Bool = false,
        activitySummary: String? = nil
    ) throws -> AppNotification {
        let category = Self.category(for: kind)
        let presentation = category.presentation
        let statefulSSHSurfaceID = kind == .sshUnexpectedDisconnect ? surfaceID : nil
        let summary = activitySummary ?? Self.activitySummary(for: kind)
        let body = try summary.map { try JSONEncoder().encode(["activity_summary": $0]) }.map { String(decoding: $0, as: UTF8.self) }
        let notification = AppNotification(
            id: statefulSSHSurfaceID.map { Self.sshDisconnectID($0) } ?? "pet.event.\(eventSequence)",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            title: presentation.title,
            body: body,
            category: category.rawValue,
            createdAt: createdAt
        )
        if statefulSSHSurfaceID != nil, !replaying {
            try repository.resurface(notification)
        } else {
            try repository.insertIfAbsent(notification)
        }
        return notification
    }

    @discardableResult
    public func record(event: EventBus.Event, replaying: Bool = false) throws -> AppNotification? {
        if event.kind == "ssh.session.updated",
           case .object(let payload) = event.payload,
           (payload["status"]?.stringValue == "connected"
                || payload["reason"]?.stringValue == "user_requested"),
           let surfaceID = Self.identifier(payload["surface_id"], SurfaceID.init) {
            try repository.markRead(id: Self.sshDisconnectID(surfaceID))
            return nil
        }
        if Self.fileEditResolvedKinds.contains(event.kind),
           case .object(let payload) = event.payload,
           let sessionID = payload["session_id"]?.stringValue,
           !sessionID.isEmpty {
            try repository.markRead(id: "pet.file-conflict.\(sessionID)")
            return nil
        }
        guard let terminal = Self.classify(event) else { return nil }
        if terminal.kind == .fileConflict,
           case .object(let payload) = event.payload,
           let sessionID = payload["session_id"]?.stringValue,
           !sessionID.isEmpty {
            let category = PetNotificationCategory.fileConflict
            let notification = AppNotification(
                id: "pet.file-conflict.\(sessionID)",
                workspaceId: terminal.workspaceID,
                surfaceId: terminal.surfaceID,
                title: category.presentation.title,
                body: nil,
                category: category.rawValue,
                createdAt: terminal.createdAt
            )
            if replaying {
                try repository.insertIfAbsent(notification)
            } else {
                try repository.resurface(notification)
            }
            return notification
        }
        return try record(
            eventSequence: terminal.sequence,
            kind: terminal.kind,
            workspaceID: terminal.workspaceID,
            surfaceID: terminal.surfaceID,
            createdAt: terminal.createdAt,
            replaying: replaying,
            activitySummary: Self.eventActivitySummary(event, kind: terminal.kind)
        )
    }

    public static func classify(_ event: EventBus.Event) -> PetTerminalEvent? {
        guard event.ts.isFinite,
              case .object(let payload) = event.payload else { return nil }
        let workspaceID = identifier(payload["workspace_id"], WorkspaceID.init)
        let surfaceID = identifier(payload["surface_id"], SurfaceID.init)
        let kind: PetTerminalNotificationKind

        switch event.kind {
        case "git.push", "git.deliver":
            guard workspaceID != nil,
                  let succeeded = payload["ok"]?.boolValue else { return nil }
            kind = .gitDelivery(succeeded ? .succeeded : .failed)
        case "project.script.finished":
            guard workspaceID != nil, surfaceID != nil else { return nil }
            switch payload["result"]?.stringValue {
            case "success": kind = .projectScript(.succeeded)
            case "failure": kind = .projectScript(.failed)
            default: return nil
            }
        case "ssh.transfer.completed":
            guard surfaceID != nil else { return nil }
            kind = .sshTransfer(.succeeded)
        case "ssh.transfer.failed":
            guard surfaceID != nil else { return nil }
            kind = .sshTransfer(.failed)
        case "ssh.session.updated":
            guard surfaceID != nil,
                  payload["status"]?.stringValue == "disconnected",
                  Self.sshUnexpectedDisconnectReasons.contains(
                    payload["reason"]?.stringValue ?? ""
                  ) else { return nil }
            kind = .sshUnexpectedDisconnect
        case "agent.provider.updated":
            guard payload["ok"]?.boolValue == false else { return nil }
            kind = .providerUpdateFailed
        case "files.edit.conflict":
            guard workspaceID != nil,
                  surfaceID != nil,
                  payload["session_id"]?.stringValue?.isEmpty == false else { return nil }
            kind = .fileConflict
        default:
            return nil
        }

        return PetTerminalEvent(
            sequence: event.seq,
            kind: kind,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            createdAt: Date(timeIntervalSince1970: event.ts)
        )
    }

    private static func eventActivitySummary(_ event: EventBus.Event, kind: PetTerminalNotificationKind) -> String? {
        guard event.kind == "project.script.finished",
              case .object(let payload) = event.payload,
              let summary = activitySummary(for: kind) else { return nil }
        guard let exitCode = payload["exit_code"]?.intValue else { return summary }
        return L("%1$@ (exit code %2$@)", summary, exitCode)
    }

    private static func activitySummary(for kind: PetTerminalNotificationKind) -> String? {
        switch kind {
        case .gitDelivery(.succeeded): return L("Git delivery succeeded")
        case .gitDelivery(.failed): return L("Git delivery failed")
        case .projectScript(.succeeded): return L("Project script succeeded")
        case .projectScript(.failed): return L("Project script failed")
        case .sshTransfer(.succeeded): return L("SSH transfer completed")
        case .sshTransfer(.failed): return L("SSH transfer failed")
        default: return nil
        }
    }

    private static func category(for kind: PetTerminalNotificationKind) -> PetNotificationCategory {
        switch kind {
        case .gitDelivery(.succeeded): return .gitCompleted
        case .gitDelivery(.failed): return .gitFailed
        case .projectScript(.succeeded): return .projectScriptCompleted
        case .projectScript(.failed): return .projectScriptFailed
        case .sshTransfer(.succeeded): return .sshTransferCompleted
        case .sshTransfer(.failed): return .sshTransferFailed
        case .sshUnexpectedDisconnect: return .sshUnexpectedDisconnect
        case .providerUpdateFailed: return .providerUpdateFailed
        case .fileConflict: return .fileConflict
        }
    }

    private static func identifier<ID>(
        _ value: JSONValue?,
        _ make: (UUID) -> ID
    ) -> ID? {
        value?.stringValue.flatMap(UUID.init(uuidString:)).map(make)
    }

    private static func sshDisconnectID(_ surfaceID: SurfaceID) -> String {
        "pet.ssh-disconnect.\(surfaceID.value.uuidString)"
    }
}
