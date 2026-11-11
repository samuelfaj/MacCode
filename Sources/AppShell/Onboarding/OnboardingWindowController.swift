import AppKit
import SwiftUI
import DesignSystemKit
import CoreModel

/// Hosts first-run setup in its own titled window above the main window.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    public let window: NSWindow
    let viewModel: OnboardingViewModel
    private let onFinish: () -> Void

    init(viewModel: OnboardingViewModel, setup: OnboardingSetupController, onFinish: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onFinish = onFinish
        let host = NSHostingController(rootView: OnboardingView(vm: viewModel, setup: setup))
        let win = NSWindow(contentViewController: host)
        win.title = L("Set up MacCode")
        win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.backgroundColor = DS.NS.bg
        win.minSize = NSSize(width: 760, height: 600)
        win.setContentSize(NSSize(width: 1040, height: 700))
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win
        super.init()
        win.delegate = self
    }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        viewModel.close()
        onFinish()
    }
}

extension AppDelegate {
    /// Resume unfinished setup; only completion or explicit Skip stops it.
    func presentOnboardingIfNeeded() -> Bool {
        guard !LocalAuthAdapter.isE2EPairingAutoApproveEnabled, let context else { return false }
        let store = OnboardingStateStore(repo: context.settingsRepo)
        let decision = OnboardingGate.launchDecision(
            saved: store.load(),
            hasWorkspaces: !context.state.workspaces.isEmpty,
            hasAccountSession: PrivateAccountSessionStore(repo: context.settingsRepo).load() != nil
        )
        if let initial = decision.stateToSave { store.save(initial) }
        guard decision.present else { return false }
        showOnboarding()
        return true
    }

    /// Opens setup at the saved step (MacCode ▸ Set Up MacCode…).
    @objc func showOnboarding() { openOnboarding(startingAt: nil) }

    /// `step` moves an unfinished setup to that step (sidebar Sign in → Account).
    func openOnboarding(startingAt step: OnboardingStep?) {
        guard let context else { return }
        if let existing = onboardingController {
            if let step { existing.viewModel.jump(to: step) }
            existing.show()
            return
        }
        let store = OnboardingStateStore(repo: context.settingsRepo)
        var state = store.load() ?? OnboardingState()
        if state.status != .inProgress {
            state.status = .inProgress
            if state.completedAt != nil { state.step = .setup }
        }
        // The sidebar account entry stays reachable until the project exists.
        if let step, !state.completedSteps.contains(.project) { state.step = step }
        store.save(state)
        let vm = OnboardingViewModel(
            services: OnboardingLiveServices(context: context),
            store: store,
            initial: state
        ) { [weak self] _ in
            self?.onboardingController?.window.close()
        }
        let setup = OnboardingSetupController(appSupport: context.appSupportDirectory,
            distillOverride: (try? context.settingsRepo.get("cli.distill.path")) ?? nil)
        let controller = OnboardingWindowController(viewModel: vm, setup: setup) { [weak self] in
            self?.onboardingController = nil
            // A first-run launch kept the main window hidden behind setup.
            if self?.windowController?.window.isVisible == false { self?.windowController?.show() }
        }
        onboardingController = controller
        controller.show()
    }
}
