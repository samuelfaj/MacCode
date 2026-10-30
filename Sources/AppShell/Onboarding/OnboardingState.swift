import Foundation
import CoreModel
import Persistence

/// The first-run setup steps, in order.
public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case account, jev, accounts, routing, bots, workspace, follow

    public var title: String {
        switch self {
        case .account: return "Account"
        case .jev: return "Jev"
        case .accounts: return "AI accounts"
        case .routing: return "Auto"
        case .bots: return "Bots"
        case .workspace: return "Project"
        case .follow: return "Follow"
        }
    }

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public var next: OnboardingStep? { Self.allCases.dropFirst(index + 1).first }
    public var previous: OnboardingStep? { index == 0 ? nil : Self.allCases[index - 1] }
}

/// Durable setup progress. Holds only non-secret choices and the ids of
/// resources the setup already created, so a resumed setup never creates
/// them twice. Credentials stay in their own stores.
public struct OnboardingState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Shown at launch until finished or closed.
        case inProgress
        /// Closed before finishing; reopened only from the app menu.
        case dismissed
        case completed
        /// An install that already had projects or an account when this
        /// setup shipped. It never sees the first-run window.
        case existingUser
    }

    public var version = 1
    public var status: Status = .inProgress
    public var step: OnboardingStep = .account
    public var completedSteps: Set<OnboardingStep> = []
    public var skippedSteps: Set<OnboardingStep> = []
    public var createDeveloper = true
    public var developerName = OnboardingDeveloperTemplate.defaultName
    public var workspaceID: WorkspaceID?
    public var developerBotID: BotID?
    public var completedAt: Date?

    public init() {}

    public mutating func complete(_ step: OnboardingStep) {
        completedSteps.insert(step)
        skippedSteps.remove(step)
    }

    /// Deferring records the step as skipped, never as succeeded.
    public mutating func skip(_ step: OnboardingStep) {
        guard !completedSteps.contains(step) else { return }
        skippedSteps.insert(step)
    }
}

public final class OnboardingStateStore {
    public static let settingsKey = "onboarding.v1"
    private let repo: SettingsRepository

    public init(repo: SettingsRepository) { self.repo = repo }

    public func load() -> OnboardingState? {
        guard let raw = (try? repo.get(Self.settingsKey)) ?? nil,
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OnboardingState.self, from: data)
    }

    /// Returns false when the write failed, so callers keep the step open.
    @discardableResult
    public func save(_ state: OnboardingState) -> Bool {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return false }
        do {
            try repo.set(Self.settingsKey, json)
            return true
        } catch {
            return false
        }
    }
}

public enum OnboardingGate {
    /// Whether launch shows the setup window. With no saved state, only an
    /// install without projects or an account counts as new; everyone else
    /// is recorded as an existing user so the window never appears for them.
    public static func launchDecision(
        saved: OnboardingState?,
        hasWorkspaces: Bool,
        hasAccountSession: Bool
    ) -> (present: Bool, stateToSave: OnboardingState?) {
        if let saved { return (saved.status == .inProgress, nil) }
        if hasWorkspaces || hasAccountSession {
            var existing = OnboardingState()
            existing.status = .existingUser
            return (false, existing)
        }
        return (true, OnboardingState())
    }

    /// Where the sidebar "Sign in" button leads. Signed-out users who never
    /// finished setup get it from step 1; everyone else gets the account sheet.
    public static func signInOpensSetup(saved: OnboardingState?, signedIn: Bool) -> Bool {
        guard !signedIn else { return false }
        return saved?.status != .completed
    }
}

/// The example Bot offered by setup.
public enum OnboardingDeveloperTemplate {
    public static let defaultName = "Developer"
    public static let title = "Software engineer"
    public static let description = "Understands the project, plans changes and reviews code."
    public static let firstPrompt = "Analyze this project's structure and propose next steps. Do not change files or run commands yet."

    public static func soul(name: String) -> String {
        """
        You are \(name), a careful software engineer working in this workspace's project.

        - Read the code before proposing changes; cite the files you rely on.
        - Prefer the smallest change that solves the problem and matches the project's conventions.
        - Explain trade-offs briefly, then act. Ask before destructive or irreversible operations.
        - When you finish, say what changed, how you verified it, and what is still unverified.
        """
    }
}

/// The maker's X profile, offered on the last step.
public enum OnboardingFollow {
    public static let handle = "@samfajreldines"
    public static let url = URL(string: "https://x.com/samfajreldines")!
}
