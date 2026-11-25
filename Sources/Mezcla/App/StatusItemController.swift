import AppKit
import MezclaCore
import SwiftUI

/// The menu bar icon and its panel: opening, positioning and every way of dismissing it.
@MainActor
final class StatusItemController: NSObject, PanelRouting {
    private static let gapBelowMenuBar: CGFloat = 5
    private static let fadeIn: TimeInterval = 0.12
    private static let fadeOut: TimeInterval = 0.1

    private let model: MixerViewModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var panel = makePanel()
    private let connectionHUD = DeviceConnectionHUD()
    private var dismissalObservers: [any NSObjectProtocol] = []
    private var outsideClickMonitor: Any?

    init(model: MixerViewModel) {
        self.model = model
        super.init()
        model.router = self
        configureButton()
    }

    func showBrowserSetup() {
        close()
        BrowserSetupGuide.present()
    }

    func showConnected(_ device: OutputDevice, symbol: String, battery: BluetoothDetails.Battery?) {
        // The open panel already shows the change; the card is for when Mezcla is out of the way.
        guard !isOpen, let button = statusItem.button, let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        connectionHUD.show(device, symbol: symbol, battery: battery, below: anchor, on: screen)
    }

    private var isOpen: Bool { panel.isVisible && panel.alphaValue > 0 }

    // MARK: - Status item

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Mezcla")
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityTitle("Mezcla")
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if isOpen {
            close()
        } else {
            open()
        }
    }

    private func showContextMenu() {
        close()
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Quit Mezcla"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // Left clicks keep opening the panel.
    }

    // MARK: - Panel

    private func makePanel() -> MenuBarPanel {
        let panel = MenuBarPanel(content: MixerPanel().environment(model))
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    private func open() {
        guard let button = statusItem.button, let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        model.applicationWillOpenPanel()

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.place(top: buttonFrame.minY - Self.gapBelowMenuBar, centerX: buttonFrame.midX, on: screen)
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        observeDismissal()
    }

    private func close() {
        guard panel.isVisible else { return }
        stopObservingDismissal()
        statusItem.button?.highlight(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOut
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return } // Re-opened meanwhile.
                self.panel.orderOut(nil)
            }
        }
    }

    // MARK: - Dismissal

    /// Like a menu: clicking anywhere else, switching apps or switching Spaces closes the panel.
    private func observeDismissal() {
        stopObservingDismissal()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let close: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        dismissalObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: close),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: close),
        ]
    }

    private func stopObservingDismissal() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        dismissalObservers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        dismissalObservers = []
    }
}
