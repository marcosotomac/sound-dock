import SwiftUI

struct PanelFooter: View {
    @Environment(MixerViewModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            Menu {
                Toggle("Open at Login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchesAtLogin($0) }))
                Toggle("Allow Boost up to 150%", isOn: $model.preferences.allowsBoost)
                Toggle("Show Apps That Aren’t Playing", isOn: $model.preferences.showsIdleApps)
                Divider()
                Toggle("Lower Other Apps During Calls", isOn: $model.preferences.ducksDuringCalls)
                Picker("Lower To", selection: $model.preferences.duckingLevel) {
                    ForEach(Preferences.duckingLevels, id: \.self) { level in
                        Text(level, format: .percent.precision(.fractionLength(0))).tag(level)
                    }
                }
                .disabled(!model.preferences.ducksDuringCalls)
                Divider()
                Button("Per-Tab Volume in Browsers…") { model.showBrowserSetup() }
                Divider()
                Button("Reset All Apps", action: model.resetAll)
                    .disabled(!model.hasCustomVolumes)
            } label: {
                HoverLabel {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(FooterLabelStyle())
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button(action: model.quit) {
                HoverLabel { Text("Quit") }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }
}

private struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}
