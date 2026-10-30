import AppKit
import SwiftUI
import DesignSystemKit

/// Hosts first-run setup in its own titled window above the main window.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    public let window: NSWindow
    let viewModel: OnboardingViewModel
    private let onFinish: () -> Void

    init(viewModel: OnboardingViewModel, onFinish: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onFinish = onFinish
        let host = NSHostingController(rootView: OnboardingView(vm: viewModel))
        let win = NSWindow(contentViewController: host)
        win.title = "Set up MacCode"
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
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        viewModel.close()
        onFinish()
    }
}

extension AppDelegate {
    /// Launch hook: show setup to new installs only. Existing installs are
    /// recorded once so they never see the window.
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

    /// Opens setup at the saved step (Help ▸ Set Up MacCode…).
    @objc func showOnboarding() {
        guard let context else { return }
        if let existing = onboardingController {
            existing.show()
            return
        }
        let store = OnboardingStateStore(repo: context.settingsRepo)
        var state = store.load() ?? OnboardingState()
        if state.status != .inProgress {
            state.status = .inProgress
            if state.completedAt != nil { state.step = .account }
            store.save(state)
        }
        let vm = OnboardingViewModel(
            services: OnboardingLiveServices(context: context),
            store: store,
            initial: state
        ) { [weak self] _ in
            self?.onboardingController?.window.close()
        }
        let controller = OnboardingWindowController(viewModel: vm) { [weak self] in
            self?.onboardingController = nil
        }
        onboardingController = controller
        controller.show()
    }
}
