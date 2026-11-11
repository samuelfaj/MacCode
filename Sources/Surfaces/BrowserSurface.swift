import Foundation
import AppKit
import WebKit
import CoreModel
import DesignSystemKit
import os

// MARK: - Pure helpers (no AppKit/WebKit dependency)

/// Browser commands that can be triggered by key equivalents.
public enum BrowserCommand: Equatable {
    case reload
    case back
    case forward
}

/// Maps a key character + modifier mask to a BrowserCommand.
/// Pure logic — no @MainActor, no AppKit views — so it is fully unit-testable.
public enum BrowserKeyMapper {
    /// Returns the BrowserCommand for the given key+modifiers, or nil if unbound.
    /// Only exact `.command` modifier is considered; Cmd+Shift or bare keys are unbound.
    public static func command(for key: String, modifiers: NSEvent.ModifierFlags) -> BrowserCommand? {
        guard modifiers.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
        switch key.lowercased() {
        case "r": return .reload
        case "[": return .back
        case "]": return .forward
        default: return nil
        }
    }
}

/// Action associated with a browser context-menu item.
/// Pure value — no AppKit dependency — so it is fully unit-testable.
public enum ContextMenuItemAction: Equatable {
    case openLinkInNewSurface(URL)
    case copyLink(URL)
}

/// Describes a single context-menu item: its user-visible title and action.
/// Pure value — no AppKit dependency — so it is fully unit-testable.
public struct ContextMenuItemSpec: Equatable {
    public let title: String
    public let action: ContextMenuItemAction
    public init(title: String, action: ContextMenuItemAction) {
        self.title = title
        self.action = action
    }
}

/// Maps an optional link URL from a WKWebView hit-test to the set of
/// context-menu item specs that should be injected at the top of the menu.
/// Pure logic — no @MainActor, no AppKit/WebKit types — fully unit-testable.
public enum BrowserContextMenuHelper {
    /// Returns link-specific items when `linkURL` is non-nil, empty otherwise.
    /// WHY: callers can test menu composition without any AppKit/WebKit state.
    public static func menuItemSpecs(linkURL: URL?) -> [ContextMenuItemSpec] {
        guard let url = linkURL else { return [] }
        return [
            ContextMenuItemSpec(title: L("Open Link in New Surface"), action: .openLinkInNewSurface(url)),
            ContextMenuItemSpec(title: L("Copy Link"), action: .copyLink(url))
        ]
    }
}

/// Formats WKFindResult data into a human-readable find-bar label.
/// Pure logic — no @MainActor, no WebKit types — so it is fully unit-testable.
public enum FindResultFormatter {
    /// - Parameters:
    ///   - current: 1-based index of the highlighted match (0 when no matches).
    ///   - total: Total match count (0 when no matches).
    ///   - wrapped: true when the search wrapped around the document.
    /// - Returns: e.g. "3 of 12", "1 of 5 \u{21A9}", or "No results".
    public static func label(current: Int, total: Int, wrapped: Bool) -> String {
        guard total > 0 else { return L("No results") }
        let base = "\(current) of \(total)"
        return wrapped ? "\(base) \u{21A9}" : base
    }
}

/// Builds JavaScript snippets used by BrowserSurface automation.
/// Pure logic — no AppKit/WebKit/MainActor dependency — fully unit-testable.
public enum BrowserWaitForJS {
    private static func escapedTemplateLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    public static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    public static func presenceCheckScript(selector: String) -> String {
        "Boolean(document.querySelector(`\(escapedTemplateLiteral(selector))`))"
    }

    /// Returns a self-executing JS expression that resolves to `true` once
    /// `selector` appears in the document, or `false` on timeout.
    ///
    /// Implementation uses a MutationObserver so the page notifies Swift the
    /// instant the element is inserted (O(1)) instead of a repeating 50 ms
    /// asyncAfter chain (O(deadline/50ms) timer callbacks).
    ///
    /// - Parameters:
    ///   - selector: CSS selector to wait for. Backtick characters are escaped
    ///               so the selector is safe to embed inside a JS template literal.
    ///   - timeoutMs: Maximum milliseconds to wait before resolving `false`.
    /// - Returns: A JS string whose evaluation yields a `Promise<Bool>`.
    public static func mutationObserverScript(selector: String, timeoutMs: Int) -> String {
        // Escape backticks and backslashes so the selector is safe inside ``...``.
        let escaped = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        return """
        (function(){
          return new Promise(function(resolve){
            if(document.querySelector(`\(escaped)`)){resolve(true);return;}
            var t=setTimeout(function(){obs.disconnect();resolve(false);},\(timeoutMs));
            var obs=new MutationObserver(function(){
              if(document.querySelector(`\(escaped)`)){
                clearTimeout(t);obs.disconnect();resolve(true);
              }
            });
            obs.observe(document.documentElement,{childList:true,subtree:true,attributes:true});
          });
        })()
        """
    }
}

