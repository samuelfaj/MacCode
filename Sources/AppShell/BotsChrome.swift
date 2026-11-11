import SwiftUI
import CoreModel
import DesignSystemKit

/// Visible Bots chrome and Bots-only visual tokens.
/// Bots surfaces speak the global DS language (accent, surfaces, radii);
/// only per-bot avatar identity colors are local to Bots.
public enum BotsChrome {
    public enum Label {
        public static let agentic = L("Workspaces")
        public static let bots = L("Bots")
        public static let newBot = L("New Bot")
        public static let activeBots = L("Active Bots")
        public static let scheduleTasks = L("Schedule Tasks")
        public static let myBots = L("My Bots")
        public static let botRoster = L("BOT ROSTER")
        public static let search = L("Search bots...")
        public static let openChat = L("Open Chat")
        public static let saveBot = L("Save Bot")
        public static let unsavedNewBotConfirmTitle = L("Don't save this Bot?")
        public static let unsavedNewBotConfirmMessage = L("This teammate has not been saved.")
        public static let unsavedNewBotDontSave = L("Don't Save")
        public static let currentGoal = L("Current Goal")
        public static let todaysActivity = L("Today's Activity")
        public static let nextRoutine = L("Next Routine")
        public static let files = L("Files")
        public static let routines = L("Schedule Tasks")
        public static let approvals = L("Approvals")
        public static let roleAndIdentity = L("Role & Identity")
        public static let description = L("Description")
        public static let descriptionCaption =
            L("Who this teammate is. A short about line. Empty stays out of the prompt.")
        public static let instructions = L("Instructions")
        public static let instructionsCaption =
            L("How this teammate should work. Always sent. Empty uses the built-in teammate default. Write your own to replace it.")
        public static let security = L("Security")
        public static let notifications = L("Notifications")
        public static let desktop = L("Desktop")
        public static let brain = L("Brain")
        public static let source = L("Source")
        public static let effective = L("Effective")
        public static let brainPreviewHonesty = L("Local compile. This is not a model call.")
        public static let brainReceiptHonesty = L("Receipt from the last compiled send.")
        public static let honesty = BotDesktopKind.logicalExecutionSpaceHonestyLabel
    }

    public static let hitTarget: CGFloat = 44
    /// Roster conversation-list avatar. Workspace folder icons stay 20pt;
    /// blobatar faces (eyes / glance) only paint at ≥40pt.
    public static let rosterAvatarSize: CGFloat = 48
    public static let rosterWidth: CGFloat = 272
    public static let threadRailWidth: CGFloat = 320
    public static let threadRailMinWidth: CGFloat = 320
    public static let threadRailMaxWidth: CGFloat = 360
    public static let desktopPaneWidth: CGFloat = 340
    public static let desktopPaneMinWidth: CGFloat = 240
    public static let desktopPaneMaxWidth: CGFloat = 560

    /// Leftover SF chips. Studio Avatar is the blobatar composer.
    public static let avatarSymbols: [String] = BotAvatar.advertisedSymbols

    public static func avatarSymbolName(_ symbol: String) -> String {
        BotAvatar.advertisedName(for: symbol)
    }

    public static let allVisibleLabels: [String] = [
        Label.agentic,
        Label.bots,
        Label.newBot,
        Label.activeBots,
        Label.scheduleTasks,
        Label.myBots,
        Label.botRoster,
        Label.openChat,
        Label.saveBot,
        Label.unsavedNewBotConfirmTitle,
        Label.unsavedNewBotConfirmMessage,
        Label.unsavedNewBotDontSave,
        Label.currentGoal,
        Label.todaysActivity,
        Label.nextRoutine,
        Label.files,
        Label.routines,
        Label.approvals,
        Label.roleAndIdentity,
        Label.description,
        Label.descriptionCaption,
        Label.instructions,
        Label.instructionsCaption,
        Label.security,
        Label.notifications,
        Label.desktop,
        Label.brain,
        Label.brainPreviewHonesty,
        Label.brainReceiptHonesty,
        Label.honesty,
    ]

    public static func avatarHex(for handle: String) -> UInt32 {
        BotAvatar.fallbackHex(for: handle)
    }

    public static func avatarColor(for handle: String) -> Color {
        Color(hex: avatarHex(for: handle))
    }

    /// Painted avatar ink. Blobatar uses the figure head; leftover SF chips
    /// keep the handle swatch so roster highlight matches the glyph.
    /// The roster calls this per visible row on every BotsViewModel publish
    /// (30 Hz while a desk streams); the ink is a pure function of its inputs,
    /// so a full figure is built once per (name, handle, symbol).
    public static func identityHex(name: String, handle: String, symbol: String) -> UInt32 {
        let key = IdentityKey(name: name, handle: handle, symbol: symbol)
        if let cached = identityHexCache.value(for: key) { return cached }
        identityHexComputeCountForTesting += 1
        let hex: UInt32
        if let spec = BotBlobatarSpec.parse(symbol) {
            hex = BotBlobatar.figure(
                name: name.isEmpty ? handle : name,
                spec: spec,
                handle: handle
            ).palette.head
        } else {
            hex = avatarHex(for: handle)
        }
        identityHexCache.store(hex, for: key)
        return hex
    }

    nonisolated(unsafe) static var identityHexComputeCountForTesting = 0

    private struct IdentityKey: Hashable {
        let name: String
        let handle: String
        let symbol: String
    }

    private final class IdentityHexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [IdentityKey: UInt32] = [:]

        func value(for key: IdentityKey) -> UInt32? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: UInt32, for key: IdentityKey) {
            lock.lock(); defer { lock.unlock() }
            // Renames/re-skins add keys; a small roster never reaches this.
            if values.count >= 512 { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }

    private static let identityHexCache = IdentityHexCache()

    public static func identityColor(name: String, handle: String, symbol: String) -> Color {
        Color(hex: identityHex(name: name, handle: handle, symbol: symbol))
    }

    public static func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        if letters.isEmpty { return "B" }
        return letters.joined().uppercased()
    }

    public static func statusTitle(for state: BotAttentionState) -> String {
        switch state {
        case .working: return "Working"
        case .needsAttention: return L("Needs you")
        case .unreadActivity: return L("Unread")
        case .none: return L("Online")
        }
    }

    public static func rosterShowsBusySpinner(for state: BotAttentionState) -> Bool {
        state == .working
    }

    public static func clampedThreadRailWidth(_ width: CGFloat) -> CGFloat {
        min(threadRailMaxWidth, max(threadRailMinWidth, width))
    }
}

/// DS primary button at the Bots 44pt hit target (DSPrimaryButtonStyle is shorter).
public struct BotsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.body.weight(.semibold))
            .foregroundColor(DS.Palette.onAccent)
            .frame(minHeight: BotsChrome.hitTarget)
            .padding(.horizontal, DS.Space.xl)
            .background(DS.Palette.accent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .opacity(DSButtonOpacity.effectiveOpacity(isEnabled: isEnabled, isHovering: hovering))
            .onHover { hovering = $0 }
    }
}

public struct BotActivityRow: Identifiable, Equatable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}
