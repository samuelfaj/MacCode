import CoreModel
import DesignSystemKit
import SwiftUI
import Combine

public struct AgentNowStripItem: Equatable, Identifiable, Sendable {
  public enum State: Sendable { case running, needsYou }

  public let id: String
  public let state: State
  public let title: String
  /// workspace · bot
  public let subtitle: String?
  public let startedAt: Date?
  /// Routing fields the host opens with (bot, conversation, thread, surface, workspace).
  public let route: AgentNowStripRoute?

  public init(id: String, state: State, title: String, subtitle: String?, startedAt: Date?,
              route: AgentNowStripRoute? = nil) {
    self.id = id
    self.state = state
    self.title = title
    self.subtitle = subtitle
    self.startedAt = startedAt
    self.route = route
  }
}

/// `items` lists needs-you first, then running, max 5.
/// Where a Now row opens. Plain strings and UUIDs so the strip stays free of host types.
public struct AgentNowStripRoute: Equatable, Sendable {
  public let botID: UUID?
  public let conversationID: UUID?
  public let threadID: UUID?
  public let workspaceID: UUID?
  public let surfaceID: UUID?

  public init(botID: UUID? = nil, conversationID: UUID? = nil, threadID: UUID? = nil,
              workspaceID: UUID? = nil, surfaceID: UUID? = nil) {
    self.botID = botID
    self.conversationID = conversationID
    self.threadID = threadID
    self.workspaceID = workspaceID
    self.surfaceID = surfaceID
  }
}

public struct AgentNowStripSnapshot: Equatable, Sendable {
  public let running: Int
  public let needsYou: Int
  public let items: [AgentNowStripItem]

  public init(running: Int, needsYou: Int, items: [AgentNowStripItem]) {
    self.running = running
    self.needsYou = needsYou
    self.items = items
  }
}

public struct AgentNowStripSource {
  public let load: @Sendable () async throws -> AgentNowStripSnapshot
  public let changes: AnyPublisher<Void, Never>
  public let open: @MainActor (AgentNowStripItem) -> Void
  /// Runs only for the accepted (latest, uncancelled) load, after it becomes
  /// the model's snapshot. Owners commit caches here, never inside `load`.
  public let onAccept: (@MainActor (AgentNowStripSnapshot) -> Void)?

  public init(
    load: @escaping @Sendable () async throws -> AgentNowStripSnapshot,
    changes: AnyPublisher<Void, Never>,
    open: @escaping @MainActor (AgentNowStripItem) -> Void,
    onAccept: (@MainActor (AgentNowStripSnapshot) -> Void)? = nil
  ) {
    self.load = load
    self.changes = changes
    self.open = open
    self.onAccept = onAccept
  }
}

@MainActor
public final class AgentNowStripModel: ObservableObject {
  /// nil until first successful load; cached value kept across refreshes.
  @Published public private(set) var snapshot: AgentNowStripSnapshot?
  @Published public private(set) var lastError: String?

  private let source: AgentNowStripSource
  private var generation = 0
  private var task: Task<Void, Never>?
  private var changeSink: AnyCancellable?

  public init(source: AgentNowStripSource, cached: AgentNowStripSnapshot? = nil) {
    self.source = source
    self.snapshot = cached
  }

  public func start() {
    changeSink = source.changes
      .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
      .sink { [weak self] in self?.refresh() }
    refresh()
  }

  /// Latest call wins: an older in-flight load is cancelled and its result ignored.
  public func refresh() {
    task?.cancel()
    generation += 1
    let current = generation
    let load = source.load
    task = Task { [weak self] in
      do {
        let next = try await load()
        guard let self, current == self.generation, !Task.isCancelled else { return }
        self.snapshot = next
        self.lastError = nil
        source.onAccept?(next)
      } catch {
        guard let self, current == self.generation, !Task.isCancelled else { return }
        self.lastError = error.localizedDescription
      }
    }
  }

  public func open(_ item: AgentNowStripItem) {
    source.open(item)
  }

  public func stop() {
    changeSink = nil
    generation += 1
    task?.cancel()
    task = nil
  }
}

public struct AgentNowStrip: View {
  @ObservedObject var model: AgentNowStripModel
  @AppStorage("titio.now_strip.expanded") private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(model: AgentNowStripModel) {
    self.model = model
  }

  public var body: some View {
    if let snapshot = model.snapshot, snapshot.running + snapshot.needsYou > 0 {
      VStack(spacing: 0) {
        Button {
          withAnimation(reduceMotion ? nil : DS.Motion.micro) { expanded.toggle() }
        } label: {
          HStack(spacing: DS.Space.sm) {
            Circle()
              .fill(snapshot.needsYou > 0 ? DS.Palette.warning : DS.Palette.accent)
              .frame(width: 7, height: 7)
            Text(Self.summary(snapshot))
              .font(DS.Font.bodyDense)
              .foregroundStyle(DS.Palette.text)
            Spacer(minLength: 0)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
              .font(DS.Font.caption)
              .foregroundStyle(DS.Palette.textSecondary)
          }
          .frame(minHeight: 32)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsHoverFill()
        .accessibilityIdentifier("agent.nowStrip.toggle")

        if expanded {
          ForEach(snapshot.items.prefix(5)) { item in
            row(item)
          }
        }
      }
      .padding(DS.Space.md)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
          .fill(DS.Palette.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
          .stroke(DS.Palette.line, lineWidth: 1)
      )
      .accessibilityIdentifier("agent.nowStrip")
    } else {
      EmptyView()
    }
  }

  private func row(_ item: AgentNowStripItem) -> some View {
    Button {
      model.open(item)
    } label: {
      HStack(spacing: DS.Space.md) {
        leading(item.state)
        VStack(alignment: .leading, spacing: 0) {
          Text(item.title)
            .font(DS.Font.bodyDense)
            .foregroundStyle(DS.Palette.text)
            .lineLimit(1)
          if let subtitle = item.subtitle {
            Text(subtitle)
              .font(DS.Font.caption)
              .foregroundStyle(DS.Palette.textSecondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: DS.Space.sm)
        trailing(item)
      }
      .frame(minHeight: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .dsHoverFill()
    .accessibilityIdentifier("agent.nowStrip.row.\(item.id)")
  }

  @ViewBuilder
  private func leading(_ state: AgentNowStripItem.State) -> some View {
    switch state {
    case .running:
      ProgressView()
        .controlSize(.small)
        .frame(width: 16, height: 16)
    case .needsYou:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(DS.Palette.warning)
        .frame(width: 16, height: 16)
    }
  }

  @ViewBuilder
  private func trailing(_ item: AgentNowStripItem) -> some View {
    switch item.state {
    case .running:
      if let started = item.startedAt {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(Self.elapsedLabel(from: started, now: context.date))
            .font(DS.Font.caption)
            .monospacedDigit()
            .foregroundStyle(DS.Palette.textSecondary)
        }
      }
    case .needsYou:
      Text(L("Review"))
        .font(DS.Font.captionStrong)
        .foregroundStyle(DS.Palette.warning)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xxs)
        .background(Capsule().fill(DS.Palette.warning.opacity(0.16)))
    }
  }

  public static func elapsedLabel(from: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(from)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h"
  }

  public static func summary(_ s: AgentNowStripSnapshot) -> String {
    var parts: [String] = []
    if s.running > 0 { parts.append(L("%1$@ running", s.running)) }
    if s.needsYou > 0 { parts.append(s.needsYou == 1 ? L("1 needs you") : L("%1$@ need you", s.needsYou)) }
    return parts.joined(separator: " · ")
  }
}
