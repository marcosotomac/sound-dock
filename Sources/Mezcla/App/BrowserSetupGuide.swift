import AppKit

/// Walks the user through the one-time extension install that enables per-tab volume.
@MainActor
enum BrowserSetupGuide {
    static func present() {
        BrowserIntegration.install() // Make sure the folder we point to exists and is current.

        let alert = NSAlert()
        alert.messageText = String(localized: "Control each browser tab")
        alert.informativeText = String(localized: """
        Browsers mix all of their tabs into a single audio stream before macOS sees it, so per-tab volume \
        has to happen inside the browser. Turn on the Mezcla extension once per browser:

        Safari: Settings › Extensions › turn on Mezcla, then allow it on all websites.

        Helium, Chrome, Brave, Edge, Arc, Vivaldi or Opera:
        1. Open \(BrowserIntegration.extensionsPage) and turn on Developer mode.
        2. Click “Load unpacked” and choose the “Browser Extension” folder that opens in Finder.

        Tabs that play audio then appear under their browser in Mezcla.
        """)
        alert.icon = NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular).applying(.preferringMulticolor()))
        alert.addButton(withTitle: String(localized: "Show Folder"))
        alert.addButton(withTitle: String(localized: "Copy “\(BrowserIntegration.extensionsPage)”"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([BrowserIntegration.extensionFolder])
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(BrowserIntegration.extensionsPage, forType: .string)
        default:
            break
        }
    }
}
