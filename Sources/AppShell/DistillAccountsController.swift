import AppKit
import Combine
import Foundation
import AgentRuntime
import SocketServer
import CoreModel
import Surfaces

protocol DistillAccountManaging: Sendable {
    func statuses() -> [DistillAccountStatus]
    func loadState() async throws -> DistillAccountsState
    func add(id: String, provider: DistillAccountProvider, label: String) async throws
    func rename(id: String, label: String) async throws
    func remove(id: String) async throws
    func login(id: String, onURL: @escaping @Sendable (URL) -> Void) async throws
    func logout(id: String) async throws
    func refreshUsage(id: String) async throws -> DistillAccountQuota
    func saveRouting(_ routing: DistillAutoRouting) async throws
}

extension DistillAccounts: DistillAccountManaging {}

private enum DistillInstallResult: Sendable {
    case success(String)
    case failure(String)
}

public enum DistillInstallState: Equatable {
    case unknown, installed, installing, failed(String)
}

@MainActor
public final class DistillAccountsController: ObservableObject {
    @Published public private(set) var installState: DistillInstallState = .unknown
    @Published public private(set) var statuses: [DistillAccountStatus]
    @Published public private(set) var busyProvider: DistillAccountProvider?
    @Published public private(set) var lastError: String?
    @Published public private(set) var signInURL: URL?

    @Published public private(set) var busyAccountID: String?
    @Published public private(set) var routing = DistillAutoRouting()
    @Published public private(set) var models: [AgentModelDescriptor] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var hasLoadedState = false
    @Published public private(set) var isRefreshing = false
    private(set) var stateError: String?
    private var refreshTask: Task<Void, Never>?
    private var usageRefreshTask: Task<Bool, Never>?
    private var refreshGeneration: UInt64 = 0
    private var catalogGeneration: UInt64 = 0
    private let accounts: any DistillAccountManaging
    private let didChange: (DistillAccountProvider?, Bool) async -> Void
    private let installer: () throws -> String
    private let resolveBinary: () -> String?
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var installGeneration: UInt64 = 0

    init(
        accounts: any DistillAccountManaging,
        configuredDistillPathOverride: String? = nil,
        installer: (() throws -> String)? = nil,
        resolveBinary: (() -> String?)? = nil,
        didChange: @escaping (DistillAccountProvider?, Bool) async -> Void = { _, _ in }
    ) {
        self.accounts = accounts
        self.installer = installer ?? {
            try DistillProvisioner.ensureInstalled(override: configuredDistillPathOverride).binaryPath
        }
        self.resolveBinary = resolveBinary ?? {
            DistillProvisioner.resolveInstalledBinary(override: configuredDistillPathOverride)
        }
        self.didChange = didChange
        self.statuses = accounts.statuses()
    }

