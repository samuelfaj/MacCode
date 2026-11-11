import Foundation
import AppKit
import SwiftUI
import DesignSystemKit
import CoreModel

/// Presentation only: the receipt keeps its execution identity and original name.
/// A stable seed keeps each cat unchanged across polling, completion and relaunch.
struct SubagentCatIdentity: Equatable, Sendable {
    let name: String
    let breed: String
    let assetName: String
    let shortID: String

    init(id: UUID) {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var seed: UInt64 = 0
        for byte in bytes { seed = (seed &* 1099511628211) ^ UInt64(byte) }
        let family = Self.families[Int(seed % UInt64(Self.families.count))]
        name = family.names[Int((seed / UInt64(Self.families.count)) % UInt64(family.names.count))]
        breed = family.breed
        assetName = family.asset
        shortID = String(id.uuidString.prefix(4)).lowercased()
    }

    private static let families: [(asset: String, breed: String, names: [String])] = [
        ("cat-tuxedo", L("Tuxedo"), ["Frajola", "Felix", "Oreo", "Silvestre", "Tom", "Bigode"]),
        ("cat-siamese", L("Siamese"), ["Mimi", "Bento", "Suki", "Nala", "Kiko", "Milo"]),
        ("cat-ginger", L("Ginger tabby"), ["Paçoca", "Chico", "Pudim", "Simba", "Garfield", "Caramelo"]),
        ("cat-calico", L("Calico"), ["Amora", "Pipoca", "Lola", "Cacau", "Jujuba", "Mel"]),
        ("cat-silver", L("Silver tabby"), ["Nino", "Luna", "Nico", "Zeca", "Pixel", "Tico"]),
        ("cat-ragdoll", L("Ragdoll"), ["Nuvem", "Floquinho", "Algodão", "Yuki", "Mochi", "Pérola"]),
    ]

    // Loose SwiftPM PNG resources need an explicit URL on macOS; name-based
    // SwiftUI Image lookup can render an empty frame outside an asset catalog.
    @MainActor static let artwork: [String: NSImage] = Dictionary(uniqueKeysWithValues: families.compactMap { family in
        guard let url = PackagedResourceBundle.bundle(target: "Surfaces")?.url(forResource: family.asset, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return (family.asset, image)
    })
}

extension SubagentActivityItem {
    var cat: SubagentCatIdentity { SubagentCatIdentity(id: runId?.value ?? id) }
}

/// The same bundled artwork is used in the badge, roster and transcript header.
struct SubagentCatAvatar: View {
    let cat: SubagentCatIdentity
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image = SubagentCatIdentity.artwork[cat.assetName] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct SubagentStatusPill: View {
    let item: SubagentActivityItem

    var body: some View {
        DSPill(item.statusLabel, tone: tone)
    }

    private var tone: DSPill.Tone {
        switch item.phase {
        case .working: return .accent
        case .completed: return .success
        case .failed: return .danger
        case .cancelled, .unknown: return .warning
        }
    }
}
