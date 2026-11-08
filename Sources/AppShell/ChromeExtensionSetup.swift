import AppKit
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit

@MainActor
final class ChromeExtensionSetup: ObservableObject {
    enum State: Equatable {
        case disconnected
        case preparing
        case awaitingChrome
        case connected
        case failed(String)

        var message: String {
            switch self {
            case .disconnected: return "Connect Chrome to use your existing logins in background tabs."
            case .preparing: return "Preparing the Chrome extension…"
            case .awaitingChrome: return "Local setup is ready. Finish loading the extension in Chrome."
            case .connected: return "Chrome is connected. Your background tabs can use your existing logins."
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var checking = false
    @Published private(set) var extensionDirectory: URL?
    private var generation: UInt64 = 0
    private let prepare: @Sendable () async throws -> URL
    private let connected: @Sendable () async -> Bool
    private let openSetup: @MainActor (URL) async throws -> Void

    init(
        prepare: @escaping @Sendable () async throws -> URL = {
            try await Task.detached(priority: .userInitiated) {
                guard let helper = AgentSkillInstaller.resolveServiceBinary() else {
                    throw NSError(domain: "RemoteCode.ChromeSetup", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The Chrome connection helper is missing. Reinstall MacCode and try again."])
                }
                return try ChromeProfileConnection.install(executable: helper.path)
            }.value
        },
        connected: @escaping @Sendable () async -> Bool = {
            await Task.detached(priority: .utility) {
                let reply = try? ChromeProfileConnection.request([
                    "operation": "browser_status", "session": UUID().uuidString,
                ])
                return reply?["ok"] as? Bool == true && reply?["connected"] as? Bool == true
            }.value
        },
        openSetup: @escaping @MainActor (URL) async throws -> Void = { folder in
            guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
                throw NSError(domain: "RemoteCode.ChromeSetup", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Install Google Chrome, then try setup again."])
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            _ = try await NSWorkspace.shared.open(
                [URL(string: "chrome://extensions")!], withApplicationAt: chrome,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    ) {
        self.prepare = prepare
        self.connected = connected
        self.openSetup = openSetup
    }

    func install() async {
        guard state != .preparing else { return }
        generation &+= 1
        let current = generation
        checking = false
        state = .preparing
        defer {
            if current == generation, state == .preparing {
                state = extensionDirectory == nil ? .disconnected : .awaitingChrome
            }
        }
        do {
            let folder = try await prepare()
            guard current == generation, !Task.isCancelled else { return }
            extensionDirectory = folder
            try await openSetup(folder)
            guard current == generation, !Task.isCancelled else { return }
            state = .awaitingChrome
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard !checking, state != .preparing else { return }
        generation &+= 1
        let current = generation
        checking = true
        let isConnected = await connected()
        guard current == generation else { return }
        checking = false
        guard !Task.isCancelled else { return }
        if isConnected {
            state = .connected
        } else if state == .connected {
            state = extensionDirectory == nil ? .disconnected : .awaitingChrome
        }
    }
}

struct ChromeExtensionSettingsSection: View {
    @StateObject private var setup: ChromeExtensionSetup
    private let showGuide: Bool

    @MainActor init(setup: ChromeExtensionSetup? = nil, showGuide: Bool = false) {
        _setup = StateObject(wrappedValue: setup ?? ChromeExtensionSetup())
        self.showGuide = showGuide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Computer Use")
            Text("Use Chrome in background tabs without taking over your mouse or keyboard. Selecting an automated tab gives control back to you.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.md) { actions }
                VStack(alignment: .leading, spacing: DS.Space.md) { actions }
            }
            Text(setup.state.message)
                .font(DS.Font.caption)
                .foregroundColor(statusColor)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings.computerUse.chrome.status")
            if showGuide, let folder = setup.extensionDirectory {
                Text(folder.path).font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    .help(folder.path)
                    .accessibilityIdentifier("onboarding.chrome.extensionFolder")
                Button("Show Extension Folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("onboarding.chrome.showFolder")
            }
            if showGuide {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    instruction("1", title: "Prepare the extension", detail: "Click Set Up Chrome Extension. MacCode prepares the files and opens Finder and Chrome's extensions page.")
                    instruction("2", title: "Enable Developer mode", detail: "In Chrome, choose the profile you want to connect. Turn on Developer mode at the top right of chrome://extensions.")
                    instruction("3", title: "Choose Load unpacked", detail: "Select the extension folder shown in Finder, not a file inside it. Confirm MacCode Computer Use is enabled and review any Chrome permission prompts.")
                    instruction("4", title: "Check the connection", detail: "Return to MacCode and click Check Connection. If disconnected, click MacCode Computer Use in Chrome's Extensions menu once, then check again. Continue becomes available when Chrome replies.")
                }
                .accessibilityIdentifier("onboarding.chrome.guide")
            }
            if !showGuide && setup.extensionDirectory != nil && setup.state != .connected {
                Text("One-time Chrome setup: enable Developer mode, choose Load unpacked, and select the extension folder shown in Finder. Return here to check the connection.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.computerUse.chrome.instructions")
            }
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier("settings.section.computerUse")
        .task { await setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refresh() }
        }
    }

    private var statusColor: Color {
        if setup.state == .connected { return DS.Palette.success }
        if case .failed = setup.state { return DS.Palette.danger }
        return DS.Palette.textSecondary
    }

    @ViewBuilder private var actions: some View {
        Button(setup.extensionDirectory == nil ? "Set Up Chrome Extension" : "Open Chrome Setup") {
            Task { await setup.install() }
        }
        .buttonStyle(.bordered)
        .disabled(setup.state == .preparing)
        .accessibilityIdentifier("settings.computerUse.chrome.setup")
        Button(setup.checking ? "Checking…" : "Check Connection") {
            Task { await setup.refresh() }
        }
        .buttonStyle(.bordered)
        .disabled(setup.checking || setup.state == .preparing)
        .accessibilityIdentifier("settings.computerUse.chrome.check")
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Text(number).font(DS.Font.captionStrong).foregroundColor(DS.Palette.accent)
                .frame(width: DS.Space.xl)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(title).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Text(detail).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