    public func refresh() {
        guard !isBusy, refreshTask == nil else { return }
        refreshGeneration &+= 1
        let token = refreshGeneration
        let operationToken = generation
        isRefreshing = true
        stateError = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await accounts.loadState()
                guard refreshGeneration == token, generation == operationToken, !Task.isCancelled else { return }
                statuses = state.accounts
                routing = state.routing
                hasLoadedState = true
            } catch {
                guard refreshGeneration == token, generation == operationToken, !Task.isCancelled else { return }
                lastError = error.localizedDescription
                stateError = error.localizedDescription
            }
            if refreshGeneration == token { refreshTask = nil; isRefreshing = false }
        }
    }

    public func refreshAndWait() async {
        refresh()
        await refreshTask?.value
    }

    public func discoverModels(using load: @escaping @MainActor () async -> [AgentModelDescriptor]) async -> [AgentModelDescriptor] {
        catalogGeneration &+= 1
        let token = catalogGeneration
        let operationToken = generation
        let loaded = await load()
        guard catalogGeneration == token, generation == operationToken, !Task.isCancelled else { return loaded }
        models = loaded
        return loaded
    }

    public func ensureDistillInstalled() {
        guard installState != .installing else { return }
        if resolveBinary() != nil {
            installState = .installed
            return
        }
        installGeneration &+= 1
        let token = installGeneration
        installState = .installing
        let installer = self.installer
        Task { [weak self] in
            let result: DistillInstallResult = await ProviderCLIProbe.runOffCooperativePool {
                do { return .success(try installer()) }
                catch { return .failure(String(describing: error)) }
            }
            guard let self, self.installGeneration == token else { return }
            switch result {
            case .success:
                installState = .installed
                await didChange(nil, true)
                refresh()
            case .failure(let error):
                installState = .failed("Could not install Distill: \(error). Run in Terminal: \(DistillProvisioner.installPlan().commandLine)")
            }
        }
    }

    public func retryDistillInstall() {
        if case .failed = installState { installState = .unknown }
        ensureDistillInstalled()
    }
    public func dismissError() { lastError = nil }

    public func login(_ provider: DistillAccountProvider) { login(accountID: provider.legacyID) }
    public func logout(_ provider: DistillAccountProvider) { logout(accountID: provider.legacyID) }

    public func add(provider: DistillAccountProvider, label: String) {
        let id = UUID().uuidString.lowercased()
        perform(accountID: id, provider: provider) { try await $0.add(id: id, provider: provider, label: label) }
    }
    public func rename(accountID: String, label: String) {
        perform(accountID: accountID) { try await $0.rename(id: accountID, label: label) }
    }
    public func remove(accountID: String) {
        perform(accountID: accountID) { try await $0.remove(id: accountID) }
    }
    public func logout(accountID: String) {
        perform(accountID: accountID) { try await $0.logout(id: accountID) }
    }
    public func refreshUsage(accountID: String) {
        perform(accountID: accountID) { _ = try await $0.refreshUsage(id: accountID) }
    }
    /// Re-reads every connected account's quota, then the account list, without
    /// taking the busy slot the Accounts settings use for sign-in and edits.
    @discardableResult
    public func refreshAllUsage() async -> Bool {
        if let usageRefreshTask { return await usageRefreshTask.value }
        guard !isBusy else { return false }
        let token = generation
        let task = Task { @MainActor in
            await self.refreshAndWait()
            guard self.hasLoadedState, self.stateError == nil, !self.isBusy, self.generation == token else { return false }
            let ids = self.statuses.filter { $0.connected && $0.provider != .openrouter }.map(\.id)
            var succeeded = true
            for id in ids {
                guard !self.isBusy, self.generation == token, !Task.isCancelled else { return false }
                do {
                    let quota = try await self.accounts.refreshUsage(id: id)
                    if quota.status != "available" { succeeded = false }
                } catch {
                    succeeded = false
                }
            }
            await self.refreshAndWait()
            return succeeded && self.stateError == nil && self.generation == token
        }
        usageRefreshTask = task
        let succeeded = await task.value
        usageRefreshTask = nil
        return succeeded
    }
    public func saveRouting(_ draft: DistillAutoRouting) {
        if let error = DistillRoutingValidation.error(draft, saved: routing, accounts: statuses, models: models) {
            lastError = error
            return
        }
        perform(accountID: nil) { try await $0.saveRouting(draft) }
    }
    /// Saves `draft` and waits for Distill. True only when the confirmed
    /// profile equals the draft; otherwise `lastError` explains.
    public func saveRoutingAndWait(_ draft: DistillAutoRouting) async -> Bool {
        saveRouting(draft)
        await operation?.value
        return lastError == nil && routing == draft
    }

    /// Turns the shared Auto profile on without the guide. Returns false when the
    /// profile has no options yet or the save fails (`lastError` explains).
    public func enableAuto() async -> Bool {
        if !hasLoadedState { await refreshAndWait() }
        guard hasLoadedState else { return false }
        if routing.enabled && !routing.options.isEmpty { return true }
        guard !routing.options.isEmpty, !isBusy else { return false }
        var draft = routing
        draft.enabled = true
        perform(accountID: nil) { try await $0.saveRouting(draft) }
        await operation?.value
        return routing.enabled
    }
    public func login(accountID: String) {
        let token = generation &+ 1
        perform(accountID: accountID) { [weak self] accounts in
            try await accounts.login(id: accountID) { [weak self] url in
                Task { @MainActor in
                    guard let self, self.generation == token, self.busyAccountID == accountID else { return }
                    self.signInURL = url
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func perform(accountID: String?, provider: DistillAccountProvider? = nil,
                         action: @escaping @MainActor (any DistillAccountManaging) async throws -> Void) {
        guard !isBusy else { return }
        if let accountID, provider == nil, !statuses.contains(where: { $0.id == accountID }) {
            lastError = "Unknown Distill account. Refresh Accounts and try again."
            return
        }
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        generation &+= 1
        let token = generation
        busyAccountID = accountID
        busyProvider = provider ?? statuses.first { $0.id == accountID }?.provider
        isBusy = true
        lastError = nil
        signInURL = nil
        publishBusyChange(provider: busyProvider, busy: true)
        operation = Task { [weak self] in
            guard let self, generation == token, !Task.isCancelled else { return }
            do {
                try await action(accounts)
                guard generation == token, !Task.isCancelled else { return }
                let state = try await accounts.loadState()
                guard generation == token, !Task.isCancelled else { return }
                statuses = state.accounts
                routing = state.routing
                hasLoadedState = true
                stateError = nil
                await didChange(busyProvider, true)
                guard generation == token, !Task.isCancelled else { return }
                publishBusyChange(provider: busyProvider, busy: true)
            } catch {
                guard generation == token else { return }
                if !(error is CancellationError), (error as? DistillAccountError) != .cancelled {
                    lastError = error.localizedDescription
                }
            }
            finish(token: token)
        }
    }

    public func cancel() {
        guard operation != nil else { return }
        let provider = busyProvider
        generation &+= 1
        operation?.cancel()
        operation = nil
        busyProvider = nil
        busyAccountID = nil
        isBusy = false
        signInURL = nil
        publishBusyChange(provider: provider, busy: false)
    }

    private func finish(token: UInt64) {
        guard generation == token else { return }
        let provider = busyProvider
        operation = nil
        busyProvider = nil
        busyAccountID = nil
        isBusy = false
        signInURL = nil
        publishBusyChange(provider: provider, busy: false)
    }

    private func publishBusyChange(provider: DistillAccountProvider?, busy: Bool) {
        EventBus.shared.publish(kind: .agentProviderUpdated, payload: .object([
            "provider": .string(provider?.rawValue ?? "distill"),
            "distill_accounts_busy": .bool(busy),
            "busy_account_id": busyAccountID.map { .string($0) } ?? .null
        ]))
    }
}
