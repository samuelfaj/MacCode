import CoreModel
import AppKit
import SwiftUI

/// Plays the pet's idle loop (rest, then blink / tail / ears) for every Titio
/// avatar on screen. One shared player: all avatars show the same frame, the
/// timer runs only while at least one avatar is mounted, and the pet's own
/// animation and reduce-motion settings pause it on the canonical frame.
@MainActor
final class TitioAvatarAnimator: ObservableObject {
    static let shared = TitioAvatarAnimator()

    @Published private(set) var image: NSImage?

    private var controller: PetAnimationController?
    private var didFailToLoad = false
    private var mountedCount = 0
    private var motionAllowed = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var isAnimatingForTests: Bool { controller?.timerIsRunning == true }
    var mountedCountForTests: Int { mountedCount }

    /// Pet settings and the system reduce-motion flag, owned by PetController.
    func setMotionAllowed(_ allowed: Bool) {
        guard allowed != motionAllowed else { return }
        motionAllowed = allowed
        controller?.setAnimationsEnabled(allowed)
    }

    func mount() {
        mountedCount += 1
        guard mountedCount == 1 else { return }
        loadIfNeeded()
        controller?.setVisible(true)
    }

    func unmount() {
        mountedCount = max(0, mountedCount - 1)
        guard mountedCount == 0 else { return }
        controller?.setVisible(false)
    }

    private func loadIfNeeded() {
        guard controller == nil, !didFailToLoad else { return }
        do {
            let controller = try PetAnimationController(atlas: .bundled())
            controller.onFrame = { [weak self] frame in self?.image = frame.appKitImage }
            controller.onError = { [weak self] _ in self?.image = nil }
            controller.setAnimationsEnabled(motionAllowed)
            image = controller.currentFrame?.appKitImage
            self.controller = controller
        } catch {
            // The static avatar below stays honest when the artwork is missing.
            didFailToLoad = true
        }
    }
}

/// Titio's avatar: the pet itself, animated, with no plate behind it.
struct TitioAvatarView: View {
    /// Share of the frame a Bot avatar's figure fills: blobatars draw their
    /// body across 62–76% of their canvas, so Titio uses the same optical size
    /// wherever it sits beside them (roster, headers, composer chips).
    static let botAvatarFill: CGFloat = 0.76

    let size: CGFloat
    /// True when shown as a Bot avatar next to blobatars; false for the
    /// popover and Option+Space, where the pet fills its frame.
    let matchesBotAvatars: Bool
    @ObservedObject private var animator = TitioAvatarAnimator.shared

    init(size: CGFloat, matchesBotAvatars: Bool = false) {
        self.size = size
        self.matchesBotAvatars = matchesBotAvatars
    }

    var body: some View {
        let figure = matchesBotAvatars ? (size * Self.botAvatarFill).rounded() : size
        Group {
            if let image = animator.image ?? TitioBot.avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: figure, height: figure)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .onAppear { animator.mount() }
        .onDisappear { animator.unmount() }
        .accessibilityHidden(true)
    }
}

/// The one "ask Titio" field. Option+Space and the pet popover both mount it,
/// so look, copy, focus and send behave the same in both places.
struct TitioComposerField: View {
    enum Size {
        /// Option+Space: large, Spotlight-like.
        case spotlight
        /// Pet popover.
        case compact
    }

    let size: Size
    let identifier: String
    let onSubmit: (String) -> Void
    var onCancel: (() -> Void)?
    @State private var text = ""
    @FocusState private var focused: Bool

    static let placeholder = L("Ask Titio anything")

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: size == .spotlight ? 10 : 8) {
            TextField(Self.placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: size == .spotlight ? 17 : 14))
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel(Self.placeholder)
                .accessibilityIdentifier(identifier)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: size == .spotlight ? 24 : 20))
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TitioPressableStyle())
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .help(L("Send to Titio (Return)"))
            .accessibilityLabel(L("Send to Titio"))
            .accessibilityIdentifier("\(identifier).send")
        }
        .padding(.leading, size == .spotlight ? 16 : 12)
        .padding(.trailing, size == .spotlight ? 10 : 6)
        .padding(.vertical, size == .spotlight ? 10 : 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(
                focused ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.15),
                lineWidth: 1
            )
        )
        .animation(.easeOut(duration: 0.15), value: focused)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { onCancel?() }
    }

    private func submit() {
        guard canSend else { return }
        onSubmit(text)
        text = ""
    }
}

/// Press feedback for Titio's small controls: a quick dip, never a bounce.
struct TitioPressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
