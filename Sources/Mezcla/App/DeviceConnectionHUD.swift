import AppKit
import MezclaCore
import SwiftUI

/// A brief card under the menu bar when headphones or a speaker connect, in the spirit of the AirPods
/// card on iPhone: the device's glyph, its name and its battery. Fades in, lingers, fades out.
@MainActor
final class DeviceConnectionHUD {
    private static let visibleDuration: Duration = .seconds(2.8)
    private static let fade: TimeInterval = 0.25

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ device: OutputDevice, symbol: String, battery: BluetoothDetails.Battery?, below anchor: NSRect, on screen: NSScreen) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let host = NSHostingView(rootView: ConnectionCard(name: device.name, symbol: symbol, battery: battery))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = host

        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 0)
        let x = min(max(anchor.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 6 - size.height))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = Self.fade; panel.animator().alphaValue = 1 }
        self.panel = panel

        dismissTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled, let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    if self?.panel === panel { self?.panel = nil }
                }
            }
        }
    }
}

private struct ConnectionCard: View {
    let name: String
    let symbol: String
    let battery: BluetoothDetails.Battery?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.primary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text("Connected")
                    if let battery {
                        BatteryBreakdown(battery: battery)
                    }
                }
                .fixedSize() // The card grows to fit every battery rather than truncating one.
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .frame(minWidth: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
