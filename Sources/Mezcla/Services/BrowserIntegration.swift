import Foundation
import MezclaCore
import os

/// Connects Chromium browsers to Mezcla: registers the native messaging host with every installed
/// browser and keeps an up-to-date copy of the extension where the user can load it.
enum BrowserIntegration {
    static let extensionID = "lainmmojbickhmpaolpbmdkaolhhmoag" // Fixed by the key in the extension's manifest.
    static let hostName = "dev.mezcla.bridge"
    static let extensionsPage = "chrome://extensions"

    /// Chromium browsers and their profile folders under ~/Library/Application Support.
    private static let browsers: [(bundleID: String, supportFolder: String)] = [
        ("com.google.Chrome", "Google/Chrome"),
        ("com.google.Chrome.beta", "Google/Chrome Beta"),
        ("com.google.Chrome.dev", "Google/Chrome Dev"),
        ("com.google.Chrome.canary", "Google/Chrome Canary"),
        ("org.chromium.Chromium", "Chromium"),
        ("com.brave.Browser", "BraveSoftware/Brave-Browser"),
        ("com.brave.Browser.beta", "BraveSoftware/Brave-Browser-Beta"),
        ("com.brave.Browser.nightly", "BraveSoftware/Brave-Browser-Nightly"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.microsoft.edgemac.Beta", "Microsoft Edge Beta"),
        ("company.thebrowser.Browser", "Arc/User Data"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("com.operasoftware.Opera", "com.operasoftware.Opera"),
        ("com.operasoftware.OperaGX", "com.operasoftware.OperaGX"),
        ("net.imput.helium", "net.imput.helium"),
    ]

    private static let log = Logger(subsystem: "dev.mezcla", category: "browser-integration")

    /// Browsers Mezcla can control tab by tab: every Chromium browser above, plus Safari.
    static func isBrowser(_ id: AppID) -> Bool {
        id == SafariIntegration.appID || browsers.contains { $0.bundleID == id.rawValue }
    }

    /// Where the extension lives for "Load unpacked". Stable across app updates.
    static var extensionFolder: URL {
        applicationSupport.appending(path: "Mezcla/Browser Extension", directoryHint: .isDirectory)
    }

    /// Idempotent; cheap enough to run at every launch, which also follows the app if it moves.
    static func install() {
        let bundle = Bundle.main
        guard let bundledExtension = bundle.resourceURL?.appending(path: "BrowserExtension", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: bundledExtension.path)
        else { return } // Running outside the app bundle (swift run, tests).

        copyExtension(from: bundledExtension)
        let host = bundle.bundleURL.appending(path: "Contents/Helpers/mezcla-bridge")
        guard FileManager.default.isExecutableFile(atPath: host.path) else { return }
        for browser in browsers {
            registerHost(at: host, inProfileFolder: applicationSupport.appending(path: browser.supportFolder, directoryHint: .isDirectory))
        }
    }

    // MARK: - Steps

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func copyExtension(from source: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: extensionFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: extensionFolder.path) {
                _ = try fileManager.replaceItemAt(extensionFolder, withItemAt: temporaryCopy(of: source))
            } else {
                try fileManager.copyItem(at: source, to: extensionFolder)
            }
        } catch {
            log.error("Could not copy the browser extension: \(error, privacy: .public)")
        }
    }

    private static func temporaryCopy(of source: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appending(path: "Mezcla-Extension-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// Writes the native messaging host manifest, only for browsers that are actually installed.
    private static func registerHost(at host: URL, inProfileFolder profile: URL) {
        guard FileManager.default.fileExists(atPath: profile.path) else { return }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Mezcla per-tab volume",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        do {
            let folder = profile.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            let file = folder.appending(path: "\(hostName).json")
            if (try? Data(contentsOf: file)) != data {
                try data.write(to: file, options: .atomic)
            }
        } catch {
            log.error("Could not register the bridge in \(profile.path, privacy: .public): \(error, privacy: .public)")
        }
    }
}
