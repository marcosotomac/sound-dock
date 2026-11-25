import Foundation
import MezclaCore
import SafariServices
import os

/// Links the Safari web extension to the browser bridge.
///
/// Safari reports arrive as distributed notifications posted by Mezcla's sandboxed app extension; commands
/// go back through `SFSafariApplication.dispatchMessage`, which Safari delivers to the extension's native port.
@MainActor
final class SafariIntegration {
    nonisolated static let appID: AppID = "com.apple.Safari"
    static let extensionIdentifier = "dev.mezcla.Mezcla.Safari"
    private static let reports = Notification.Name("dev.mezcla.safari.message")
    private nonisolated static let log = Logger(subsystem: "dev.mezcla", category: "safari")

    private let bridge: BrowserBridge
    private var observer: (any NSObjectProtocol)?

    init(bridge: BrowserBridge) {
        self.bridge = bridge
    }

    func start() {
        let bridge = bridge
        Task {
            await bridge.registerMessageBrowser(Self.appID) { message in
                Task { @MainActor in Self.dispatch(message) }
            }
        }
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.reports, object: nil, queue: .main) { notification in
            guard let json = notification.object as? String else { return }
            Task { await bridge.receive(Data(json.utf8), fromMessageBrowser: Self.appID) }
        }
    }

    private static func dispatch(_ message: Data) {
        guard let userInfo = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { return }
        SFSafariApplication.dispatchMessage(withName: "mezcla", toExtensionWithIdentifier: extensionIdentifier, userInfo: userInfo) { error in
            if let error {
                log.error("Could not reach the Safari extension: \(error, privacy: .public)")
            }
        }
    }
}
