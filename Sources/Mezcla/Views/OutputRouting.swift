import MezclaCore
import SwiftUI

/// The outputs an app can be sent to, with the current choice checked.
struct OutputMenuItems: View {
    let appID: AppID

    @Environment(MixerViewModel.self) private var model

    var body: some View {
        let route = model.routes[appID]
        Picker("Output", selection: Binding(
            get: { route?.deviceUID },
            set: { uid in model.setOutput(uid.flatMap { uid in model.snapshot.outputDevices.first { $0.uid == uid } }, for: appID) }
        )) {
            Label("System Output", systemImage: "macwindow").tag(String?.none)
            ForEach(model.snapshot.outputDevices) { device in
                Label(DeviceMenuTitle.text(device, battery: model.battery(of: device)?.summary), systemImage: model.symbol(for: device))
                    .tag(Optional(device.uid))
            }
            if let route, !model.snapshot.outputDevices.contains(where: { $0.uid == route.deviceUID }) {
                Label("\(route.deviceName) (Not Connected)", systemImage: "exclamationmark.triangle").tag(Optional(route.deviceUID))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// Shown next to an app's name when it plays somewhere other than the system output. Click to change it.
struct RouteBadge: View {
    let appID: AppID

    @Environment(MixerViewModel.self) private var model

    var body: some View {
        switch model.routeState(for: appID) {
        case .systemDefault:
            EmptyView()
        case let .device(device):
            badge(symbol: model.symbol(for: device), tint: .secondary, help: "Plays on \(device.name)")
        case let .unavailable(name):
            badge(symbol: "exclamationmark.triangle.fill", tint: .yellow, help: "\(name) isn’t connected, so this app plays on the system output.")
        }
    }

    private func badge(symbol: String, tint: Color, help: LocalizedStringKey) -> some View {
        Menu {
            OutputMenuItems(appID: appID)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// "AirPods Pro — 80 %" in device menus, the way the Sound menu shows battery.
enum DeviceMenuTitle {
    static func text(_ device: OutputDevice, battery: Int?) -> String {
        guard let battery else { return device.name }
        return "\(device.name)  —  \((Double(battery) / 100).formatted(.percent.precision(.fractionLength(0))))"
    }
}

/// The orange dot of the macOS privacy indicator, as a microphone glyph.
struct MicrophoneBadge: View {
    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.orange)
            .help("Using the microphone")
            .accessibilityLabel("Using the microphone")
    }
}

/// Explains why music just got quieter.
struct CallDuckingBanner: View {
    let callNames: [String]

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "phone.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
            Text("On a call in \(callNames.formatted(.list(type: .and)))")
                .foregroundStyle(.primary)
            Text("· other audio lowered")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.green.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }
}
