import MezclaCore
import SwiftUI

/// One browser tab under its browser's row: favicon (click to mute), title, slider and level.
/// Its slider lines up with the app sliders above it.
struct TabVolumeRow: View {
    let tab: BrowserTab
    let nameWidth: CGFloat
    let isLast: Bool

    @Environment(MixerViewModel.self) private var model
    @State private var isHovering = false

    private static let faviconSize: CGFloat = 16
    private static let faviconSpacing: CGFloat = 6

    var body: some View {
        let volume = tab.volume

        HStack(spacing: PanelStyle.columnSpacing) {
            HierarchyGuide(isLast: isLast)
                .frame(width: PanelStyle.iconSize)

            HStack(spacing: Self.faviconSpacing) {
                FaviconMuteButton(
                    favicon: model.icons.favicon(tab.favicon),
                    title: tab.title,
                    isMuted: volume.isMuted,
                    showsAffordance: isHovering
                ) {
                    model.toggleTabMute(tab.id)
                }
                Text(tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: nameWidth - Self.faviconSize - Self.faviconSpacing, alignment: .leading)
                    .help(tab.url?.host().map { "\(tab.title)\n\($0)" } ?? tab.title)
            }

            Slider(
                value: Binding(get: { volume.level }, set: { model.setTabLevel($0, for: tab.id) }),
                in: 0...max(model.maximumLevel, volume.level)
            )
            .controlSize(.small)
            .accessibilityLabel(Text("\(tab.title) volume"))

            LevelIndicator(volume: volume, issue: nil)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, PanelStyle.rowInset)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PanelStyle.highlight(isHovering)))
        .opacity(volume.isMuted ? 0.55 : tab.isAudible ? 1 : 0.8)
        .onHover { isHovering = $0 }
        .animation(PanelStyle.hoverAnimation, value: isHovering)
        .animation(PanelStyle.hoverAnimation, value: volume.isMuted)
        .contextMenu {
            Button(volume.isMuted ? "Unmute Tab" : "Mute Tab") { model.toggleTabMute(tab.id) }
            Button("Reset to 100%") { model.resetTab(tab.id) }
                .disabled(volume.isNeutral)
        }
    }
}

/// A thin line that ties tab rows to their browser: │ for middle rows, ╰ for the last one.
private struct HierarchyGuide: View {
    let isLast: Bool

    var body: some View {
        GeometryReader { proxy in
            let x = (proxy.size.width / 2).rounded() + 0.5
            Path { path in
                path.move(to: CGPoint(x: x, y: -2))
                if isLast {
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height / 2 - 4))
                    path.addQuadCurve(to: CGPoint(x: x + 5, y: proxy.size.height / 2), control: CGPoint(x: x, y: proxy.size.height / 2))
                } else {
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height + 2))
                }
            }
            .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct FaviconMuteButton: View {
    let favicon: NSImage?
    let title: String
    let isMuted: Bool
    let showsAffordance: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let favicon {
                    Image(nsImage: favicon)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .overlay(alignment: .bottomTrailing) {
                if isMuted || showsAffordance {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 10, height: 10)
                        .background(Circle().fill(isMuted ? Color.red : Color.black.opacity(0.7)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .offset(x: 4, y: 3)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute tab" : "Mute tab")
        .accessibilityLabel(isMuted ? Text("Unmute \(title)") : Text("Mute \(title)"))
    }
}

/// Shown under a playing browser without the extension: one click away from per-tab control.
struct TabControlSuggestion: View {
    @Environment(MixerViewModel.self) private var model
    let browser: AudioApp

    var body: some View {
        HStack(spacing: PanelStyle.columnSpacing) {
            HierarchyGuide(isLast: true)
                .frame(width: PanelStyle.iconSize)

            Button { model.showBrowserSetup(for: browser) } label: {
                HoverLabel {
                    Label("Control each tab separately…", systemImage: "puzzlepiece.extension")
                        .labelStyle(CompactLabelStyle())
                        .font(.system(size: 11.5))
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, -PanelStyle.rowInset) // Align the text with the app names above.

            Spacer(minLength: 0)

            Button(action: model.hideTabControlSuggestion) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don’t suggest again")
        }
        .padding(.horizontal, PanelStyle.rowInset)
        .padding(.vertical, 1)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}
