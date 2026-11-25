import AppKit
import MezclaCore

/// Process entry point: runs a diagnostic mode when asked to, otherwise the menu bar app.
@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--selftest") {
            let rest = arguments.dropFirst(index + 1)
            SelfTest.run(appFilter: rest.first, percent: rest.dropFirst().first.flatMap(Int.init))
        }
        if let index = arguments.firstIndex(of: "--setup-guide") {
            // `--setup-guide [com.apple.Safari|net.imput.helium]`: the extension guide, for screenshots.
            NSApplication.shared.setActivationPolicy(.accessory)
            let browser = arguments.dropFirst(index + 1).first.map {
                AudioApp(id: AppID(rawValue: $0), name: $0 == "com.apple.Safari" ? "Safari" : "Helium", path: nil, kind: .application, isPlaying: true, issue: nil)
            }
            BrowserSetupGuide.present(for: browser)
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--preview") {
            PanelPreview.run(arguments: Array(arguments.dropFirst(index + 1)))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() } // NSApplication holds its delegate weakly.
    }
}