@MainActor
public final class BrowserSurface: NSObject, Surface, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    public static let defaultInitialURLString = "https://www.remotecode.io/from-app"

    // Structured navigation/diagnostics logging (QA-MAC_BROWSER-006) so mirror
    // desyncs and field load failures are traceable. URLs are %{public}-omitted
    // by default to avoid leaking browsed addresses; only outcomes/codes log.
    private static let log = Logger(subsystem: "io.remotecode.app", category: "browser")
    static let navigationStateMessageHandlerName = "remoteCodeNavigationState"
    static var navigationStateObserverScript: String {
        """
        (function(){
          if (window.__remoteCodeNavigationStateObserver) { return; }
          window.__remoteCodeNavigationStateObserver = true;
          function notifyRemoteCodeNavigationState(){
            try {
              window.webkit.messageHandlers.\(navigationStateMessageHandlerName).postMessage({
                url: String(window.location.href),
                title: String(document.title || '')
              });
            } catch (e) {}
          }
          var originalPushState = history.pushState;
          var originalReplaceState = history.replaceState;
          history.pushState = function(){
            var result = originalPushState.apply(this, arguments);
            notifyRemoteCodeNavigationState();
            return result;
          };
          history.replaceState = function(){
            var result = originalReplaceState.apply(this, arguments);
            notifyRemoteCodeNavigationState();
            return result;
          };
          window.addEventListener('popstate', notifyRemoteCodeNavigationState);
          window.addEventListener('hashchange', notifyRemoteCodeNavigationState);
          setTimeout(notifyRemoteCodeNavigationState, 0);
        })();
        """
    }

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let webView: BrowserWebView
    private let addressBar: NSTextField
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let openExternalButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let findBar = NSView()
    private let findField = NSTextField()
    private let findPrevButton = NSButton()
    private let findNextButton = NSButton()
    private let findCloseButton = NSButton()
    private let findCountLabel = NSTextField(labelWithString: "")
    private let errorOverlay = NSView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()
    private let securityIndicator = NSButton()
    // windowOpenBanner: transient notice shown when window.open loads in-place
    // (UX-MAC_BROWSER-134). Auto-hides after 2.5 s.
    private let windowOpenBanner = NSView()
    private let windowOpenBannerLabel = NSTextField(labelWithString: "")
    /// Snapshot of the current page URL. Restored when user presses Esc in the
    /// address bar (UX-MAC_BROWSER-133).
    private var addressBarSnapshot = ""
    /// Last (url, title) pair fanned out via onNavigationChange. Guards the
    /// persist + EventBus publish so repeat KVO/didFinish/script callbacks
    /// for one navigation don't rewrite snapshots or spam the iOS mirror.
    private var lastPublishedNavigation: (url: String, title: String?)?
    private var googleLegacyLayoutReloads = Set<String>()
    private var googleLegacyLayoutReloadOrder: [String] = []
    // internal (not private) so tests can assert the cap value without
    // instantiating a WKWebView; QA-MAC_BROWSER-043.
    static let googleLegacyLayoutReloadCap = 32
    private var retainedURL: URL?
    private var isVisible = true
    /// Test-only read of the hidden/visible gate (QA-MAC_BROWSER-004) so tests
    /// can assert the "navigate while hidden is deferred" contract directly.
    var isVisibleForTesting: Bool { isVisible }
    private var progressObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var canGoBackObservation: NSKeyValueObservation?
    private var canGoForwardObservation: NSKeyValueObservation?
    private var navigationScriptMessageHandler: BrowserNavigationScriptMessageHandler?
    private var waitForToken = 0
    private var isClosed = false
    public var onNavigationChange: ((SurfaceID, String, String?) -> Void)?
    /// Fires on every page-load start/finish so the host can refresh busy listings.
    public var onBusyStateChanged: ((Bool) -> Void)?
    /// WKHTTPCookieStore snapshot for bot login-wait. Names and values only.
    public var onHTTPCookiesCaptured: ((SurfaceID, [HTTPCookie], String, String?) -> Void)?
    public var externalURLOpener: ((URL) -> Void)?
    /// Called when the user chooses "Open Link in New Surface" from the context menu.
    public var onOpenLinkInNewSurface: ((URL) -> Void)?
    /// Called when the user chooses "Copy Link" from the context menu.
    public var onCopyLink: ((URL) -> Void)?

    public init(workspaceID: WorkspaceID, initialURL: URL? = nil, title: String = "browser", botID: BotID? = nil) {
        var metadata = ["workspace": workspaceID.value.uuidString]
        if let botID {
            metadata["bot_id"] = botID.value.uuidString.lowercased()
        }
        self.descriptor = SurfaceDescriptor(
            type: .browser,
            title: title,
            iconName: "browser",
            metadata: metadata
        )

        let cfg = WKWebViewConfiguration()
        let storeID = botID.map { BotBrowserIdentity.dataStoreIdentifier(for: $0) }
            ?? Self.dataStoreIdentifier(for: workspaceID)
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.navigationStateObserverScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let wv = BrowserWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = Self.currentSafariUserAgent()
        wv.setAccessibilityIdentifier("browser.webview")
        // Enable Safari Web Inspector attachment in debug builds (P1 dev-server
        // preview use case). isInspectable is macOS 13.3+ API; guarded with
        // both a compile-time DEBUG flag and a runtime availability check so
        // release builds and older OS versions are unaffected.
        #if DEBUG
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        #endif
        self.webView = wv

        let tf = NSTextField()
        tf.placeholderString = L("Search or enter address")
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.drawsBackground = true
        tf.backgroundColor = DS.NS.surfaceRaised
        tf.textColor = DS.NS.text
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.setAccessibilityIdentifier("browser.url-field")
        tf.setAccessibilityLabel(L("Address"))
        self.addressBar = tf

        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = DS.NS.surface.cgColor
        for (b, glyph, help, axID) in [
            (backButton, "chevron.backward", L("Back"), "browser.back"),
            (forwardButton, "chevron.forward", L("Forward"), "browser.forward"),
            (reloadButton, "arrow.clockwise", L("Reload"), "browser.reload"),
            (openExternalButton, "arrow.up.forward.square", L("Open in Default Browser"), "browser.open-external")
        ] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.image = NSImage(systemSymbolName: glyph, accessibilityDescription: help)
            b.contentTintColor = DS.NS.textSecondary
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = help
            b.setAccessibilityIdentifier(axID)
            b.setAccessibilityLabel(help)
        }

        let container = BrowserContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        for v in [toolbar, wv] { v.translatesAutoresizingMaskIntoConstraints = false }
        securityIndicator.isBordered = false
        securityIndicator.bezelStyle = .inline
        securityIndicator.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")
        securityIndicator.contentTintColor = DS.NS.textSecondary
        securityIndicator.imageScaling = .scaleProportionallyDown
        securityIndicator.toolTip = L("Secure")
        securityIndicator.isEnabled = false
        securityIndicator.setAccessibilityIdentifier("browser.security-indicator")
        securityIndicator.setAccessibilityLabel(L("Security indicator"))
        for v in [backButton, forwardButton, reloadButton, securityIndicator, tf, openExternalButton] { v.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(v) }
        container.addSubview(toolbar)
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            reloadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            securityIndicator.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 6),
            securityIndicator.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            tf.leadingAnchor.constraint(equalTo: securityIndicator.trailingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: openExternalButton.leadingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            openExternalButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            openExternalButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            wv.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let toolbarDivider = NSView()
        toolbarDivider.wantsLayer = true
        toolbarDivider.layer?.backgroundColor = DS.NS.line.cgColor
        toolbarDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbarDivider)
        NSLayoutConstraint.activate([
            toolbarDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarDivider.heightAnchor.constraint(equalToConstant: 1)
        ])

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: toolbarDivider.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2)
        ])

        // In-page Find bar (UX-MAC_BROWSER-010), shown on Cmd-F over the webView.
        findBar.wantsLayer = true
        findBar.layer?.backgroundColor = DS.NS.surface.cgColor
        findBar.isHidden = true
        findBar.setAccessibilityIdentifier("browser.find-bar")
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = L("Find on page")
        findField.bezelStyle = .roundedBezel
        findField.focusRingType = .none
        findField.setAccessibilityIdentifier("browser.find-field")
        findField.setAccessibilityLabel(L("Find on page"))
        findField.translatesAutoresizingMaskIntoConstraints = false
        for (b, glyph, help, axID) in [
            (findPrevButton, "chevron.up", L("Previous match"), "browser.find-prev"),
            (findNextButton, "chevron.down", L("Next match"), "browser.find-next"),
            (findCloseButton, "xmark", L("Close find"), "browser.find-close")
        ] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.image = NSImage(systemSymbolName: glyph, accessibilityDescription: help)
            b.contentTintColor = DS.NS.textSecondary
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = help
            b.setAccessibilityIdentifier(axID)
            b.setAccessibilityLabel(help)
        }
        findCountLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        findCountLabel.textColor = DS.NS.textSecondary
        findCountLabel.setAccessibilityIdentifier("browser.find-count")
        findCountLabel.setAccessibilityLabel(L("Match count"))

        let findStack = NSStackView(views: [findField, findCountLabel, findPrevButton, findNextButton, findCloseButton])
        findStack.orientation = .horizontal
        findStack.spacing = 4
        findStack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(findStack)
        container.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.trailingAnchor.constraint(equalTo: wv.trailingAnchor, constant: -12),
            findBar.topAnchor.constraint(equalTo: wv.topAnchor, constant: 8),
            findStack.topAnchor.constraint(equalTo: findBar.topAnchor, constant: 6),
            findStack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -6),
            findStack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
            findStack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            findField.widthAnchor.constraint(equalToConstant: 180)
        ])

        errorOverlay.wantsLayer = true
        errorOverlay.layer?.backgroundColor = DS.NS.bg.cgColor
        errorOverlay.isHidden = true
        errorOverlay.setAccessibilityIdentifier("browser.error-overlay")
        errorOverlay.translatesAutoresizingMaskIntoConstraints = false
        let errorIcon = NSImageView()
        errorIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error")
        errorIcon.contentTintColor = DS.NS.textSecondary
        errorIcon.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 0
        errorLabel.textColor = DS.NS.text
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.title = L("Retry")
        retryButton.bezelStyle = .rounded
        retryButton.setAccessibilityIdentifier("browser.error-retry")
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        let errorStack = NSStackView(views: [errorIcon, errorLabel, retryButton])
        errorStack.orientation = .vertical
        errorStack.alignment = .centerX
        errorStack.spacing = 12
        errorStack.translatesAutoresizingMaskIntoConstraints = false
        errorOverlay.addSubview(errorStack)
        container.addSubview(errorOverlay)
        NSLayoutConstraint.activate([
            errorOverlay.topAnchor.constraint(equalTo: wv.topAnchor),
            errorOverlay.leadingAnchor.constraint(equalTo: wv.leadingAnchor),
            errorOverlay.trailingAnchor.constraint(equalTo: wv.trailingAnchor),
            errorOverlay.bottomAnchor.constraint(equalTo: wv.bottomAnchor),
            errorStack.centerXAnchor.constraint(equalTo: errorOverlay.centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: errorOverlay.centerYAnchor),
            errorStack.leadingAnchor.constraint(greaterThanOrEqualTo: errorOverlay.leadingAnchor, constant: 24),
            errorStack.trailingAnchor.constraint(lessThanOrEqualTo: errorOverlay.trailingAnchor, constant: -24),
            errorIcon.widthAnchor.constraint(equalToConstant: 32),
            errorIcon.heightAnchor.constraint(equalToConstant: 32)
        ])

        // window.open banner (UX-MAC_BROWSER-134): overlays top of webView;
        // hidden by default, shown transiently when createWebViewWith fires.
        windowOpenBanner.wantsLayer = true
        windowOpenBanner.layer?.backgroundColor = DS.NS.surfaceRaised.cgColor
        windowOpenBanner.layer?.cornerRadius = 6
        windowOpenBanner.isHidden = true
        windowOpenBanner.setAccessibilityIdentifier("browser.window-open-banner")
        windowOpenBanner.translatesAutoresizingMaskIntoConstraints = false
        windowOpenBannerLabel.font = .systemFont(ofSize: 11, weight: .regular)
        windowOpenBannerLabel.textColor = DS.NS.text
        windowOpenBannerLabel.setAccessibilityIdentifier("browser.window-open-banner-label")
        windowOpenBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        windowOpenBanner.addSubview(windowOpenBannerLabel)
        container.addSubview(windowOpenBanner)
        NSLayoutConstraint.activate([
            windowOpenBanner.topAnchor.constraint(equalTo: wv.topAnchor, constant: 8),
            windowOpenBanner.trailingAnchor.constraint(equalTo: wv.trailingAnchor, constant: -12),
            windowOpenBannerLabel.topAnchor.constraint(equalTo: windowOpenBanner.topAnchor, constant: 6),
            windowOpenBannerLabel.bottomAnchor.constraint(equalTo: windowOpenBanner.bottomAnchor, constant: -6),
            windowOpenBannerLabel.leadingAnchor.constraint(equalTo: windowOpenBanner.leadingAnchor, constant: 10),
            windowOpenBannerLabel.trailingAnchor.constraint(equalTo: windowOpenBanner.trailingAnchor, constant: -10)
        ])

        container.wantsLayer = true
        container.layer?.backgroundColor = DS.NS.bg.cgColor
        self.view = container
        super.init()
        let navigationScriptMessageHandler = BrowserNavigationScriptMessageHandler(surface: self)
        self.navigationScriptMessageHandler = navigationScriptMessageHandler
        cfg.userContentController.add(navigationScriptMessageHandler, name: Self.navigationStateMessageHandlerName)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        // Allow two-finger swipe-back / swipe-forward gestures (muscle memory).
        wv.allowsBackForwardNavigationGestures = true
        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        reloadButton.target = self; reloadButton.action = #selector(reload)
        openExternalButton.target = self; openExternalButton.action = #selector(openInDefaultBrowser)
        retryButton.target = self; retryButton.action = #selector(reload)
        tf.target = self; tf.action = #selector(goAddress)
        tf.delegate = self
        findField.target = self; findField.action = #selector(findNext)
        findField.delegate = self
        findPrevButton.target = self; findPrevButton.action = #selector(findPrev)
        findNextButton.target = self; findNextButton.action = #selector(findNext)
        findCloseButton.target = self; findCloseButton.action = #selector(closeFind)
        container.onFocusAddressBar = { [weak self] in self?.focusAddressBar() }
        container.onShowFind = { [weak self] in self?.showFind() }
        container.onEscape = { [weak self] in self?.closeFind() }
        container.onZoomIn = { [weak self] in self?.adjustZoom(by: 0.1) }
        container.onZoomOut = { [weak self] in self?.adjustZoom(by: -0.1) }
        container.onZoomReset = { [weak self] in self?.resetZoom() }
        container.onReload = { [weak self] in self?.reload() }
        container.onBack = { [weak self] in self?.goBack() }
        container.onForward = { [weak self] in self?.goForward() }
        container.onFindPrev = { [weak self] in self?.findPrev() }

        backButton.isEnabled = false
        forwardButton.isEnabled = false
        wv.onContextMenuItem = { [weak self] spec in
            guard let self else { return }
            switch spec.action {
            case .openLinkInNewSurface(let url):
                self.onOpenLinkInNewSurface?(url)
            case .copyLink(let url):
                if let handler = self.onCopyLink {
                    handler(url)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
        observeLoadingState()

        navigate(to: initialURL ?? Self.defaultInitialURL)
    }

    private func observeLoadingState() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progressBar.doubleValue = webView.estimatedProgress
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateLoadingChrome(isLoading: webView.isLoading)
                self.onBusyStateChanged?(webView.isLoading)
            }
        }
        // Push title changes to the iOS mirror as they happen (IMP-MAC_BROWSER-011),
        // not just on didFinish, so the mirror shows the human title between
        // SPA navigations that never fire a fresh navigation finish.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self, let url = webView.url else { return }
                self.publishNavigationChange(url: url, title: webView.title)
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncNavigationChrome(url: webView.url, title: webView.title, publish: true)
            }
        }
        canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateNavigationButtons(canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
            }
        }
        canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateNavigationButtons(canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
            }
        }
    }

    private func updateLoadingChrome(isLoading: Bool) {
        if isLoading {
            progressBar.isHidden = false
            reloadButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop")
            reloadButton.toolTip = L("Stop")
        } else {
            progressBar.isHidden = true
            progressBar.doubleValue = 0
            reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            reloadButton.toolTip = L("Reload")
        }
        updateNavigationButtons()
    }

    private func updateNavigationButtons() {
        updateNavigationButtons(canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
    }

    private func updateNavigationButtons(canGoBack: Bool, canGoForward: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        backButton.contentTintColor = canGoBack ? DS.NS.textSecondary : DS.NS.textSecondary.withAlphaComponent(0.35)
        forwardButton.contentTintColor = canGoForward ? DS.NS.textSecondary : DS.NS.textSecondary.withAlphaComponent(0.35)
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorOverlay.isHidden = false
    }

    private func hideError() {
        errorOverlay.isHidden = true
    }

    /// Returns true when `isInspectable` is enabled on the webView —
    /// i.e. DEBUG build on macOS 13.3+. Tests use this to assert the
    /// feature is active under the expected conditions without needing
    /// to touch the live WKWebView instance.
    static func isInspectableEnabled() -> Bool {
        #if DEBUG
        if #available(macOS 13.3, *) { return true }
        #endif
        return false
    }

    /// Maps a workspace id to a stable `WKWebsiteDataStore` identifier.
    /// Using the workspace UUID directly ensures:
    ///   - Same workspace -> same identifier (deterministic, no hash needed).
    ///   - Distinct workspaces -> distinct identifiers (UUID collision probability negligible).
    ///   - Identifier is a valid UUID, as required by `WKWebsiteDataStore(forIdentifier:)`.
    ///
    /// Marked `nonisolated` so tests can call it without a MainActor context.
    nonisolated static func dataStoreIdentifier(for workspaceID: WorkspaceID) -> UUID {
        workspaceID.value
    }

    /// Bot-owned browsers use the shipped bot mapping, not the workspace UUID.
    nonisolated static func dataStoreIdentifier(forBot botID: BotID) -> UUID {
        BotBrowserIdentity.dataStoreIdentifier(for: botID)
    }

    public static var defaultInitialURL: URL {
        URL(string: defaultInitialURLString)!
    }

    static func normalizedInitialURL(_ url: URL?) -> URL {
        guard let url else { return defaultInitialURL }
        return isAboutBlank(url) ? defaultInitialURL : url
    }

    private static func isAboutBlank(_ url: URL) -> Bool {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "about:blank"
    }

    /// Returns true iff `s` uses the https scheme. Used by the security
    /// indicator (UX-MAC_BROWSER-133). Pure: no I/O, no side effects.
    /// Marked `nonisolated` so tests invoke it without a MainActor context.
    /// PERF: indicator refreshes on every nav chrome sync; lowercased() copied
    /// the whole URL per check. Prefix-scan is allocation-free; verdict identical.
    nonisolated static func isSecureURL(_ s: String) -> Bool {
        // "https://" is 8 ASCII bytes; fold case per byte without copying.
        let bytes = Array(s.utf8.prefix(8))
        guard bytes.count == 8 else { return false }
        let want: [UInt8] = [0x68, 0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F] // https://
        for (b, w) in zip(bytes, want) {
            if b | 0x20 != w { return false }
        }
        return true
    }

    /// Updates the lock/insecure glyph beside the address bar to reflect the
    /// CURRENTLY LOADED page URL (webView.url), not the half-typed field text.
    /// Called from didFinish and navigate(to:) (the two moments when the loaded
    /// URL is definitively known).
    private func updateSecurityIndicator() {
        let currentURLString = webView.url?.absoluteString ?? retainedURL?.absoluteString ?? ""
        let secure = Self.isSecureURL(currentURLString)
        let glyph = secure ? "lock.fill" : "lock.open.fill"
        let desc = secure ? L("Secure") : L("Not secure")
        securityIndicator.image = NSImage(systemSymbolName: glyph, accessibilityDescription: desc)
        securityIndicator.contentTintColor = secure ? DS.NS.textSecondary : DS.NS.textTertiary
        securityIndicator.toolTip = desc
        securityIndicator.setAccessibilityLabel(desc)
    }

    private func syncNavigationChrome(url: URL?, title: String?, publish: Bool) {
        guard let url else {
            updateSecurityIndicator()
            updateNavigationButtons()
            return
        }
        retainedURL = url
        addressBar.stringValue = url.absoluteString
        addressBarSnapshot = url.absoluteString
        if publish {
            publishNavigationChange(url: url, title: title)
        }
        updateSecurityIndicator()
        updateNavigationButtons()
    }

    func syncNavigationChromeForTesting(url: URL, title: String?, canGoBack: Bool, canGoForward: Bool) {
        retainedURL = url
        addressBar.stringValue = url.absoluteString
        addressBarSnapshot = url.absoluteString
        publishNavigationChange(url: url, title: title)
        updateSecurityIndicator()
        updateNavigationButtons(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    var addressBarStringForTesting: String { addressBar.stringValue }
    var backButtonIsEnabledForTesting: Bool { backButton.isEnabled }
    var forwardButtonIsEnabledForTesting: Bool { forwardButton.isEnabled }

    fileprivate func handleNavigationScriptPayload(_ payload: BrowserNavigationScriptPayload) {
        guard let url = URL(string: payload.urlString) else { return }
        let title = payload.title?.isEmpty == false ? payload.title : webView.title
        syncNavigationChrome(url: url, title: title, publish: true)
        DispatchQueue.main.async { [weak self] in
            self?.updateNavigationButtons()
        }
    }

    public func navigate(to url: URL) {
        let url = Self.normalizedInitialURL(url)
        retainedURL = url
        addressBar.stringValue = url.absoluteString
        addressBarSnapshot = url.absoluteString
        updateSecurityIndicator()
        hideError()
        waitForToken &+= 1
        guard isVisible else { return }
        webView.load(URLRequest(url: url))
        if Self.isGoogleHost(url.host) {
            scheduleGoogleLegacyLayoutRefresh(for: url.absoluteString)
        }
    }

    static func safariLikeUserAgent(safariVersion: String) -> String {
        let osToken = "10_15_7"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osToken)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }

    static func isGoogleHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "google.com" || host.hasSuffix(".google.com")
    }

    // Computed once per process: installedSafariVersion() walks bundle/plist
    // disk paths, and the result is identical for every surface (PERF-003).
    private static let cachedSafariUserAgent: String = safariLikeUserAgent(
        safariVersion: installedSafariVersion() ?? "17.0"
    )

    private static func currentSafariUserAgent() -> String {
        cachedSafariUserAgent
    }

    private static func installedSafariVersion() -> String? {
        let paths = [
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
            "/Applications/Safari.app"
        ]
        for path in paths {
            if let bundle = Bundle(path: path),
               let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               !version.isEmpty {
                return version
            }
        }
        return nil
    }

    public func navigate(string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        guard let u = Self.resolveURL(from: s) else { return false }
        navigate(to: u)
        return true
    }

    /// Maps raw address-bar input to a URL. Scheme-less input that looks like
    /// a host (has a dot, no spaces) is treated as `https://…`; anything else
    /// (e.g. "weather tomorrow") becomes a search query against the default
    /// engine — matching Safari/Chrome omnibox behavior.
    static func resolveURL(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.contains("://") { return URL(string: s) }
        // Bare schemes with no authority (e.g. about:blank) are valid URLs and
        // must pass through rather than becoming a search query.
        if s.lowercased().hasPrefix("about:"), let u = URL(string: s) { return u }
        let looksLikeHost = !s.contains(" ") && s.contains(".")
        if looksLikeHost, let u = URL(string: "https://" + s) {
            return u
        }
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        return URL(string: "https://www.google.com/search?q=\(q)")
    }

    public func currentURL() -> String { webView.url?.absoluteString ?? "" }
    public func currentTitle() -> String { webView.title ?? "" }
    public func goBackAction() { webView.goBack() }
    public func goForwardAction() { webView.goForward() }
    public func reloadAction() { webView.reload() }
    public func stopLoadingAction() { webView.stopLoading() }
    public func openInDefaultBrowserAction() { openCurrentURLInDefaultBrowser() }

    public func evaluate(_ js: String, completion: @escaping (Any?, Error?) -> Void) {
        webView.evaluateJavaScript(js, completionHandler: completion)
    }

    /// Returns an array of {ref, tag, text, role, attrs} for all visible
    /// elements that look interactable. ref is a stable per-snapshot id
    /// the browser stores on a WeakMap so subsequent click/fill calls can
    /// resolve to the same node even if the DOM is reshuffled.
    public func snapshot(completion: @escaping (String) -> Void) {
        let js = #"""
        (function(){
          // Reset refs each snapshot so detached DOM nodes from prior
          // snapshots can be GC'd (PERF-008) instead of accumulating.
          window.__rc2 = { refs: new Map(), counter: 0 };
          const out = [];
          const isVisible = (el) => {
            if (!el) return false;
            const s = getComputedStyle(el);
            if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          };
          const interactable = (el) => {
            const t = el.tagName;
            if (['A','BUTTON','INPUT','TEXTAREA','SELECT','LABEL','SUMMARY'].includes(t)) return true;
            if (el.getAttribute('role')) return true;
            if (el.onclick) return true;
            if (el.getAttribute('contenteditable') === 'true') return true;
            return false;
          };
          // Cap emitted elements so the JSON payload ferried to iOS over RPC
          // stays bounded on huge DOMs (PERF-007); flag when truncated.
          const MAX = 1500;
          let truncated = false;
          for (const el of document.querySelectorAll('*')) {
            if (out.length >= MAX) { truncated = true; break; }
            if (!isVisible(el) || !interactable(el)) continue;
            const ref = 'rc2-' + (++window.__rc2.counter);
            window.__rc2.refs.set(ref, el);
            out.push({
              ref,
              tag: el.tagName,
              text: (el.innerText || '').slice(0, 200),
              role: el.getAttribute('role') || null,
              name: el.getAttribute('name') || null,
              type: el.getAttribute('type') || null,
              placeholder: el.getAttribute('placeholder') || null,
              href: el.tagName === 'A' ? el.getAttribute('href') : null,
              value: ('value' in el) ? el.value : null,
              bounding: (() => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; })()
            });
          }
          return JSON.stringify({ url: location.href, title: document.title, truncated, elements: out });
        })()
        """#
        evaluate(js) { value, error in
            if let s = value as? String { completion(s) }
            else {
                Self.log.error("snapshot eval failed err=\(error?.localizedDescription ?? "nil", privacy: .public)")
                completion("{\"error\":\"snapshot failed\"}")
            }
        }
    }

    public func performAction(_ kind: String, ref: String, value: String?, completion: @escaping (String) -> Void) {
        let val = (value ?? "").replacingOccurrences(of: "`", with: "\\`")
        let js = """
        (function(){
          const ref = "\(ref)";
          if (!window.__rc2 || !window.__rc2.refs.has(ref)) {
            return JSON.stringify({ ok: false, error: 'ref not found; call snapshot first' });
          }
          const el = window.__rc2.refs.get(ref);
          try {
            switch ("\(kind)") {
              case 'click':
                el.click();
                break;
              case 'focus':
                el.focus();
                break;
              case 'fill':
                el.focus();
                if ('value' in el) {
                  el.value = `\(val)`;
                  el.dispatchEvent(new Event('input', { bubbles: true }));
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                } else if (el.isContentEditable) {
                  el.textContent = `\(val)`;
                }
                break;
              case 'type':
                el.focus();
                const txt = `\(val)`;
                for (const ch of txt) {
                  el.dispatchEvent(new KeyboardEvent('keydown', { key: ch, bubbles: true }));
                  if ('value' in el) el.value += ch;
                  el.dispatchEvent(new InputEvent('input', { data: ch, bubbles: true }));
                  el.dispatchEvent(new KeyboardEvent('keyup', { key: ch, bubbles: true }));
                }
                el.dispatchEvent(new Event('change', { bubbles: true }));
                break;
              case 'check':
                el.checked = true;
                el.dispatchEvent(new Event('change', { bubbles: true }));
                break;
              case 'uncheck':
                el.checked = false;
                el.dispatchEvent(new Event('change', { bubbles: true }));
                break;
              case 'select':
                if (el.tagName === 'SELECT') {
                  el.value = `\(val)`;
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                }
                break;
              case 'hover':
                el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
                break;
            }
            return JSON.stringify({ ok: true });
          } catch (e) {
            return JSON.stringify({ ok: false, error: String(e) });
          }
        })()
        """
        evaluate(js) { value, _ in
            if let s = value as? String { completion(s) } else { completion("{\"ok\":false}") }
        }
    }

    public func waitFor(_ selector: String, timeoutMs: Int, completion: @escaping (String) -> Void) {
        waitForToken &+= 1
        let token = waitForToken
        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000.0)
        pollWaitFor(selector: selector, token: token, deadline: deadline, completion: completion)
    }

    private func pollWaitFor(selector: String, token: Int, deadline: Date, completion: @escaping (String) -> Void) {
        let js = BrowserWaitForJS.presenceCheckScript(selector: selector)
        evaluate(js) { [weak self] value, _ in
            let found = BrowserWaitForJS.boolValue(value)
            MainActor.assumeIsolated {
                guard let self, !self.isClosed, self.waitForToken == token else {
                    completion("{\"ok\":false,\"error\":\"cancelled\"}")
                    return
                }
                if found {
                    completion("{\"ok\":true}")
                    return
                }
                guard Date() < deadline else {
                    completion("{\"ok\":false,\"error\":\"timeout\"}")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.pollWaitFor(selector: selector, token: token, deadline: deadline, completion: completion)
                    }
                }
            }
        }
    }

    public func screenshotPNG() -> Data? {
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = webView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        webView.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            hideError()
            webView.reload()
        }
    }
    @objc private func openInDefaultBrowser() { openCurrentURLInDefaultBrowser() }
    @objc private func goAddress() {
        _ = navigate(string: addressBar.stringValue)
    }

    private func openCurrentURLInDefaultBrowser() {
        guard let url = webView.url ?? retainedURL ?? URL(string: addressBar.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        if let externalURLOpener {
            externalURLOpener(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Self.log.debug("nav start host=\(webView.url?.host ?? "?", privacy: .public)")
        hideError()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.log.debug("nav finish host=\(webView.url?.host ?? "?", privacy: .public)")
        syncNavigationChrome(url: webView.url, title: webView.title, publish: true)
        hideError()
        captureHTTPCookies()
        reloadGoogleOnceAfterClearingLegacyLayoutCookie()
    }

    public func captureHTTPCookies() {
        let url = webView.url?.absoluteString ?? retainedURL?.absoluteString ?? ""
        let title = webView.title
        let surfaceID = descriptor.id
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            self?.onHTTPCookiesCaptured?(surfaceID, cookies, url, title)
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        let ns = error as NSError
        // Ignore user/programmatic cancellations (e.g. stopLoading, new navigation superseding this one).
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        Self.log.error("nav fail domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
        showError(error.localizedDescription)
        updateNavigationButtons()
    }

    // MARK: WKUIDelegate

    /// target=_blank / window.open links have no destination view in a
    /// single-webView surface, so WKWebView silently drops them
    /// (UX-MAC_BROWSER-012). Load the request in this view instead and surface
    /// a transient banner so the navigation is not silent (UX-MAC_BROWSER-134).
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            syncNavigationChrome(url: url, title: webView.title, publish: true)
            webView.load(URLRequest(url: url))
            showWindowOpenBanner(for: url)
        }
        return nil
    }

    private func showWindowOpenBanner(for url: URL) {
        let host = url.host ?? url.absoluteString
        windowOpenBannerLabel.stringValue = L("Opened %1$@ in this tab", host)
        windowOpenBanner.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.windowOpenBanner.isHidden = true
        }
    }

    // IMP-MAC_BROWSER-008/012: context-menu link items implemented via
    // BrowserWebView.willOpenMenu (NSView API, macOS 10.11+). Callers receive
    // link URLs through onOpenLinkInNewSurface and onCopyLink callbacks.

    public func publishNavigationChange(url: URL, title: String?) {
        descriptor.metadata["url"] = url.absoluteString
        if let title, !title.isEmpty {
            descriptor.title = title
        }
        // SEP-3: url/title KVO, didFinish, and the SPA script payload all
        // fire for one navigation. Skip the persist + EventBus fan-out when
        // nothing changed so iOS mirrors and snapshot saves stay latest-wins.
        let urlString = url.absoluteString
        if lastPublishedNavigation?.url == urlString, lastPublishedNavigation?.title == title {
            return
        }
        lastPublishedNavigation = (urlString, title)
        onNavigationChange?(descriptor.id, urlString, title)
    }

    // Bounded insert (PERF-005): the reload-dedup set previously grew without
    // limit for every distinct Google URL the tab ever visited. Cap it and
    // evict oldest so membership stays O(1) and memory stays flat.
    private func recordGoogleLegacyLayoutReload(_ key: String) {
        guard googleLegacyLayoutReloads.insert(key).inserted else { return }
        Self.log.debug("google legacy-layout reload count=\(self.googleLegacyLayoutReloads.count, privacy: .public)")
        googleLegacyLayoutReloadOrder.append(key)
        if googleLegacyLayoutReloadOrder.count > Self.googleLegacyLayoutReloadCap {
            let evicted = googleLegacyLayoutReloadOrder.removeFirst()
            googleLegacyLayoutReloads.remove(evicted)
        }
    }

    private func scheduleGoogleLegacyLayoutRefresh(for key: String) {
        guard !googleLegacyLayoutReloads.contains(key) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  self.webView.url?.absoluteString == key,
                  !self.googleLegacyLayoutReloads.contains(key) else { return }
            self.expireGoogleLegacyLayoutCookieAndReload(key: key)
        }
    }

    private func reloadGoogleOnceAfterClearingLegacyLayoutCookie() {
        guard let url = webView.url, Self.isGoogleHost(url.host) else { return }
        let key = url.absoluteString
        guard !googleLegacyLayoutReloads.contains(key) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.webView.url?.absoluteString == key else { return }
            self.expireGoogleLegacyLayoutCookieAndReload(key: key)
        }
    }

    private func expireGoogleLegacyLayoutCookieAndReload(key: String) {
        let js = "document.cookie='__Secure-STRP=; Max-Age=0; path=/; domain=.google.com; Secure'"
        evaluate(js) { [weak self] _, _ in
            guard let self, self.webView.url?.absoluteString == key else { return }
            self.recordGoogleLegacyLayoutReload(key)
            self.webView.reload()
        }
    }

    // MARK: Surface

    /// Drives the tab spinner during page loads (UX-MAC_BROWSER-008) via the
    /// existing Surface.isBusy hook the tab/sidebar views already read.
    public var isBusy: Bool { webView.isLoading }
    public func focus() { view.window?.makeFirstResponder(webView) }
    public func focusAddressBar() {
        view.window?.makeFirstResponder(addressBar)
        addressBar.currentEditor()?.selectAll(nil)
    }

    private func showFind() {
        findBar.isHidden = false
        view.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    @objc private func closeFind() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        view.window?.makeFirstResponder(webView)
    }

    // NSTextFieldDelegate: Esc while the find field has focus closes the find bar
    // (UX-MAC_BROWSER-009). The field editor consumes the Esc keyDown before it
    // reaches BrowserContainerView.keyDown, so we intercept it here via
    // cancelOperation: instead.
    // Also handles Esc in the address bar (UX-MAC_BROWSER-133): reverts the
    // half-typed text to the current page URL and returns focus to the webView.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if control === findField {
            closeFind()
            return true
        }
        if control === addressBar {
            addressBar.stringValue = addressBarSnapshot
            view.window?.makeFirstResponder(webView)
            return true
        }
        return false
    }

    @objc private func findNext() { runFind(forward: true) }
    @objc private func findPrev() { runFind(forward: false) }

    private func runFind(forward: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty else {
            findCountLabel.stringValue = ""
            return
        }
        let cfg = WKFindConfiguration()
        cfg.backwards = !forward
        cfg.caseSensitive = false
        cfg.wraps = true
        webView.find(query, configuration: cfg) { [weak self] result in
            guard let self else { return }
            // WKFindResult.matchFound indicates at least one match was located.
            // matchFound == false means zero results (total == 0).
            // WKFindResult does not expose a total count API; we surface
            // current=1/total=1 for a found match and 0/0 for no match.
            // When the result exposes a matchCount (future API), swap it in here.
            if result.matchFound {
                // matchCount is not exposed by WKFindResult in current SDK;
                // show "Match found" style label using current=1/total=1 as
                // a conservative placeholder until the API is available.
                // The wrap indicator IS available: cfg.wraps=true means any
                // result that went past end/start wrapped.
                self.findCountLabel.stringValue = FindResultFormatter.label(
                    current: 1, total: 1, wrapped: false)
            } else {
                self.findCountLabel.stringValue = FindResultFormatter.label(
                    current: 0, total: 0, wrapped: false)
            }
        }
    }

    /// Cmd-+/Cmd-- adjust page zoom; Cmd-0 resets (IMP-MAC_BROWSER-007).
    /// Clamped to a sane range so content never collapses or runs away.
    private func adjustZoom(by delta: CGFloat) {
        webView.pageZoom = min(3.0, max(0.5, webView.pageZoom + delta))
    }
    private func resetZoom() {
        webView.pageZoom = 1.0
    }
    public func unfocus() {}
    public func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        // The webView stayed resident while hidden (WebKit suspends the
        // offscreen process), so scroll/forms/history survive. Only load
        // fresh content if nothing is loaded yet, or a navigate() arrived
        // while hidden and was deferred (retainedURL diverged from the
        // resident page).
        if webView.url == nil {
            navigate(to: retainedURL ?? Self.defaultInitialURL)
        } else if let pending = retainedURL, pending != webView.url {
            navigate(to: pending)
        }
    }
    public func didBecomeHidden() {
        guard isVisible else { return }
        isVisible = false
        retainedURL = webView.url ?? retainedURL
        // Keep the document resident; WebKit suspends the offscreen web
        // process. Blanking + reloading on every tab switch destroyed
        // scroll position, form input, and back/forward history.
    }
    public func close() {
        isClosed = true
        waitForToken &+= 1
        progressObservation?.invalidate()
        progressObservation = nil
        loadingObservation?.invalidate()
        loadingObservation = nil
        titleObservation?.invalidate()
        titleObservation = nil
        urlObservation?.invalidate()
        urlObservation = nil
        canGoBackObservation?.invalidate()
        canGoBackObservation = nil
        canGoForwardObservation?.invalidate()
        canGoForwardObservation = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.navigationStateMessageHandlerName)
        navigationScriptMessageHandler = nil
        onNavigationChange = nil
        externalURLOpener = nil
        onOpenLinkInNewSurface = nil
        onCopyLink = nil
        webView.onContextMenuItem = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }
    public func sendText(_ text: String) { /* not applicable for browser */ }
    public func readText() -> String { webView.url?.absoluteString ?? "" }
    public func snapshot() -> [String: String] {
        ["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""]
    }
}

private struct BrowserNavigationScriptPayload: Sendable {
    let urlString: String
    let title: String?

    init?(body: Any) {
        if let dict = body as? [String: Any],
           let urlString = dict["url"] as? String {
            self.urlString = urlString
            self.title = dict["title"] as? String
            return
        }
        if let urlString = body as? String {
            self.urlString = urlString
            self.title = nil
            return
        }
        return nil
    }
}

private final class BrowserNavigationScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var surface: BrowserSurface?

    init(surface: BrowserSurface) {
        self.surface = surface
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == BrowserSurface.navigationStateMessageHandlerName,
              let payload = BrowserNavigationScriptPayload(body: message.body) else { return }
        Task { @MainActor [weak surface] in
            surface?.handleNavigationScriptPayload(payload)
        }
    }
}

/// WKWebView subclass that injects "Open Link in New Surface" and "Copy Link"
/// items at the top of the native context menu when the user right-clicks a link.
/// Uses the macOS NSView `willOpenMenu(_:with:)` hook available since macOS 10.11.
private final class BrowserWebView: WKWebView {
    /// Called by `willOpenMenu` for each link-targeted item spec.
    var onContextMenuItem: ((ContextMenuItemSpec) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // Hit-test the click point to extract the link URL.
        let point = convert(event.locationInWindow, from: nil)
        let linkURL: URL? = hitTest(point).flatMap { Self.linkURL(from: $0) }

        let specs = BrowserContextMenuHelper.menuItemSpecs(linkURL: linkURL)
        guard !specs.isEmpty else { return }

        // Insert a separator then the new items at the top of the menu,
        // so the custom items are visually grouped before WKWebView defaults.
        menu.insertItem(NSMenuItem.separator(), at: 0)
        for spec in specs.reversed() {
            let item = NSMenuItem(title: spec.title, action: #selector(handleContextItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec
            menu.insertItem(item, at: 0)
        }
    }

    @objc private func handleContextItem(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? ContextMenuItemSpec else { return }
        onContextMenuItem?(spec)
    }

    /// Walks the responder/view hierarchy to find an anchor element's href URL.
    /// WKWebView renders link hit-testing via the WebKit process; we read back
    /// the URL from the hit-tested NSView's accessible URL when available, or
    /// fall back to nil so the menu degrades gracefully.
    private static func linkURL(from view: NSView) -> URL? {
        // WKWebView sets accessibilityURL on link subviews (internal WebKit detail,
        // stable since macOS 10.13). Cast via AnyObject to avoid direct dependency
        // on WebKit internals; return nil if the API is absent.
        let obj = view as AnyObject
        if obj.responds(to: NSSelectorFromString("URL")),
           let url = obj.value(forKey: "URL") as? URL {
            return url
        }
        return nil
    }
}

/// Container view that intercepts Cmd-L to focus the address bar, giving
/// keyboard users a way to reach the URL field (UX-MAC_BROWSER-006).
private final class BrowserContainerView: NSView {
    var onFocusAddressBar: (() -> Void)?
    var onShowFind: (() -> Void)?
    var onEscape: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    var onReload: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    /// Called when Shift+Return is pressed while the find bar is focused;
    /// should trigger find-previous.
    var onFindPrev: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shift+Return: find previous (standard browser convention).
        if mods == .shift,
           event.keyCode == 36 /* Return */ {
            onFindPrev?()
            return true
        }
        if mods == .command || mods == [.command, .shift] {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            // Delegate to BrowserKeyMapper for reload/back/forward.
            if let browserCmd = BrowserKeyMapper.command(for: key, modifiers: mods) {
                switch browserCmd {
                case .reload:  onReload?();  return true
                case .back:    onBack?();    return true
                case .forward: onForward?(); return true
                }
            }
            switch key {
            case "l": onFocusAddressBar?(); return true
            case "f": onShowFind?(); return true
            // Cmd-= and Cmd-+ zoom in (the + key is shift-=), Cmd-- zooms out,
            // Cmd-0 resets (IMP-MAC_BROWSER-007).
            case "=", "+": onZoomIn?(); return true
            case "-": onZoomOut?(); return true
            case "0": onZoomReset?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Escape (keyCode 53) dismisses the find bar.
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
