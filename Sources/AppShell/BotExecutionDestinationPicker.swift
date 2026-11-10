import CoreModel
import DesignSystemKit
import Persistence
import SocketServer
import SwiftUI

/// The same destination choice in Bot Studio and Schedule Tasks.
struct BotExecutionDestinationPicker: View {
    @Binding var selection: BotExecutionDestination
    let bot: BotDefinition?
    let store: BotStore
    let workspaces: [Workspace]
    @State private var machines: [BotVirtualMachine] = []
    @State private var managing = false
    @State private var error: String?

    private var available: [BotVirtualMachine] {
        machines.filter { machine in
            guard let bot else { return machine.workspaceID == nil }
            return machine.allows(bot) && (machine.workspaceID == nil || workspaces.contains { $0.id == machine.workspaceID })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Picker(L("Run on"), selection: $selection) {
                Text(L("This Mac")).tag(BotExecutionDestination.mac)
                Text(L("Own VM")).tag(BotExecutionDestination.ownVM)
                Section("General VMs") {
                    ForEach(available.filter { $0.workspaceID == nil }) { machine in
                        Text(machine.name).tag(BotExecutionDestination.virtualMachine(machine.id))
                    }
                }
                if let workspaceID = bot?.workspaceID {
                    Section(workspaces.first { $0.id == workspaceID }?.name ?? "Workspace VMs") {
                        ForEach(available.filter { $0.workspaceID == workspaceID }) { machine in
                            Text(machine.name).tag(BotExecutionDestination.virtualMachine(machine.id))
                        }
                    }
                }
                if let id = selection.virtualMachineID, !available.contains(where: { $0.id == id }) {
                    Text(L("Unavailable VM — choose another")).tag(selection)
                }
            }
            .accessibilityIdentifier("bots.execution.destination")

            Text(explanation)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Manage VMs…")) { managing = true }
                .accessibilityIdentifier("bots.execution.manage")
            if let error {
                Text(error).font(DS.Font.caption).foregroundStyle(DS.Palette.danger)
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $managing, onDismiss: reload) {
            BotVirtualMachinesView(store: store, workspaces: workspaces)
        }
    }

    private var explanation: String {
        switch selection {
        case .mac: return "Runs on this Mac using your local environment."
        case .ownVM: return "A Linux desktop reserved for this bot."
        case .virtualMachine:
            return "Bots using this VM share its files, apps and browser sessions. One conversation runs at a time; others wait."
        }
    }

    private func reload() {
        do { machines = try store.listVirtualMachines(); error = nil }
        catch { self.error = String(describing: error) }
    }
}

struct BotVirtualMachinesView: View {
    let store: BotStore
    let workspaces: [Workspace]
    var initialWorkspaceID: WorkspaceID? = nil
    var initialMachine: BotVirtualMachine? = nil
    /// Set when mounted as a workspace's VMs tab: lists and creates only that workspace's VMs.
    var lockedWorkspaceID: WorkspaceID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var machines: [BotVirtualMachine] = []
    @State private var name = ""
    @State private var scope: WorkspaceID?
    @State private var editingID: UUID?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                Text(L("Virtual machines")).font(DS.Font.title)
                Spacer()
                if lockedWorkspaceID == nil {
                    Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            Text(lockedWorkspaceID == nil
                 ? "General VMs can be shared by any bot. Workspace VMs are available only to bots exclusive to that workspace."
                 : "These VMs are available only to bots exclusive to this workspace.")
                .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            List(machines) { machine in
                HStack(alignment: .top, spacing: DS.Space.md) {
                    Image(systemName: "desktopcomputer").accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(machine.name).font(DS.Font.bodyStrong).textSelection(.enabled)
                        Text(scopeName(machine)).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer(minLength: DS.Space.md)
                    Button(L("Rename")) {
                        editingID = machine.id
                        name = machine.name
                        scope = machine.workspaceID
                    }
                    .accessibilityLabel("Rename \(machine.name)")
                }
                .padding(.vertical, DS.Space.xs)
            }
            .overlay {
                if machines.isEmpty {
                    Text(lockedWorkspaceID == nil ? "No shared VMs yet. Create one below." : "No VMs in this workspace yet. Create one below.")
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            Form {
                TextField(L("Name"), text: $name)
                    .onSubmit(save)
                    .accessibilityIdentifier("bots.vm.name")
                if lockedWorkspaceID == nil {
                    Picker(L("Available to"), selection: $scope) {
                        Text(L("All bots (General)")).tag(WorkspaceID?.none)
                        ForEach(workspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }
                    .disabled(editingID != nil)
                    .accessibilityIdentifier("bots.vm.scope")
                }
            }
            if let error {
                Text(error).font(DS.Font.caption).foregroundStyle(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(L("Linux · Docker is required when the VM starts"))
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                if editingID != nil {
                    Button(L("Cancel")) { editingID = nil; name = ""; scope = lockedWorkspaceID; error = nil }
                }
                Button(editingID == nil ? "Create VM" : "Save name", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("bots.vm.save")
            }
        }
        .padding(DS.Space.xl)
        .frame(
            minWidth: lockedWorkspaceID == nil ? 560 : 320, maxWidth: lockedWorkspaceID == nil ? 560 : .infinity,
            minHeight: lockedWorkspaceID == nil ? 490 : 320, maxHeight: lockedWorkspaceID == nil ? 490 : .infinity,
            alignment: .topLeading
        )
        .onAppear {
            scope = lockedWorkspaceID ?? initialMachine?.workspaceID ?? initialWorkspaceID
            editingID = initialMachine?.id
            name = initialMachine?.name ?? ""
            reloadMachines()
        }
    }

    private func scopeName(_ machine: BotVirtualMachine) -> String {
        guard let id = machine.workspaceID else { return "General · All bots" }
        return workspaces.first { $0.id == id }.map { "Workspace · \($0.name)" } ?? "Workspace unavailable"
    }

    private func save() {
        do {
            if let scope, !workspaces.contains(where: { $0.id == scope }) {
                throw BotStoreError.invalidInput("This workspace is no longer available.")
            }
            let machine = try store.saveVirtualMachine(id: editingID, name: name, workspaceID: scope)
            EventBus.shared.publish(kind: .botUpdated, payload: .object([
                "method": .string("bot.vm.save"),
                "vm_id": .string(machine.id.uuidString.lowercased())
            ]))
            reloadMachines()
            editingID = nil
            name = ""
            error = nil
        } catch { self.error = String(describing: error) }
    }

    private func reloadMachines() {
        do { machines = try store.listVirtualMachines().filter { lockedWorkspaceID == nil || $0.workspaceID == lockedWorkspaceID } }
        catch { self.error = String(describing: error) }
    }
}
