import AgentRuntime
import CoreModel
import DesignSystemKit
import SwiftUI

/// Auto profile editor. Mounted by Settings > Accounts & Auto and the Auto model
/// guide, so both edit the same draft shape with the same validation.
public struct DistillAutoRoutingEditor: View {
    @Binding public var draft: DistillAutoRouting
    public let saved: DistillAutoRouting
    public let statuses: [DistillAccountStatus]
    public let models: [AgentModelDescriptor]
    public let disabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(draft: Binding<DistillAutoRouting>, saved: DistillAutoRouting, statuses: [DistillAccountStatus],
                models: [AgentModelDescriptor], disabled: Bool = false) {
        self._draft = draft
        self.saved = saved
        self.statuses = statuses
        self.models = models
        self.disabled = disabled
    }

    private var validationError: String? {
        DistillRoutingValidation.error(draft, saved: saved, accounts: statuses, models: models)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            enableRow
            if draft.enabled {
                Group {
                    strategyRow
                    optionsSection
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: draft.enabled)
            } else {
                offHint
            }
            if let error = validationError {
                AgentChoiceCallout(icon: "exclamationmark.triangle.fill", tint: DS.Palette.warning, text: error)
            }
        }
        .disabled(disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Enable

    private var enableRow: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Enable Auto for all conversations")).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Text(L("This global profile affects all Auto conversations and Bots."))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.lg)
            Toggle(L("Enable Auto for all conversations"), isOn: Binding(get: { draft.enabled }, set: { value in
                var next = draft
                next.enabled = value
                draft = next
            }))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private var offHint: some View {
        Text(L("Auto is off. Existing Auto threads and tasks need the profile enabled on the next turn."))
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textTertiary)
    }

    // MARK: Strategy

