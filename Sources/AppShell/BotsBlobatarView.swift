import SwiftUI
import CoreModel
import DesignSystemKit
import Surfaces

/// Studio composer. Control set is blobatar's editor; tiles follow bloub.
struct BotBlobatarEditor: View {
    @Binding var token: String
    var seed: String
    var handle: String = ""

    private var spec: BotBlobatarSpec {
        BotBlobatarSpec.parse(token) ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            section(L("Shape")) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64), spacing: DS.Space.sm)],
                    spacing: DS.Space.md
                ) {
                    ForEach(BotBlobatarShape.allCases, id: \.self) { shape in
                        tile(
                            label: shape.displayName,
                            selected: spec.shape == shape,
                            identifier: "bots.studio.avatar.shape.\(shape.rawValue)",
                            preview: previewing { $0.shape = shape }
                        ) {
                            apply { $0.shape = shape }
                        }
                    }
                }
            }
            section(L("Color")) {
                hueRow
            }
        }
        .padding(DS.Space.xl)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityIdentifier("bots.studio.avatar")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            content()
        }
    }

    private func tile(label: String, selected: Bool, identifier: String, preview: BotBlobatarSpec, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs) {
                BotBlobatarView(name: seed, spec: preview, size: 36, motion: .frozen, handle: handle)
                Text(label)
                    .font(DS.Font.caption2)
                    .foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: BotsChrome.hitTarget)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.surfaceOverlay : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(selected ? DS.Palette.accent : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var hueRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            let autoSelected = spec.hue == .auto
            Button {
                apply { $0.hue = .auto }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    let automatic = BotBlobatar.figure(name: seed, spec: previewing { $0.hue = .auto }, handle: handle)
                    Circle().fill(Color(hex: automatic.palette.head)).frame(width: 18, height: 18)
                    Text(L("Auto")).font(DS.Font.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    if autoSelected { Image(systemName: "checkmark").font(DS.Font.caption) }
                }
                .foregroundColor(DS.Palette.text)
                .padding(.horizontal, DS.Space.sm)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(autoSelected ? DS.Palette.surfaceOverlay : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Automatic color"))
            .accessibilityAddTraits(autoSelected ? .isSelected : [])
            .accessibilityIdentifier("bots.studio.avatar.hue.auto")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: DS.Space.sm)], alignment: .leading, spacing: DS.Space.sm) {
                ForEach(BotBlobatar.studioHues, id: \.id) { swatch in
                    let selected = spec.hue == .named(swatch.id)
                    Button {
                        apply { $0.hue = .named(swatch.id) }
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.preview))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                            .overlay(
                                Circle()
                                    .strokeBorder(selected ? DS.Palette.text : Color.clear, lineWidth: 2)
                                    .padding(-3)
                            )
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.id.capitalized)
                    .help(swatch.id.capitalized)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("bots.studio.avatar.hue.\(swatch.id)")
                }
            }
        }
        .accessibilityIdentifier("bots.studio.avatar.hue")
    }

    private func previewing(_ mutate: (inout BotBlobatarSpec) -> Void) -> BotBlobatarSpec {
        var next = spec
        mutate(&next)
        return spec.selecting(shape: next.shape, hue: next.hue, name: seed, handle: handle)
    }

    private func apply(_ mutate: (inout BotBlobatarSpec) -> Void) {
        token = previewing(mutate).token
    }
}
