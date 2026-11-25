import AppKit
import MezclaCore
import SafariServices

/// Walks the user through the one-time extension install that enables per-tab volume, with the steps for
/// the browser they clicked (or for every browser, from Settings).
@MainActor
enum BrowserSetupGuide {
    static func present(for browser: AudioApp?) {
        BrowserIntegration.install() // Make sure the folder we point to exists and is current.

        let isSafari = browser?.id == SafariIntegration.appID
        let alert = NSAlert()
        alert.icon = icon
        alert.messageText = browser.map { String(localized: "Control each \($0.name) tab") }
            ?? String(localized: "Control each browser tab")

        let why = String(localized: """
        Browsers mix all of their tabs into one sound before it reaches macOS, so per-tab volume needs \
        Mezcla’s small extension inside the browser. It only adjusts volume and never reads what you browse.
        """)
        switch browser {
        case .some where isSafari:
            alert.informativeText = why + "\n\n" + safariSteps + "\n\n" + String(localized: """
            Safari turns “Allow unsigned extensions” off each time it quits, so repeat step 2 after \
            restarting Safari.
            """)
            alert.addButton(withTitle: String(localized: "Open Safari Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                openSafariSettings()
            }

        case .some:
            alert.informativeText = why + "\n\n" + chromiumSteps
            addChromiumButtons(to: alert)
            NSApp.activate()
            handleChromium(alert.runModal())

        case .none:
            alert.informativeText = why + "\n\n" + String(localized: "Safari") + "\n" + safariSteps + "\n\n"
                + String(localized: "Chrome, Helium, Brave, Edge, Arc, Vivaldi or Opera") + "\n" + chromiumSteps
            addChromiumButtons(to: alert)
            NSApp.activate()
            handleChromium(alert.runModal())
        }
    }

    private static var icon: NSImage? {
        NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular).applying(.init(hierarchicalColor: .systemOrange)))
    }

    private static let safariSteps = String(localized: """
    1. In Safari › Settings › Advanced, turn on “Show features for web developers”.
    2. In the new Developer tab, turn on “Allow unsigned extensions”.
    3. In Extensions, turn on Mezcla and allow it on all websites, then reload the tab.
    """)

    private static var chromiumSteps: String {
        let page = BrowserIntegration.extensionsPage
        return String(localized: """
        1. Paste \(page) into the address bar (Mezcla copies it for you) and turn on Developer mode.
        2. Click “Load unpacked” and choose the “Browser Extension” folder that Mezcla shows in Finder.
        3. Reload the tab.
        """)
    }

    private static func addChromiumButtons(to alert: NSAlert) {
        alert.addButton(withTitle: String(localized: "Show Folder and Copy Address"))
        alert.addButton(withTitle: String(localized: "Cancel"))
    }

    private static func handleChromium(_ response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BrowserIntegration.extensionsPage, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([BrowserIntegration.extensionFolder])
    }

    private static func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: SafariIntegration.extensionIdentifier) { error in
            guard error != nil else { return }
            // Safari hides unsigned extensions until they are allowed: open Safari itself instead.
            Task { @MainActor in
                if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                    NSWorkspace.shared.openApplication(at: safari, configuration: .init())
                }
            }
        }
    }
}
