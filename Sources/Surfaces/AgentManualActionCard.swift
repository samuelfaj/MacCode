import AppKit
import SwiftUI
import CoreModel
import Persistence
import DesignSystemKit

extension AgentAppViewModel {
    /// Header pill text; a pending manual action overrides the run status.
    public var statusLabel: String {
        openManualAction == nil ? status.rawValue : "Waiting for you"
    }

    func manualActionStoreDidChange() {
        refreshManualAction()
        guard manualActionStore != nil else { return }
        if manualActionStateObserver == nil {
            manualActionStateObserver = NotificationCenter.default.addObserver(
                forName: .manualActionStateChanged, object: nil, queue: .main
            ) { [weak self] note in
                let threadID = note.userInfo?[BotHostNotificationKey.threadID] as? AgentThreadID
                MainActor.assumeIsolated {
                    guard let self, threadID == nil || threadID == self.selectedThreadId else { return }
                    self.refreshManualAction()
                }
            }
        }
        guard manualActionObserver == nil else { return }
        manualActionObserver = NotificationCenter.default.addObserver(
            forName: .botManualActionRequested, object: nil, queue: .main
        ) { [weak self] note in
            guard let request = note.userInfo?[BotHostNotificationKey.request] as? ManualActionRequest else { return }
            MainActor.assumeIsolated { self?.manualActionRequested(request) }
        }
    }

    private func manualActionRequested(_ request: ManualActionRequest) {
        guard let threadID = request.threadID, threadID == selectedThreadId, let store = manualActionStore else { return }
        // The router persists too; upsert is idempotent and keeps the card independent of observer order.
        if store.all(threadID: threadID).first(where: { $0.id == request.id }) == nil {
            do { try store.upsert(request) } catch { reportManualActionStoreFailure(error) }
        }
        refreshManualAction()
    }

    private func reportManualActionStoreFailure(_ error: Error) {
        statusMessage = "Manual action could not be saved: \(error.localizedDescription)"
    }

    private func postManualActionStateChanged(_ request: ManualActionRequest) {
        // The request lets the host publish agent.manual_action.updated for paired devices.
        var info: [String: Any] = [BotHostNotificationKey.request: request]
        if let threadID = request.threadID { info[BotHostNotificationKey.threadID] = threadID }
        NotificationCenter.default.post(name: .manualActionStateChanged, object: nil, userInfo: info)
    }

    func refreshManualAction() {
        guard let store = manualActionStore, let threadID = selectedThreadId else {
            if openManualAction != nil { openManualAction = nil }
            if !resolvedManualActions.isEmpty { resolvedManualActions = [] }
            return
        }
        var open = store.open(threadID: threadID)
        // Control is in-memory only: after a restart a taken request is handed back to the bot.
        if var request = open, request.state == .taken, !botComputerControl.isControlledByUser(request.botID) {
            request.state = .open
            do { try store.upsert(request) } catch { reportManualActionStoreFailure(error) }
            open = request
        }
        let resolved = store.all(threadID: threadID).filter { $0.state == .continued || $0.state == .declined }
        let controlled = botScreenBotID.map { botComputerControl.isControlledByUser($0) } ?? false
        if botScreenControlled != controlled { botScreenControlled = controlled }
        if openManualAction != open { openManualAction = open }
        if resolvedManualActions != resolved { resolvedManualActions = resolved }
    }

    /// The bot whose VM screen the selected thread uses; nil for any other thread.
    public var botScreenBotID: BotID? {
        guard let thread = threads.first(where: { $0.id == selectedThreadId }),
              thread.executionTarget == .vm, case .bot(let botID) = thread.actor else { return nil }
        return botID
    }

    public func viewBotScreen() {
        if let botID = botScreenBotID { openBotScreen?(botID) }
    }

    /// Handing control back with an open request behaves like "Ready, continue"; otherwise it only releases control.
    public func toggleBotScreenControl() async {
        guard let botID = botScreenBotID else { return }
        if botComputerControl.isControlledByUser(botID) {
            if let request = openManualAction, request.botID == botID {
                await continueManualAction(note: nil)
            } else {
                botComputerControl.release(botID)
            }
        } else if let request = openManualAction, request.botID == botID {
            takeManualControl()
        } else {
            botComputerControl.take(botID, threadID: selectedThreadId)
        }
        botScreenControlled = botComputerControl.isControlledByUser(botID)
    }

    public func takeManualControl() {
        guard let store = manualActionStore, let request = openManualAction else { return }
        do {
            // Stale cards lose here: a terminal or already-taken request is never revived.
            if try store.take(id: request.id, control: botComputerControl) != nil {
                postManualActionStateChanged(request)
            }
        } catch {
            reportManualActionStoreFailure(error)
        }
        refreshManualAction()
    }

    public func continueManualAction(note: String?) async {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (trimmed?.isEmpty ?? true) ? nil : trimmed
        await resolveManualAction(.continued, note: stored) {
            ManualActionRequest.continueFollowUp(kind: $0.kind, note: stored)
        }
    }

    public func declineManualAction() async {
        await resolveManualAction(.declined, note: nil) { _ in ManualActionRequest.declineFollowUp }
    }

