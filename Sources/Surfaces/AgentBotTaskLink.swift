import CoreModel
import DesignSystemKit
import SwiftUI

public struct AgentBotTaskLink: View {
    public let task: BotParallelTask
    public let loadStatus: (BotParallelTask) async throws -> AgentRunStatus?
    public let open: (BotParallelTask) -> Void
    @State private var status: AgentRunStatus?
    @State private var unavailable = false

    public init(task: BotParallelTask,
                loadStatus: @escaping (BotParallelTask) async throws -> AgentRunStatus?,
                open: @escaping (BotParallelTask) -> Void) {
        self.task = task
        self.loadStatus = loadStatus
        self.open = open
    }

    public var body: some View {
        Button { open(task) } label: {
            HStack(spacing: DS.Space.sm) {
                if status == .running || status == .pending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(unavailable ? DS.Palette.warning : DS.Palette.textSecondary)
                }
                Text(task.title)
                    .font(DS.Font.caption.weight(.medium))
                    .lineLimit(1)
                Circle()
                    .fill(status == .completed ? DS.Palette.accent : DS.Palette.textTertiary)
                    .frame(width: DS.Space.xs, height: DS.Space.xs)
                    .accessibilityHidden(true)
                Image(systemName: "chevron.right")
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(DS.Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        }
        .buttonStyle(.plain)
        .help("\(statusLabel). Open conversation alongside this chat.")
        .accessibilityLabel("\(task.title). \(statusLabel). Open parallel conversation")
        .accessibilityIdentifier("agent.botTask.\(task.runID.value.uuidString.lowercased())")
        .task(id: task.runID) {
            while !Task.isCancelled {
                do {
                    let loaded = try await loadStatus(task)
                    guard !Task.isCancelled else { return }
                    status = loaded
                    unavailable = loaded == nil
                } catch {
                    guard !Task.isCancelled else { return }
                    unavailable = true
                }
                if let status, status != .running && status != .pending { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
    }

    private var symbol: String {
        if unavailable { return "exclamationmark.circle" }
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .failed, .cancelled, .interrupted: return "exclamationmark.circle"
        default: return "circle.dotted"
        }
    }

    private var statusLabel: String {
        if unavailable { return "Status unavailable" }
        switch status {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        case .running: return "Running"
        case .pending: return "Queued"
        case nil: return "Checking status"
        }
    }
}
