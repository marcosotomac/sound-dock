import AppKit

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
