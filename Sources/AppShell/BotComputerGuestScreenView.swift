import CoreModel
import DesignSystemKit
import SwiftUI
import WebKit

/// Interactive noVNC guest screen. The URL must already be 127.0.0.1.
struct BotComputerGuestScreenView: NSViewRepresentable {
    let url: URL
    /// Copies Mac files dropped or pasted on the screen into the guest; nil disables it.
    var onImportFiles: (([URL]) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BotComputerGuestWebView {
        let configuration = WKWebViewConfiguration()
        // The only audio in vnc.html is the RFB bell. The URL already asks
        // noVNC not to play it (bell=off); this blocks any autoplay outright
        // so the guest can never make the Mac beep.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.embedStyleScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let view = BotComputerGuestWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.onImportFiles = onImportFiles
        return view
    }

    /// The app owns the viewer chrome (Rebuild / Stop), so noVNC's floating
    /// control-bar handle reads as a broken leftover. Hide it and blend the
    /// page background into the surrounding pane (DS.Palette.surface).
    private static let embedStyleScript = """
    (function() {
      const style = document.createElement('style');
      style.textContent = `
        html, body { background: #171D24 !important; }
        #noVNC_control_bar_anchor { display: none !important; }
      `;
      document.documentElement.appendChild(style);
    })();
    """

    func updateNSView(_ view: BotComputerGuestWebView, context: Context) {
        view.onImportFiles = onImportFiles
        guard (try? BotComputerGuestSpec.validateScreenURL(url)) != nil else { return }
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript(
                """
                (function() {
                  const canvas = document.querySelector('canvas');
                  if (canvas) {
                    canvas.tabIndex = 0;
                    canvas.focus();
                  }
                })();
                """,
                completionHandler: nil
            )
        }
    }
}

/// Clicks on the guest must steal key focus from the Desk composer.
/// Cmd+V pastes Mac text into the guest; Mac files pasted or dropped are copied in.
final class BotComputerGuestWebView: WKWebView {
    var onImportFiles: (([URL]) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
              let responder = window?.firstResponder as? NSView, responder === self || responder.isDescendant(of: self)
        else { return super.performKeyEquivalent(with: event) }
        let pasteboard = NSPasteboard.general
        if let files = Self.fileURLs(pasteboard), !files.isEmpty, let onImportFiles {
            onImportFiles(files)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            evaluateJavaScript(Self.pasteScript(text), completionHandler: nil)
        }
        return true
    }

