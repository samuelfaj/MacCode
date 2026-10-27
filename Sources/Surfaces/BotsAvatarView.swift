import SwiftUI
import CoreModel
import DesignSystemKit

/// Shared teammate avatar. Desk roster and both composers mount this view.
public struct BotsAvatarView: View {
    /// View that replaces the generated avatar for a handle, drawn at `size`
    /// with no plate behind it (Titio is the animated pet).
    @MainActor public static var viewOverride: (_ handle: String, _ size: CGFloat) -> AnyView? = { _, _ in nil }

    public let name: String
    public let handle: String
    public var symbol: String?
    public var size: CGFloat = 36
    public var attention: BotAttentionState = .none
    public var tintHex: UInt32? = nil

    public init(
        name: String,
        handle: String,
        symbol: String? = nil,
        size: CGFloat = 36,
        attention: BotAttentionState = .none,
        tintHex: UInt32? = nil
    ) {
        self.name = name
        self.handle = handle
        self.symbol = symbol
        self.size = size
        self.attention = attention
        self.tintHex = tintHex
    }

    /// A working Bot hops; any other Bot breathes only while hovered.
    public static func motionMode(for attention: BotAttentionState) -> BotBlobatarMotionMode {
        attention == .working ? .working : .hover
    }

    public var body: some View {
        Group {
            if let custom = Self.viewOverride(handle, size) {
                custom.frame(width: size, height: size)
            } else if let spec = blobatarSpec {
                BotBlobatarView(
                    name: name.isEmpty ? handle : name,
                    spec: spec.liveFaced(attention: attention, name: name, handle: handle),
                    size: size,
                    motion: Self.motionMode(for: attention),
                    handle: handle,
                    tintHex: tintHex
                )
            } else {
                symbolFallback
            }
        }
        .accessibilityHidden(true)
    }

    /// Legacy default symbol means the auto blobatar, so older bots render like new ones.
    private var blobatarSpec: BotBlobatarSpec? {
        if symbol == "person.crop.circle" { return .default }
        guard let symbol else { return nil }
        return BotBlobatarSpec.parse(symbol)
    }

    @ViewBuilder
    private var symbolFallback: some View {
        let ink = Color(hex: tintHex ?? BotAvatar.fallbackHex(for: handle))
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(ink)
            if let symbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: max(11, size * 0.42), weight: .semibold))
                    .foregroundColor(.white)
            } else {
                Text(initials(for: name))
                    .font(.system(size: max(11, size * 0.36), weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        if letters.isEmpty { return "B" }
        return letters.joined().uppercased()
    }
}
