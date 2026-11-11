import Foundation
import CoreModel
import Persistence

/// The first-run setup steps, in order.
public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case setup, permissions, chrome, accounts, project

    public var title: String {
        switch self {
        case .setup: return L("Setup")
        case .permissions: return L("Permissions")
        case .chrome: return L("Chrome")
        case .accounts: return L("AI accounts")
        case .project: return L("Project")
        }
    }

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public var next: OnboardingStep? { Self.allCases.dropFirst(index + 1).first }
    public var previous: OnboardingStep? { index == 0 ? nil : Self.allCases[index - 1] }
    public var eyebrow: String { "Step \(index + 1) of \(Self.allCases.count)" }

    /// Version 3 steps, folded into the current ones. A current step counts as
    /// done only when every legacy step it replaced was done.
    static let legacyGroups: [(OnboardingStep, [String])] = [
        (.setup, ["distill", "tools"]),
        (.permissions, ["permissions"]),
        (.chrome, ["basics", "chrome"]),
        (.accounts, ["accounts"]),
        (.project, ["workspace", "follow"]),
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let step = Self(rawValue: raw) { self = step; return }
        let legacy: [String: OnboardingStep] = ["distill": .setup, "tools": .setup, "basics": .chrome,
            "account": .accounts, "jev": .accounts, "routing": .accounts, "bots": .project, "workspace": .project, "follow": .project]
        guard let step = legacy[raw] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown step \(raw)"))
        }
        self = step
    }
}

/// Durable setup progress. Holds only non-secret choices and the ids of
/// resources the setup already created, so a resumed setup never creates
/// them twice. Credentials stay in their own stores.
public struct OnboardingState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Shown at launch until finished or explicitly skipped.
        case inProgress
        /// Legacy window-close state; now resumes on launch.
        case dismissed
        case completed
        /// Legacy implicit exemption, now migrated to unfinished setup.
        case existingUser
        /// Explicitly chose Skip setup, rather than closing the window.
        case skipped
    }

    public var version = 4
    public var status: Status = .inProgress
    public var step: OnboardingStep = .setup
    public var completedSteps: Set<OnboardingStep> = []
    public var skippedSteps: Set<OnboardingStep> = []
    public var createDeveloper = true
    public var developerName = OnboardingDeveloperTemplate.defaultName
    public var workspaceID: WorkspaceID?
    public var developerBotID: BotID?
    public var completedAt: Date?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, status, step, completedSteps, skippedSteps, createDeveloper, developerName, workspaceID, developerBotID, completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .inProgress
        step = try c.decodeIfPresent(OnboardingStep.self, forKey: .step) ?? .setup
        createDeveloper = try c.decodeIfPresent(Bool.self, forKey: .createDeveloper) ?? true
        developerName = try c.decodeIfPresent(String.self, forKey: .developerName) ?? OnboardingDeveloperTemplate.defaultName
        workspaceID = try c.decodeIfPresent(WorkspaceID.self, forKey: .workspaceID)
        developerBotID = try c.decodeIfPresent(BotID.self, forKey: .developerBotID)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        let completed = Set(try c.decodeIfPresent([String].self, forKey: .completedSteps) ?? [])
        let skipped = Set(try c.decodeIfPresent([String].self, forKey: .skippedSteps) ?? [])
        for (step, legacy) in OnboardingStep.legacyGroups {
            let names = saved >= 4 ? [step.rawValue] : legacy
            let required = saved >= 4 || step != .chrome ? names : ["chrome"]
            if required.allSatisfy(completed.contains) { completedSteps.insert(step) }
            else if required.contains(where: skipped.contains) { skippedSteps.insert(step) }
        }
        version = 4
    }

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
    /// Only completion or an explicit Skip setup dismisses first-run setup.
    /// Existing projects/accounts do not prove the setup was handled.
    public static func launchDecision(
        saved: OnboardingState?,
        hasWorkspaces: Bool,
        hasAccountSession: Bool
    ) -> (present: Bool, stateToSave: OnboardingState?) {
        if var saved {
            if saved.status == .completed || saved.status == .skipped { return (false, nil) }
            if saved.status != .inProgress {
                saved.status = .inProgress
                return (true, saved)
            }
            return (true, nil)
        }
        return (true, OnboardingState())
    }

    /// Where the sidebar "Sign in" button leads. Signed-out users who never
    /// finished setup get its Account step; everyone else gets the account sheet.
    public static func signInOpensSetup(saved: OnboardingState?, signedIn: Bool) -> Bool {
        guard !signedIn else { return false }
        return saved?.status != .completed
    }
}

/// The example Bot offered by setup.
public enum OnboardingDeveloperTemplate {
    public static let defaultName = L("Developer")
    public static let title = L("Software engineer")
    public static let description = L("Understands the project, plans changes and reviews code.")
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
