import SwiftUI
import CoreModel
import DesignSystemKit
import Surfaces

/// Page chrome shared by the workspace and Bot Schedule Tasks editors, laid out like a Settings page:
/// header bar, hero, then grouped cards. One component so the two editors cannot drift apart.
struct ScheduleEditorPage<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let saveTitle: String
    let saveIdentifier: String
    let isSaving: Bool
    let onBack: () -> Void
    let onSave: () -> Void
    private let content: Content
    private let footer: Footer

    init(
        title: String,
        subtitle: String,
        saveTitle: String,
        saveIdentifier: String,
        isSaving: Bool = false,
        onBack: @escaping () -> Void,
        onSave: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.saveTitle = saveTitle
        self.saveIdentifier = saveIdentifier
        self.isSaving = isSaving
        self.onBack = onBack
        self.onSave = onSave
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.lg) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .disabled(isSaving)
                Spacer()
                Button("Cancel", action: onBack)
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(isSaving)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: onSave)
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(isSaving)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(saveIdentifier)
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.lg)
            .dsBar(edge: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    hero
                    content
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .background(DS.Palette.bg)
    }

    private var hero: some View {
        VStack(spacing: DS.Space.md) {
            AgentChoiceIconTile(systemName: "calendar.badge.clock", tint: DS.Palette.accent, size: 56)
            Text(title)
                .font(DS.Font.title2)
                .foregroundColor(DS.Palette.text)
            Text(subtitle)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Space.xxl)
        .background(RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous).fill(DS.Palette.surfaceRaised))
    }
}

/// A titled card of rows. Rows are separated by hairlines and sit on `surface`, like a Settings section.
struct ScheduleEditorSection<Content: View>: View {
    let title: String
    let caption: String?
    let identifier: String
    private let content: Content

    init(_ title: String, caption: String? = nil, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionHeaderG(title)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            if let caption {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.horizontal, DS.Space.lg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// One row inside a `ScheduleEditorSection`: label (and optional hint) on the left, control on the right.
struct ScheduleEditorRow<Control: View>: View {
    let label: String
    let hint: String?
    let showsDivider: Bool
    private let control: Control

    init(_ label: String, hint: String? = nil, showsDivider: Bool = true, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.showsDivider = showsDivider
        self.control = control()
    }

    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(label)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
            if let hint {
                Text(hint)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider { Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline) }
            // Label left, control right; stacks vertically when the column is too narrow for both.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.lg) {
                    labelBlock
                    Spacer(minLength: DS.Space.lg)
                    control
                }
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    labelBlock
                    control
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .frame(minHeight: 44)
        }
    }
}

/// Raised text field used for the title and name inputs.
struct ScheduleEditorTextField: View {
    let placeholder: String
    @Binding var text: String
    let identifier: String
    /// VoiceOver name; the placeholder is hint copy, not the control name.
    var label = "Name"

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .frame(minHeight: 44)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
    }
}

/// Multi-line prompt box with a placeholder.
struct ScheduleEditorPromptBox: View {
    let placeholder: String
    @Binding var text: String
    let identifier: String
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.lg)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 132)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.md)
        }
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }
}

/// Footer strip showing when the task will run next.
struct ScheduleEditorFooter: View {
    let nextRun: String

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "clock")
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            Text("Next run: \(nextRun)")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, DS.Space.xxl)
        .frame(height: 40)
        .background(DS.Palette.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
    }
}
