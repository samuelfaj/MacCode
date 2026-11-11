import AppKit
import Persistence
import SwiftUI
import CoreModel

/// The sprite frame lives apart from PetViewModel so a 2-7 fps animation tick redraws
/// only the image, not the attention dot, accessibility value or popover that observe the model.
@MainActor
final class PetFrameModel: ObservableObject {
    @Published fileprivate(set) var image: NSImage?
}

@MainActor
public final class PetViewModel: ObservableObject {
    @Published public private(set) var animationState: PetAnimationState = .idle
    @Published public private(set) var items: [PetAttentionItem] = []
    @Published public private(set) var count = 0
    @Published public private(set) var activeThreads: [PetActiveThreadItem] = []
    @Published public private(set) var activeThreadCount = 0
    @Published private(set) var activityCounts = PetActivityCounts.zero
    @Published public private(set) var settings: AppSettings
    @Published public var routeError: String?
    /// What Titio is saying from the pet right now (hub spec §9), or nil.
    @Published public private(set) var speech: PetSpeech?

    private(set) var currentFrame: PetAtlasFrame?
    let frameModel = PetFrameModel()
    public var currentImage: NSImage? { frameModel.image }

    public init(settings: AppSettings) {
        self.settings = settings
    }

    /// Single external indicator, gated by the existing ready-counter preference.
    public var badgeText: String? {
        guard activityCounts.isAvailable else { return nil }
        return PetAttentionCountFormatter.badgeText(
            count: activityCounts.badgeTotal,
            isEnabled: settings.petReadyCounterEnabled
        )
    }

    /// Blue dot: agent threads running now (the popover's active list). Not
    /// gated by the ready-counter setting.
    public var activeBadgeText: String? {
        PetActiveThreadCountFormatter.badgeText(count: activeThreadCount)
    }

    public var accessibilityValue: String {
        guard activityCounts.isAvailable else { return L("Activity status unavailable") }
        let running = activityCounts.running == 1 ? L("1 running") : L("%1$@ running", activityCounts.running)
        let needsYou = PetAttentionCountFormatter.accessibilityValue(count: activityCounts.needsYou)
        return L("Activity: %1$@, %2$@", running, needsYou)
    }

    public var isPopoverEmpty: Bool {
        items.isEmpty && activeThreads.isEmpty
    }

    public func setAnimationState(_ state: PetAnimationState) {
        animationState = state
    }

    func setFrame(_ frame: PetAtlasFrame) {
        currentFrame = frame
        frameModel.image = frame.appKitImage
    }

    public func apply(snapshot: PetAttentionSnapshot) {
        items = snapshot.items
        count = snapshot.count
    }

    public func apply(activeThreads: [PetActiveThreadItem]) {
        guard activeThreads != self.activeThreads else { return }
        self.activeThreads = activeThreads
        activeThreadCount = activeThreads.count
    }

    func apply(activityCounts: PetActivityCounts) {
        guard activityCounts != self.activityCounts else { return }
        self.activityCounts = activityCounts
    }

    public func apply(settings: AppSettings) {
        self.settings = settings
    }

    func setSpeech(_ speech: PetSpeech?) {
        guard speech != self.speech else { return }
        self.speech = speech
    }
}
