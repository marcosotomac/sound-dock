import SwiftUI

/// Volume of the current output device, kept in sync with the volume keys.
struct SystemVolumeRow: View {
    @Environment(MixerViewModel.self) private var model

    var body: some View {
        let volume = model.snapshot.systemVolume
        let level = Double(volume.level ?? 0)
        let isMuted = volume.isMuted ?? false

        HStack(spacing: PanelStyle.columnSpacing) {
            Button(action: model.toggleSystemMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: level)
                    .font(.system(size: 13))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: PanelStyle.iconSize, height: PanelStyle.iconSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(volume.isMuted == nil)
            .help(isMuted ? "Unmute output" : "Mute output")
            .accessibilityLabel(isMuted ? "Unmute output" : "Mute output")

            Slider(value: Binding(get: { level }, set: { model.setSystemVolume(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .disabled(volume.level == nil)
                .accessibilityLabel("Output volume")

            PercentLabel(level: level)
        }
        .padding(.horizontal, PanelStyle.rowInset)
        .opacity(isMuted ? 0.55 : 1)
        .animation(PanelStyle.hoverAnimation, value: isMuted)
    }
}
