import CoreModel
import Foundation
import AppKit
import UserNotifications
import os
import Persistence

// MARK: - NotificationCenterClient DI seam (QA :96)

/// Abstracts the `UNUserNotificationCenter` calls that `SystemNotifier` makes
/// so unit tests can intercept posting without a real app bundle (the
/// `canUseNotificationCenter` guard makes UNCenter a no-op under `swift test`).
/// Production code uses `LiveNotificationCenterClient` which delegates to
/// `UNUserNotificationCenter.current()`.
public protocol NotificationCenterClient: Sendable {
    /// Schedules a notification request.
    func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)?)
    /// Registers the delegate for presentation callbacks.
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?)
    /// Registers notification categories.
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    /// Requests authorization; calls back with (granted, error).
    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping (Bool, Error?) -> Void)
    /// Returns the current notification settings.
    func notificationSettings() async -> UNNotificationSettings
}

/// Live implementation that delegates to `UNUserNotificationCenter.current()`.
public struct LiveNotificationCenterClient: NotificationCenterClient {
    public init() {}
    public func add(_ request: UNNotificationRequest, withCompletionHandler handler: ((Error?) -> Void)?) {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: handler)
    }
    public func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        UNUserNotificationCenter.current().delegate = delegate
    }
    public func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
    public func requestAuthorization(options: UNAuthorizationOptions,
                                     completionHandler: @escaping (Bool, Error?) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: options,
                                                                completionHandler: completionHandler)
    }
    public func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }
}

