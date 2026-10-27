import AgentRuntime
import CoreModel
import DesignSystemKit
import SwiftUI
import Surfaces

/// Content of the Auto model guide. Shown inside the model sheet; edits the same
/// Distill Auto profile as Settings > Accounts & Auto.
struct DistillAutoGuideSheet: View {
    @ObservedObject var controller: DistillAccountsController
    let loadModels: () async -> [AgentModelDescriptor]
    let onClose: () -> Void
    @State private var draft: DistillAutoRouting?

    private var current: DistillAutoRouting { draft ?? controller.routing }
    private var hasChanges: Bool { current != controller.routing }
    private var validationError: String? {
        DistillRoutingValidation.error(current, saved: controller.routing, accounts: controller.statuses, models: controller.models)
    }

    var body: some View {
        Group {
            if controller.hasLoadedState {
                loadedBody
            } else if let stateError = controller.stateError, !controller.isRefreshing {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    Text(stateError).font(DS.Font.caption).foregroundColor(DS.Palette.warning)
                    Button("Retry") { controller.refresh() }
                        .buttonStyle(DSPrimaryButtonStyle())
                        .accessibilityIdentifier("agent.autoGuide.retry")
                }
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .leading)
            } else {
                loadingBody
            }
        }
        .frame(width: 560, alignment: .leading)
        .task { controller.refresh() }
        .task(id: controller.statuses.filter(\.connected).map(\.id) + [controller.routing.enabled ? "auto-enabled" : "auto-disabled"]) {
            _ = await controller.discoverModels(using: loadModels)
        }
    }

    private var loadedBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            DistillAutoRoutingEditor(
                draft: Binding(get: { current }, set: { draft = $0 }),
                saved: controller.routing,
                statuses: controller.statuses,
                models: controller.models,
                disabled: controller.isBusy
            )
            Divider()
            actionRow
        }
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.md) {
                ProgressView().controlSize(.small)
                Text("Loading Auto profile…")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
        }
        .accessibilityIdentifier("agent.autoGuide.loading")
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if let stateError = controller.stateError {
                Text(stateError)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { controller.refresh() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("agent.autoGuide.retry")
            }
            if controller.isRefreshing {
                Text("Refreshing Auto profile…")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            if let error = controller.lastError {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let validationError {
                Text(validationError)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.md) {
                Text(statusText)
                    .font(DS.Font.caption)
                    .foregroundColor(hasChanges ? DS.Palette.warning : DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.md)
                if hasChanges {
                    Button("Cancel") { draft = nil }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .disabled(controller.isBusy)
                        .accessibilityIdentifier("agent.autoGuide.cancel")
                    Button("Save") { controller.saveRouting(current) }
                        .buttonStyle(DSPrimaryButtonStyle())
                        .disabled(controller.isBusy || validationError != nil)
                        .accessibilityIdentifier("agent.autoGuide.save")
                }
            }
        }
    }

    /// Installs the factory that the model sheet uses to render the Auto guide.
    @MainActor static func installFactory(context: AppContext) {
        AgentAccountsInline.make = { [weak context] in
            guard let context else { return AnyView(EmptyView()) }
            return AnyView(DistillAccountsInlineDisclosure(
                controller: context.distillAccountsController,
                loadModels: { [weak context] in await context?.router?.listAgentModels(provider: .distill) ?? [] }
            ))
        }
        AgentAutoGuide.makeGuide = { [weak context] onClose in
            guard let context else { return AnyView(EmptyView()) }
            return AnyView(DistillAutoGuideSheet(
                controller: context.distillAccountsController,
                loadModels: { [weak context] in await context?.router?.listAgentModels(provider: .distill) ?? [] },
                onClose: onClose
            ))
        }
    }

    private var statusText: String {
        if controller.isBusy { return "Saving…" }
        if controller.isRefreshing { return "Refreshing Auto profile…" }
        if hasChanges { return "Unsaved changes" }
        return "Saved · Auto \(controller.routing.enabled ? "on" : "off")"
    }
}