    /// The store transition is the single winner: any later or parallel caller gets nil and stays silent.
    private func resolveManualAction(
        _ state: ManualActionState,
        note: String?,
        followUp: (ManualActionRequest) -> String
    ) async {
        guard let store = manualActionStore, let open = openManualAction else {
            refreshManualAction()
            return
        }
        let resolved: ManualActionRequest
        do {
            guard let result = try store.resolve(id: open.id, state: state, note: note, control: botComputerControl) else {
                refreshManualAction()
                return
            }
            resolved = result
        } catch {
            reportManualActionStoreFailure(error)
            refreshManualAction()
            return
        }
        postManualActionStateChanged(resolved)
        refreshManualAction()
        await sendManualActionFollowUp(followUp(resolved))
    }

    /// Goes through the normal composer send path; the user's draft is put back afterwards.
    private func sendManualActionFollowUp(_ text: String) async {
        let draft = prompt
        let draftAttachments = attachments
        attachments = []
        prompt = text
        await send()
        if prompt.isEmpty { prompt = draft }
        attachments = draftAttachments
    }
}

struct AgentManualActionCard: View {
    @ObservedObject var vm: AgentAppViewModel
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let request = vm.openManualAction {
                openCard(request)
            }
            ForEach(vm.resolvedManualActions) { request in
                resolvedRow(request)
            }
        }
        .accessibilityIdentifier("agent.manualAction")
    }

    private func openCard(_ request: ManualActionRequest) -> some View {
        let executesOnMac = vm.threads.first(where: { $0.id == vm.selectedThreadId })?.executionTarget == .mac
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: Self.symbol(request.kind))
                    .font(.system(size: 12))
                    .foregroundColor(DS.Palette.warning)
                Text("\(vm.botNameProvider(request.botID) ?? "Bot") is waiting for you")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer(minLength: 0)
                Text(request.createdAt, style: .relative)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            Text(request.reason)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
            if let ref = request.screenshotRef, FileManager.default.fileExists(atPath: ref),
               let image = NSImage(contentsOfFile: ref) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 120)
                    .cornerRadius(6)
            }
            TextField("Note for the bot (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Note for the bot")
                .accessibilityIdentifier("agent.manualAction.note")
            HStack(spacing: DS.Space.sm) {
                if !executesOnMac {
                    Button(request.state == .taken ? "Control taken" : "Take control") {
                        vm.takeManualControl()
                    }
                    .disabled(request.state == .taken)
                    .help("Drive the bot's computer yourself; the bot stays paused")
                    .accessibilityIdentifier("agent.manualAction.take")
                }
                if request.kind == .file, vm.importFilesToBotComputer != nil,
                   let named = MacPathReferences.requestedFile(in: request.reason, home: NSHomeDirectory()) {
                    Button("Send \(named.lastPathComponent)") { sendFiles([named], for: request) }
                        .buttonStyle(.borderedProminent)
                        .help("Copy \(named.path) into the bot's Linux desktop and resume the bot")
                        .accessibilityIdentifier("agent.manualAction.sendNamedFile")
                }
                if request.kind == .file, vm.importFilesToBotComputer != nil {
                    Button("Choose file…") { chooseFiles(for: request) }
                        .help("Copy files from this Mac into the bot's Linux desktop and resume the bot")
                        .accessibilityIdentifier("agent.manualAction.chooseFile")
                }
                Button("Ready, continue") {
                    let text = note
                    note = ""
                    Task { await vm.continueManualAction(note: text) }
                }
                .help("Resume the bot with your note")
                .accessibilityIdentifier("agent.manualAction.continue")
                Button("Decline") {
                    Task { await vm.declineManualAction() }
                }
                .help("Tell the bot to continue without this step, or stop")
                .accessibilityIdentifier("agent.manualAction.decline")
            }
        }
        .padding(DS.Space.sm)
        .background(DS.Palette.surface)
        .cornerRadius(8)
    }

    private func chooseFiles(for request: ManualActionRequest) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send to Linux desktop"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        sendFiles(panel.urls, for: request)
    }

    private func sendFiles(_ urls: [URL], for request: ManualActionRequest) {
        guard let importFiles = vm.importFilesToBotComputer else { return }
        do {
            let paths = try importFiles(request.botID, request.threadID, urls)
            let typed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            note = ""
            let copied = "Files copied into the Linux desktop: " + paths.joined(separator: ", ")
            Task { await vm.continueManualAction(note: typed.isEmpty ? copied : "\(copied). \(typed)") }
        } catch {
            vm.statusMessage = "Could not copy files to the Linux desktop: \(error.localizedDescription)"
        }
    }

    private func resolvedRow(_ request: ManualActionRequest) -> some View {
        let minutes = max(0, Int((request.resolvedAt ?? request.createdAt).timeIntervalSince(request.createdAt) / 60))
        let outcome = request.state == .declined ? "declined" : "continued"
        return HStack(spacing: DS.Space.sm) {
            Image(systemName: Self.symbol(request.kind))
                .font(.system(size: 10))
                .foregroundColor(DS.Palette.textTertiary)
            Text("You took over for \(minutes) min · \(outcome)")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
    }

    static func symbol(_ kind: ManualActionKind) -> String {
        switch kind {
        case .login: return "person.badge.key"
        case .captcha: return "checkmark.shield"
        case .twoFactor: return "lock.shield"
        case .payment: return "creditcard"
        case .confirm: return "hand.raised"
        case .file: return "doc.badge.plus"
        case .other: return "hand.point.up.left"
        }
    }
}