    /// Sets the guest CLIPBOARD through noVNC's clipboard field, then presses Ctrl+V in the guest.
    static func pasteScript(_ text: String) -> String {
        let literal = (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? "\"\""
        return """
        (function() {
          const field = document.getElementById('noVNC_clipboard_text');
          const canvas = document.querySelector('canvas');
          if (!field || !canvas) return;
          field.value = \(literal);
          field.dispatchEvent(new Event('change'));
          setTimeout(function() {
            const key = function(type, key, code, ctrl) {
              canvas.dispatchEvent(new KeyboardEvent(type, { key: key, code: code, ctrlKey: ctrl, bubbles: true, cancelable: true }));
            };
            key('keydown', 'Control', 'ControlLeft', true);
            key('keydown', 'v', 'KeyV', true);
            key('keyup', 'v', 'KeyV', true);
            key('keyup', 'Control', 'ControlLeft', false);
          }, 150);
        })();
        """
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard onImportFiles != nil, Self.fileURLs(sender.draggingPasteboard)?.isEmpty == false else {
            return super.draggingEntered(sender)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard onImportFiles != nil, Self.fileURLs(sender.draggingPasteboard)?.isEmpty == false else {
            return super.draggingUpdated(sender)
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let onImportFiles, let files = Self.fileURLs(sender.draggingPasteboard), !files.isEmpty else {
            return super.performDragOperation(sender)
        }
        onImportFiles(files)
        return true
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        evaluateJavaScript(
            "var c = document.querySelector('canvas'); if (c) { c.tabIndex = 0; c.focus(); }",
            completionHandler: nil
        )
        return accepted
    }
}

enum BotComputerGuestLaunchState: Equatable {
    case idle
    case starting
    case failed(String)

    var isStarting: Bool {
        self == .starting
    }

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

/// Shared Desk/Studio chrome: live screen plus Start or Rebuild / Stop.
struct BotComputerGuestCanvas: View {
    let url: URL?
    let running: Bool
    let rebuilding: Bool
    let launchState: BotComputerGuestLaunchState
    let startIdentifier: String
    let rebuildIdentifier: String
    let stopIdentifier: String
    let screenIdentifier: String
    let onStart: () -> Void
    let onRebuild: () -> Void
    let onStop: () -> Void
    var onOpenInNewWindow: (() -> Void)? = nil
    var openInNewWindowIdentifier: String = "bots.desk.desktop.openInNewWindow"
    /// Copies Mac files into the guest's ~/Downloads and returns the guest paths.
    var onImportFiles: (([URL]) throws -> [String])? = nil
    @State private var importMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text(L("Linux desktop"))
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                if running {
                    Button(action: onRebuild) {
                        HStack(spacing: DS.Space.xs) {
                            if rebuilding {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(rebuilding ? L("Rebuilding…") : L("Rebuild"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(rebuilding)
                    .accessibilityLabel(rebuilding ? L("Rebuilding Linux desktop") : L("Rebuild Linux desktop"))
                    .accessibilityIdentifier(rebuildIdentifier)
                    Button(L("Stop"), action: onStop)
                        .buttonStyle(.bordered)
                        .disabled(rebuilding)
                        .accessibilityIdentifier(stopIdentifier)
                } else {
                    Button(action: onStart) {
                        HStack(spacing: DS.Space.xs) {
                            if launchState.isStarting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(startButtonTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(launchState.isStarting)
                    .accessibilityLabel(startButtonAccessibilityLabel)
                    .accessibilityHint(startButtonAccessibilityHint)
                    .accessibilityIdentifier(startIdentifier)
                }
                if let onOpenInNewWindow {
                    DSIconButton("rectangle.on.rectangle", help: L("Open in New Window")) {
                        onOpenInNewWindow()
                    }
                    .accessibilityIdentifier(openInNewWindowIdentifier)
                }
            }
            if let url {
                // Match the guest framebuffer (start.sh Xvfb size, pinned against
                // BotComputerGuestSpec) so the viewer hugs the actual screen.
                BotComputerGuestScreenView(url: url, onImportFiles: onImportFiles.map { importFiles in
                    { urls in
                        do {
                            let paths = try importFiles(urls)
                            importMessage = paths.count == 1
                                ? L("Copied to %1$@", paths[0])
                                : L("Copied %1$@ items to ~/Downloads", paths.count)
                        } catch {
                            importMessage = L("Could not copy to the Linux desktop: %1$@", error.localizedDescription)
                        }
                    }
                })
                    .aspectRatio(
                        CGFloat(BotComputerGuestSpec.screenWidth) / CGFloat(BotComputerGuestSpec.screenHeight),
                        contentMode: .fit
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(screenIdentifier)
                if let importMessage {
                    Text(importMessage)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("\(screenIdentifier).importMessage")
                } else if onImportFiles != nil {
                    Text(L("⌘V pastes text. Drop or paste Mac files to copy them to ~/Downloads."))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                }
            } else {
                emptyScreen
            }
        }
    }

    @ViewBuilder
    private var emptyScreen: some View {
        VStack(spacing: DS.Space.sm) {
            switch launchState {
            case .idle:
                Text(L("Start the Linux desktop to use this machine."))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text(L("Starting Linux desktop…"))
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Text(L("First launch can take a few minutes while Docker prepares the desktop."))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DS.Palette.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(
                        BotComputerDockerRecovery.matching(message)?.accessibilityLabel ?? message
                    )
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(screenIdentifier)
    }

    private var startButtonTitle: String {
        if launchState.isStarting { return L("Starting…") }
        return launchState.failureMessage == nil ? L("Start") : L("Try Again")
    }

    private var startButtonAccessibilityLabel: String {
        if launchState.isStarting { return L("Starting Linux desktop") }
        if case .failed(let message) = launchState,
           let recovery = BotComputerDockerRecovery.matching(message) {
            return recovery.accessibilityAction
        }
        return startButtonTitle
    }

    private var startButtonAccessibilityHint: String {
        if case .failed(let message) = launchState {
            return BotComputerDockerRecovery.matching(message)?.accessibilityLabel ?? message
        }
        return L("Starts the Linux desktop.")
    }
}
