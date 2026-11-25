import MezclaCore
import SwiftUI

/// Battery glyph that fills with the charge, the way macOS shows device batteries. Red at 20 % or less.
struct BatteryLabel: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: percent))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(percent <= 20 ? Color.red : Color.secondary)
            Text(Double(percent) / 100, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery \(percent) percent"))
    }

    static func symbol(for percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Every battery a device reports: left and right buds and the case, or its single battery.
struct BatteryBreakdown: View {
    let battery: BluetoothDetails.Battery

    var body: some View {
        HStack(spacing: 10) {
            if battery.left != nil || battery.right != nil {
                if let left = battery.left { part("L", left) }
                if let right = battery.right { part("R", right) }
            } else if let main = battery.main {
                BatteryLabel(percent: main)
            }
            if let chargingCase = battery.chargingCase {
                part("Case", chargingCase)
            }
        }
    }

    private func part(_ name: LocalizedStringKey, _ percent: Int) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.tertiary)
            BatteryLabel(percent: percent)
        }
    }

    /// "Left 80 % · Right 75 % · Case 100 %", for tooltips and accessibility.
    static func text(_ battery: BluetoothDetails.Battery) -> String {
        let percent = { (value: Int) in (Double(value) / 100).formatted(.percent.precision(.fractionLength(0))) }
        var parts: [String] = []
        if let left = battery.left { parts.append(String(localized: "Left \(percent(left))")) }
        if let right = battery.right { parts.append(String(localized: "Right \(percent(right))")) }
        if parts.isEmpty, let main = battery.main { parts.append(String(localized: "Battery \(percent(main))")) }
        if let chargingCase = battery.chargingCase { parts.append(String(localized: "Case \(percent(chargingCase))")) }
        return parts.joined(separator: " · ")
    }
}

/// The other connected headphones and speakers with their charge, like the Batteries widget on iPhone.
/// The active output's battery lives in the header, so this only appears with a second device.
struct DeviceBatteryStrip: View {
    @Environment(MixerViewModel.self) private var model

    var body: some View {
        let devices = model.connectedBatteries
        if !devices.isEmpty {
            HStack(spacing: 6) {
                ForEach(devices, id: \.device.id) { entry in
                    if let summary = entry.battery.summary ?? entry.battery.chargingCase {
                        HStack(spacing: 5) {
                            Image(systemName: model.symbol(for: entry.device))
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 11))
                            BatteryLabel(percent: summary)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .help("\(entry.device.name)\n\(BatteryBreakdown.text(entry.battery))")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(entry.device.name), \(BatteryBreakdown.text(entry.battery))"))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PanelStyle.rowInset)
            .padding(.top, 8)
        }
    }
}