    private var strategyRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(L("Pick accounts")).font(DS.Font.captionStrong).foregroundColor(DS.Palette.textSecondary)
            AgentChoiceSegmented(
                options: [
                    (value: DistillAutoStrategy.orderedFirst, title: "In order", help: "Try connected accounts in the order below."),
                    (value: DistillAutoStrategy.highestRemaining, title: "Most quota left", help: "Prefer the connected account with the highest known remaining quota.")
                ],
                selection: draft.strategy,
                onSelect: { strategy in
                    var next = draft
                    next.strategy = strategy
                    draft = next
                }
            )
            Text(draft.strategy == .orderedFirst
                 ? "Uses the first available option below."
                 : "Uses the option with the most quota left.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text(L("Options")).font(DS.Font.captionStrong).foregroundColor(DS.Palette.textSecondary)
                Text(L("%1$@", draft.options.count))
                    .font(DS.Font.caption2.monospacedDigit())
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
            }
            if statuses.isEmpty {
                AgentChoiceCallout(icon: "person.crop.circle.badge.exclamationmark", tint: DS.Palette.warning,
                                   text: "Add an account on the left to use Auto.")
            } else if draft.options.isEmpty {
                AgentChoiceCallout(icon: "info.circle", tint: DS.Palette.accent,
                                   text: "Add an option to choose an account and its models.")
            }
            VStack(spacing: DS.Space.sm) {
                ForEach(Array(draft.options.enumerated()), id: \.element.id) { index, option in
                    optionCard(option, index: index)
                }
            }
            addOptionButton
        }
    }

    private var addOptionButton: some View {
        Button(action: addOption) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "plus.circle.fill").font(.system(size: 13))
                Text(L("Add option"))
            }
            .font(DS.Font.caption.weight(.semibold))
            .foregroundColor(statuses.isEmpty ? DS.Palette.textTertiary : DS.Palette.accent)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
        .disabled(statuses.isEmpty)
        .help("Add an option")
    }

    private func optionCard(_ option: DistillAutoOption, index: Int) -> some View {
        let account = statuses.first { $0.id == option.accountID }
        let eligible = DistillRoutingValidation.models(for: account, catalog: models)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.md) {
                Text(L("%1$@", index + 1))
                    .font(DS.Font.caption.weight(.bold).monospacedDigit())
                    .foregroundColor(DS.Palette.accent)
                    .frame(width: 22, height: 22)
                    .background(DS.Palette.accent.opacity(0.14), in: Circle())
                    .accessibilityLabel("Option \(index + 1)")
                accountField(option, account: account)
                Menu {
                    Button(L("Move up")) { moveOption(option.id, offset: -1) }
                        .disabled(index == 0)
                    Button(L("Move down")) { moveOption(option.id, offset: 1) }
                        .disabled(index == draft.options.count - 1)
                    Divider()
                    Button(L("Remove"), role: .destructive) { removeOption(option.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(DS.Palette.surfaceOverlay.opacity(0.6), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for option \(index + 1)")
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.md)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.md) {
                    mainPicker(option, eligible: eligible).frame(minWidth: 160)
                    workerPicker(option, eligible: eligible).frame(minWidth: 160)
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    mainPicker(option, eligible: eligible)
                    workerPicker(option, eligible: eligible)
                }
            }
            .padding(DS.Space.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.accounts.routing.\(option.id)")
    }

    private func mainPicker(_ option: DistillAutoOption, eligible: [AgentModelDescriptor]) -> some View {
        modelField(
            title: "Main", icon: "cpu", help: option.mainModel,
            display: eligible.first { $0.id == option.mainModel }?.label
                ?? (option.mainModel.isEmpty ? "Choose model" : "Unavailable: \(option.mainModel)"),
            selection: Binding(get: { option.mainModel }, set: { model in editOption(option.id) { $0.mainModel = model } })
        ) {
            if !eligible.contains(where: { $0.id == option.mainModel }) {
                Text(option.mainModel.isEmpty ? "Choose model" : "Unavailable: \(option.mainModel)").tag(option.mainModel)
            }
            ForEach(eligible, id: \.id) { Text($0.label).tag($0.id) }
        }
    }

    private func workerPicker(_ option: DistillAutoOption, eligible: [AgentModelDescriptor]) -> some View {
        let worker = option.workerModel ?? ""
        return modelField(
            title: "Worker", icon: "bolt.horizontal", help: option.workerModel ?? "Same as Main",
            display: worker.isEmpty ? "Same as Main"
                : (eligible.first { $0.id == worker }?.label ?? "Unavailable: \(worker)"),
            selection: Binding(get: { worker }, set: { model in
                editOption(option.id) { $0.workerModel = model.isEmpty ? nil : model }
            })
        ) {
            Text(L("Same as Main")).tag("")
            if !worker.isEmpty, !eligible.contains(where: { $0.id == worker }) {
                Text(L("Unavailable: %1$@", worker)).tag(worker)
            }
            ForEach(eligible, id: \.id) { Text($0.label).tag($0.id) }
        }
    }

    /// Caption above a dark pill menu; the menu shows checkmarks via an inline picker.
    private func modelField<Content: View>(title: String, icon: String, help: String, display: String,
                                           selection: Binding<String>,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label(title, systemImage: icon)
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .textCase(.uppercase)
                .labelStyle(.titleAndIcon)
            Menu {
                Picker(title, selection: selection) { content() }
                    .pickerStyle(.inline)
                    .labelsHidden()
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Text(display)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .padding(.horizontal, DS.Space.md)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(DS.Palette.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(help)
            .accessibilityLabel(title)
            .accessibilityValue(display)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountField(_ option: DistillAutoOption, account: DistillAccountStatus?) -> some View {
        let remaining = account.flatMap {
            DistillAccountsPanelPresentation.quotaPresentation($0.quota, connected: $0.connected, connectionError: $0.connectionError).remainingPercent
        }
        let title = account.map { "\($0.provider.displayName) · \($0.label)" } ?? "Choose account"
        let connected = account?.connected == true
        let status: String? = account == nil ? nil
            : (!connected ? "Not connected" : remaining.map { "Connected · \(Int($0.rounded()))% remaining" } ?? "Connected")
        return Menu {
            Picker(L("Account"), selection: Binding(get: { option.accountID }, set: { id in
                editOption(option.id) {
                    $0.accountID = id
                    $0.mainModel = DistillRoutingValidation.models(for: statuses.first { $0.id == id }, catalog: models).first?.id ?? ""
                    $0.workerModel = nil
                }
            })) {
                if account == nil { Text(L("Choose account")).tag(option.accountID) }
                ForEach(statuses, id: \.id) { Text(L("%1$@ · %2$@", $0.provider.displayName, $0.label)).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DS.Space.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let status {
                        HStack(spacing: DS.Space.xs) {
                            Circle()
                                .fill(connected ? DS.Palette.success : DS.Palette.textTertiary)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(status)
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(title)
        .accessibilityLabel("Account")
        .accessibilityValue(title)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Draft mutations

    private func addOption() {
        let account = statuses.first
        let model = DistillRoutingValidation.models(for: account, catalog: models).first
        var value = draft
        value.options.append(.init(id: UUID().uuidString.lowercased(), accountID: account?.id ?? "", mainModel: model?.id ?? ""))
        draft = value
    }

    private func editOption(_ id: String, _ edit: (inout DistillAutoOption) -> Void) {
        var value = draft
        guard let index = value.options.firstIndex(where: { $0.id == id }) else { return }
        edit(&value.options[index])
        draft = value
    }

    private func moveOption(_ id: String, offset: Int) {
        var value = draft
        guard let index = value.options.firstIndex(where: { $0.id == id }), value.options.indices.contains(index + offset) else { return }
        value.options.swapAt(index, index + offset)
        draft = value
    }

    private func removeOption(_ id: String) {
        var value = draft
        value.options.removeAll { $0.id == id }
        draft = value
    }
}
