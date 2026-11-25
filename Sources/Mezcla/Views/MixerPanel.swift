import CoreAudio
import SwiftUI

/// Root of the menu bar window.
struct MixerPanel: View {
    @Environment(MixerViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader()
            SystemVolumeRow()
                .padding(.top, 2)
            DeviceBatteryStrip()
            if !model.duckingCallNames.isEmpty {
                CallDuckingBanner(callNames: model.duckingCallNames)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            PanelDivider()
            if model.permission != .authorized {
                PermissionNotice()
                PanelDivider()
            }
            AppList()
            PanelDivider()
            PanelFooter()
        }
        .padding(PanelStyle.padding)
        .frame(width: PanelStyle.width)
        .animation(PanelStyle.listAnimation, value: model.duckingCallNames)
    }
}

struct PanelDivider: View {
    var body: some View {
        Divider().padding(.vertical, 6)
    }
}

private struct PanelHeader: View {
    @Environment(MixerViewModel.self) private var model

    var body: some View {
        HStack(alignment: .center) {
            Text("App Volume")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, PanelStyle.rowInset)
            Spacer(minLength: 8)
            OutputDevicePicker()
        }
        .padding(.bottom, 4)
    }
}

private struct OutputDevicePicker: View {
    @Environment(MixerViewModel.self) private var model

    var body: some View {
        Menu {
            Picker("Output", selection: selection) {
                ForEach(model.snapshot.outputDevices) { device in
                    Label(DeviceMenuTitle.text(device, battery: model.battery(of: device)?.summary), systemImage: model.symbol(for: device))
                        .tag(Optional(device.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HoverLabel {
                HStack(spacing: 4) {
                    if let device = model.defaultOutputDevice {
                        Image(systemName: model.symbol(for: device))
                            .symbolRenderingMode(.hierarchical)
                            .imageScale(.small)
                    }
                    Text(model.defaultOutputName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150)
                    if let battery = model.defaultOutputDevice.flatMap(model.battery(of:)), let summary = battery.summary {
                        BatteryLabel(percent: summary)
                            .font(.system(size: 10.5))
                            .help(BatteryBreakdown.text(battery))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sound Output")
    }

    private var selection: Binding<AudioDeviceID?> {
        Binding(
            get: { model.snapshot.defaultOutputID },
            set: { if let id = $0 { model.selectOutputDevice(id) } }
        )
    }
}

