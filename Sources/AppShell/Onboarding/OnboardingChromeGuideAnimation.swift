import CoreModel
import SwiftUI
import DesignSystemKit

/// A looping, video-like walkthrough of the one-time Chrome extension setup:
/// open chrome://extensions, turn on Developer mode, choose Load unpacked,
/// pick the folder, see MacCode Computer Use enabled.
struct OnboardingChromeGuideAnimation: View {
    enum Scene: Int, CaseIterable {
        case openExtensions, developerMode, loadUnpacked, chooseFolder, enabled

        var caption: String {
            switch self {
            case .openExtensions: return L("Open chrome://extensions in the profile you want to use.")
            case .developerMode: return L("Turn on Developer mode at the top right.")
            case .loadUnpacked: return L("Click Load unpacked.")
            case .chooseFolder: return L("Select the extension folder MacCode showed in Finder.")
            case .enabled: return L("MacCode Computer Use is on. Return here and check the connection.")
            }
        }

        /// Seconds each scene stays on screen.
        var duration: Double { self == .enabled ? 3.2 : 2.4 }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene: Scene = .openExtensions

    var body: some View {
        OnboardingPanel {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                browser
                    .frame(height: 230)
                progress
                Text(scene.caption)
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(scene)
                    .transition(.opacity)
                Text(L("Selecting an automated tab gives control back to you. You can disable the extension later in Chrome."))
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Chrome extension setup: %1$@", Scene.allCases.map(\.caption).joined(separator: " ")))
        .task(id: reduceMotion) { await play() }
    }

    /// Loops the scenes while visible; Reduce Motion holds the final frame.
    private func play() async {
        guard !reduceMotion else { scene = .enabled; return }
        while !Task.isCancelled {
            for next in Scene.allCases {
                withAnimation(DS.Motion.standard) { scene = next }
                try? await Task.sleep(for: .seconds(next.duration))
                if Task.isCancelled { return }
            }
        }
    }

    private var progress: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(Scene.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= scene.rawValue ? DS.Palette.accent : DS.Palette.lineStrong)
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 8, height: 8) }
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 9))
                    Text("chrome://extensions").font(.system(size: 10, design: .monospaced))
                }
                .foregroundColor(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.md).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(scene == .openExtensions ? DS.Palette.accent : .clear, lineWidth: 1.5))
            }
            .padding(DS.Space.md)
            .background(DS.Palette.surfaceOverlay)
            ZStack {
                extensionsPage
                if scene == .chooseFolder { folderSheet.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(DS.Palette.line))
        .accessibilityHidden(true)
    }

    private var developerModeOn: Bool { scene.rawValue >= Scene.developerMode.rawValue }

    private var extensionsPage: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                Text(L("Extensions")).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Spacer()
                Text(L("Developer mode")).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                Capsule()
                    .fill(developerModeOn ? DS.Palette.accent : DS.Palette.lineStrong)
                    .frame(width: 28, height: 16)
                    .overlay(Circle().fill(Color.white).frame(width: 12, height: 12)
                        .offset(x: developerModeOn ? 6 : -6))
                    .overlay(highlight(scene == .developerMode, radius: 10))
            }
            if developerModeOn {
                HStack(spacing: DS.Space.sm) {
                    chromeButton(L("Load unpacked"), highlighted: scene == .loadUnpacked)
                    chromeButton(L("Pack extension"), highlighted: false)
                    chromeButton(L("Update"), highlighted: false)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if scene == .enabled {
                HStack(spacing: DS.Space.md) {
                    RoundedRectangle(cornerRadius: 6).fill(DS.Palette.accent.opacity(0.2)).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "cursorarrow.motionlines").font(.system(size: 13)).foregroundColor(DS.Palette.accent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacCode Computer Use").font(DS.Font.captionStrong).foregroundColor(DS.Palette.text)
                        Text(L("Enabled")).font(DS.Font.caption).foregroundColor(DS.Palette.success)
                    }
                    Spacer()
                    Capsule().fill(DS.Palette.accent).frame(width: 28, height: 16)
                        .overlay(Circle().fill(Color.white).frame(width: 12, height: 12).offset(x: 6))
                }
                .padding(DS.Space.md)
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Palette.success.opacity(0.5)))
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
    }

    private var folderSheet: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(L("Select the extension folder")).font(DS.Font.captionStrong).foregroundColor(DS.Palette.text)
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "folder.fill").foregroundColor(DS.Palette.accent)
                Text("ChromeComputerUse").font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Palette.text)
                Spacer()
            }
            .padding(DS.Space.sm)
            .background(DS.Palette.selection)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            HStack {
                Spacer()
                chromeButton(L("Select"), highlighted: true)
            }
        }
        .padding(DS.Space.lg)
        .frame(width: 260)
        .background(DS.Palette.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private func chromeButton(_ title: String, highlighted: Bool) -> some View {
        Text(title)
            .font(DS.Font.caption)
            .foregroundColor(highlighted ? DS.Palette.text : DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xs)
            .background(highlighted ? DS.Palette.accent.opacity(0.25) : DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(highlight(highlighted, radius: 5))
    }

    private func highlight(_ on: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(DS.Palette.accent, lineWidth: on ? 2 : 0)
            .padding(-3)
            .opacity(on ? 1 : 0)
    }
}
