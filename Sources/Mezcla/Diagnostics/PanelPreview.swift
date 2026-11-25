import AppKit
import MezclaCore
import SwiftUI

/// `Mezcla --preview [demo] [light|dark] [quiet] [hud]` shows the real panel in the middle of the screen, for
/// screenshots and UI work. `demo` renders a fixed, representative state without touching the system's
/// audio, and `quiet` toggles "Show Apps That Aren’t Playing" after a second, to watch the panel resize.
@MainActor
enum PanelPreview {
    private static let hud = DeviceConnectionHUD()

    static func run(arguments: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.contains("light") {
            app.appearance = NSAppearance(named: .aqua)
        } else if arguments.contains("dark") {
            app.appearance = NSAppearance(named: .darkAqua)
        }

        let model = arguments.contains("demo") ? DemoEnvironment.makeViewModel() : AppComposition.makeViewModel()
        model.start()

        let panel = MenuBarPanel(content: MixerPanel().environment(model))
        if let screen = NSScreen.main {
            panel.place(top: screen.visibleFrame.midY + 260, centerX: screen.visibleFrame.midX, on: screen)
        }
        panel.orderFrontRegardless()

        if arguments.contains("hud"), let screen = NSScreen.main {
            let device = OutputDevice(id: 9, uid: "demo", name: "HUAWEI FreeBuds Pro 5", transport: .bluetooth)
            let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY + 340, width: 1, height: 1)
            hud.show(device, symbol: "earbuds", battery: .init(left: 80, right: 75, chargingCase: 100), below: anchor, on: screen)
        }

        if arguments.contains("quiet") {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                model.preferences.showsIdleApps.toggle()
            }
        }

        print("preview window \(panel.windowNumber)")
        fflush(stdout)
        withExtendedLifetime(panel) { app.run() }
        exit(0)
    }
}