/// Thin wrapper around UNUserNotificationCenter. Requests authorization
/// once; subsequent posts are best-effort. If authorization is denied
/// notifications still get persisted via the NotificationRepository so
/// the in-app feed is unaffected.
public final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = SystemNotifier()

    // `authorized` is written from UNUserNotificationCenter's authorization
    // callback (arbitrary queue) and read from `post(...)` on arbitrary
    // callers. Guard both with a lock so the access is a proper barrier
    // (previously a plain Bool, which TSan flagged and could drop the first
    // post after launch).
    private let authLock = NSLock()
    private var _authorized = false
    private let postedIdentifiersLock = NSLock()
    private var postedIdentifiers = Set<String>()
    private let outcomeQueue = DispatchQueue(label: "io.remotecode.notifications.outcomes")
    private var pendingOutcomes: [String: [RemoteCodeNotificationContent]] = [:]
    private var pendingRemoteOutcomes: [String: [RemoteCodeNotificationContent]] = [:]
    private var remoteOutcomeCallbacks: [String: (RemoteCodeNotificationContent) -> Void] = [:]
    private var outcomeWorkItems: [String: DispatchWorkItem] = [:]
    private var seenOutcomeIdentifiers = Set<String>()
    private let scheduleOutcome: (TimeInterval, @escaping () -> Void) -> Void
    private let canUseNotificationCenterForInstance: Bool
    private var authorized: Bool {
        get { authLock.lock(); defer { authLock.unlock() }; return _authorized }
        set { authLock.lock(); _authorized = newValue; authLock.unlock() }
    }

    /// Called on the main thread whenever the user taps a delivered
    /// notification. Set by AppDelegate at launch to wire deep-linking.
    public var onNotificationResponse: ((UNNotificationResponse) -> Void)?

    /// Called when a `post(_:)` is silently dropped because the user has
    /// denied OS-level notification permission. Use this seam to surface
    /// an in-app fallback (e.g. badge, feed entry, alert) so a finished
    /// agent run is not invisible on a denied system (UX-MAC_APPSHELL-P2).
    public var onDeniedPost: ((RemoteCodeNotificationContent) -> Void)?

    /// Posted on the main thread the first time a `post(_:)` call is dropped
    /// because the user has denied OS-level notification permission. Observers
    /// (e.g. a status-bar notice or settings prompt) can react to this name.
    /// Posted at most once per app session; the gating flag lives in AppDelegate
    /// so multiple denied posts never spam the user (UX-MAC_APPSHELL-P2).
    public static let rc2NotificationsDeniedPost = Notification.Name("rc2NotificationsDeniedPost")

    /// Injected notification center. Default = LiveNotificationCenterClient (real UNCenter).
    /// Tests inject a fake so posting is unit-testable without a bundled .app (QA :96).
    let notificationCenterClient: any NotificationCenterClient

    private override init() {
        self.notificationCenterClient = LiveNotificationCenterClient()
        self.canUseNotificationCenterForInstance = Self.canUseNotificationCenter
        self.scheduleOutcome = { delay, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: action)
        }
        super.init()
    }

    /// Designated init for test injection. Not exposed via `shared`.
    init(
        notificationCenterClient: any NotificationCenterClient,
        allowsNotificationCenterForTesting: Bool = false,
        scheduleOutcome: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.notificationCenterClient = notificationCenterClient
        self.canUseNotificationCenterForInstance = Self.canUseNotificationCenter || allowsNotificationCenterForTesting
        self.scheduleOutcome = scheduleOutcome
        super.init()
    }

    /// `.badge` is what lets the Dock icon show the needs-you count: without
    /// it macOS keeps "Badge application icon" off and hides the badge.
    static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]
    private static let log = Logger(subsystem: "io.remotecode.app", category: "notifications")

    private static var canUseNotificationCenter: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Sets the authorization state for tests. Not callable in production because
    /// `authorized` is always set via the `requestAuthorization` callback.
    /// Internal so `@testable import AppShell` can reach it without reflection.
    func setAuthorizedForTesting(_ value: Bool) {
        authorized = value
    }

    public func bootstrap() {
        // UNUserNotificationCenter requires the process to be a real
        // bundled .app. Running from `swift run` produces a binary
        // without an app bundle and would crash on .current().
        guard Self.canUseNotificationCenter else { return }
        notificationCenterClient.setDelegate(self)
        notificationCenterClient.setNotificationCategories(Self.notificationCategories)
        notificationCenterClient.requestAuthorization(options: Self.authorizationOptions) { [notificationCenterClient] granted, _ in
            self.authorized = granted
            // The Dock badge only shows while macOS allows badges for the app.
            Task {
                let badge = await notificationCenterClient.notificationSettings().badgeSetting
                Self.log.info("notifications.authorized granted=\(granted, privacy: .public) badge=\(badge.rawValue, privacy: .public)")
            }
        }
    }

    /// Thread updates and Titio notices. Titio's category has only Open
    /// (approve/decline from the lock screen is out of scope, hub spec §14).
    static var notificationCategories: Set<UNNotificationCategory> {
        let open = UNNotificationAction(
            identifier: RemoteCodeNotificationContent.openActionIdentifier,
            title: "Open",
            options: [.foreground]
        )
        return [
            UNNotificationCategory(
                identifier: RemoteCodeNotificationContent.threadUpdateCategoryIdentifier,
                actions: [open],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: RemoteCodeNotificationContent.titioQuestionCategoryIdentifier,
                actions: [open], intentIdentifiers: [], options: []
            ),
            UNNotificationCategory(
                identifier: RemoteCodeNotificationContent.titioNoticeCategoryIdentifier,
                actions: [open],
                intentIdentifiers: [],
                options: []
            ),
        ]
    }

    public func post(title: String, body: String?, category: String?) {
        post(Self.legacyContent(title: title, body: body, category: category))
    }

    static func legacyContent(
        title: String,
        body: String?,
        category: String?
    ) -> RemoteCodeNotificationContent {
        var userInfo: [String: String] = [:]
        if let category, !category.isEmpty {
            userInfo["category"] = category
        }
        return RemoteCodeNotificationContent(
            identifier: UUID().uuidString,
            title: title,
            body: body ?? "",
            categoryIdentifier: category ?? "",
            threadIdentifier: "",
            userInfo: userInfo,
            soundEnabled: true
        )
    }

    public func post(_ content: RemoteCodeNotificationContent, settings: AppSettings = AppSettings()) {
        post(content.withSound(settings.notificationSoundEnabled))
    }

    public func postOutcomeGrouped(
        _ content: RemoteCodeNotificationContent,
        workspaceId: String?,
        settings: AppSettings,
        remoteDelivery: ((RemoteCodeNotificationContent) -> Void)? = nil
    ) {
        let key = workspaceId ?? "__no_workspace__"
        outcomeQueue.async { [weak self] in
            guard let self else { return }
            guard self.seenOutcomeIdentifiers.insert(content.identifier).inserted else { return }
            let outcome = content.withSound(settings.notificationSoundEnabled)
            self.pendingOutcomes[key, default: []].append(outcome)
            if let remoteDelivery {
                self.pendingRemoteOutcomes[key, default: []].append(outcome)
                self.remoteOutcomeCallbacks[key] = remoteDelivery
            }
            guard self.outcomeWorkItems[key] == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let contents = self.pendingOutcomes.removeValue(forKey: key) ?? []
                let remoteContents = self.pendingRemoteOutcomes.removeValue(forKey: key) ?? []
                let remoteDelivery = self.remoteOutcomeCallbacks.removeValue(forKey: key)
                self.outcomeWorkItems.removeValue(forKey: key)
                if let grouped = RemoteCodeNotificationContent.groupedOutcomes(contents) {
                    self.post(grouped)
                }
                if let groupedRemote = RemoteCodeNotificationContent.groupedOutcomes(remoteContents) {
                    remoteDelivery?(groupedRemote)
                }
            }
            self.outcomeWorkItems[key] = item
            self.scheduleOutcome(5) { [weak self] in
                self?.outcomeQueue.async { item.perform() }
            }
        }
    }

    private func post(_ content: RemoteCodeNotificationContent) {
        guard authorized, canUseNotificationCenterForInstance else {
            // Notify the caller so an in-app fallback can surface the result
            // when OS-level delivery is blocked (permission denied).
            DispatchQueue.main.async { [weak self] in
                self?.onDeniedPost?(content)
            }
            return
        }
        postedIdentifiersLock.lock()
        let inserted = postedIdentifiers.insert(content.identifier).inserted
        postedIdentifiersLock.unlock()
        guard inserted else { return }
        notificationCenterClient.add(content.makeRequest()) { [weak self] error in
            guard let self, let error else { return }
            self.postedIdentifiersLock.lock()
            self.postedIdentifiers.remove(content.identifier)
            self.postedIdentifiersLock.unlock()
            Self.log.error("notifications.schedule_failed id=\(content.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Current OS authorization status, used by Settings to decide whether to
    /// show a "Test notification" button or a "permission denied" prompt.
    /// Returns `.notDetermined` for non-bundled (`swift run`) processes where
    /// UNUserNotificationCenter is unavailable.
    public func authorizationStatus() async -> UNAuthorizationStatus {
        guard Self.canUseNotificationCenter else { return .notDetermined }
        let status = await notificationCenterClient.notificationSettings().authorizationStatus
        authorized = status == .authorized || status == .provisional
        return status
    }

    /// Best-effort test notification for the Settings "Test notification"
    /// button. Re-requests authorization when still undetermined so the first
    /// press also triggers the OS prompt.
    public func postTestNotification(settings: AppSettings = AppSettings()) {
        guard Self.canUseNotificationCenter else { return }
        let deliver = { [self] in
            post(RemoteCodeNotificationContent(
                identifier: UUID().uuidString, title: "MacCode",
                body: "Test notification — your alerts appear here.",
                categoryIdentifier: RemoteCodeNotificationContent.threadUpdateCategoryIdentifier,
                threadIdentifier: "notification.test", userInfo: [:],
                soundEnabled: settings.notificationSoundEnabled
            ))
        }
        if authorized {
            deliver()
        } else {
            notificationCenterClient.requestAuthorization(options: Self.authorizationOptions) { granted, _ in
                self.authorized = granted
                if granted { deliver() }
            }
        }
    }

    /// Deep-links to System Settings > Notifications so a user who denied the
    /// permission can re-enable it without hunting through panes.
    @MainActor
    public func openSystemNotificationSettings() {
        let fallback = "x-apple.systempreferences:com.apple.preference.notifications"
        let url = Bundle.main.bundleIdentifier
            .map { "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\($0)" }
            .flatMap(URL.init(string:)) ?? URL(string: fallback)!
        NSWorkspace.shared.open(url)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptions(
            appIsForeground: true,
            isTestNotification: notification.request.content.threadIdentifier == "notification.test"
        ))
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.onNotificationResponse?(response)
        }
        completionHandler()
    }

    public static func presentationOptions(appIsForeground: Bool, isTestNotification: Bool = false) -> UNNotificationPresentationOptions {
        appIsForeground && !isTestNotification ? [] : [.banner, .list, .sound]
    }
}
