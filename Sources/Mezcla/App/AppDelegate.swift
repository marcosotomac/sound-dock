import AppKit

/// Lifecycle hooks for the menu bar app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = AppComposition.makeServices()
    private var model: MixerViewModel { services.model }
    private var statusItem: StatusItemController?
    private var wakeObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        services.safari.start()
        statusItem = StatusItemController(model: model)
        Task.detached(priority: .utility) { BrowserIntegration.install() }
        // Audio devices are re-created across sleep; rebuild taps against the fresh devices.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [model] _ in
            MainActor.assumeIsolated { model.systemDidWake() }
        }
    }

    // No teardown on quit: taps and aggregate devices are private to this process and the HAL removes
    // them the moment it exits, which also un-mutes every app.
}
