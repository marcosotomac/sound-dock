import MezclaCore
import SwiftUI

/// Icon (click to mute), name, slider and level for one app.
struct AppVolumeRow: View {
    let app: AudioApp
    let volume: AppVolume
    let nameWidth: CGFloat

    @Environment(MixerViewModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        let name = DisplayName.of(app)

        HStack(spacing: PanelStyle.columnSpacing) {
            MuteButton(
                icon: model.icons.icon(forPath: DisplayName.iconPath(of: app)),
                appName: name,
                isMuted: volume.isMuted,
                showsAffordance: isHovering
            ) {
                model.toggleMute(app.id)
            }

            HStack(spacing: 4) {
                Text(name)
                    .font(Font(PanelStyle.nameFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(name)
                if app.isUsingMicrophone {
                    MicrophoneBadge()
                }
                RouteBadge(appID: app.id)
            }
            .frame(width: nameWidth, alignment: .leading)

            Slider(
                value: Binding(get: { volume.level }, set: { model.setLevel($0, for: app.id) }),
                in: 0...max(model.maximumLevel, volume.level)
            ) { isEditing in
                if !isEditing { model.commitVolumes() }
            }
            .controlSize(.small)
            .accessibilityLabel(Text("\(name) volume"))

            LevelIndicator(volume: volume, issue: app.issue)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, PanelStyle.rowInset)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PanelStyle.highlight(isHovering)))
        .opacity(volume.isMuted ? 0.55 : 1)
        .onHover { isHovering = $0 }
        .animation(PanelStyle.hoverAnimation, value: isHovering)
        .animation(PanelStyle.hoverAnimation, value: volume.isMuted)
        .contextMenu {
            Button(volume.isMuted ? "Unmute" : "Mute") { model.toggleMute(app.id) }
            Button("Reset to 100%") { model.reset(app.id) }
                .disabled(volume.isNeutral)
            Menu("Output") {
                OutputMenuItems(appID: app.id)
            }
            if model.isBrowser(app) {
                Divider()
                Button("Control Each Tab Separately…") { model.showBrowserSetup(for: app) }
            }
        }
    }
}

private struct MuteButton: View {
    let icon: NSImage
    let appName: String
    let isMuted: Bool
    let showsAffordance: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: icon)
                .frame(width: PanelStyle.iconSize, height: PanelStyle.iconSize)
                .overlay(alignment: .bottomTrailing) {
                    if isMuted || showsAffordance {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 12, height: 12)
                            .background(Circle().fill(isMuted ? Color.red : Color.black.opacity(0.7)))
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                            .offset(x: 4, y: 3)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute \(appName)" : "Mute \(appName)")
        .accessibilityLabel(isMuted ? Text("Unmute \(appName)") : Text("Mute \(appName)"))
    }
}

struct LevelIndicator: View {
    let volume: AppVolume
    let issue: TapIssue?

    var body: some View {
        if let issue {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
                .frame(width: PanelStyle.levelColumnWidth, alignment: .trailing)
                .help(issue.message)
                .accessibilityLabel(issue.message)
        } else if volume.isMuted {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: PanelStyle.levelColumnWidth, alignment: .trailing)
                .accessibilityLabel("Muted")
        } else {
            PercentLabel(level: volume.level)
        }
    }
}
