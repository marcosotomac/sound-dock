import Foundation
import SafariServices
import os

/// Native side of the Safari web extension. Runs sandboxed inside Mezcla.app's plug-in.
///
/// Each report the extension sends with `sendNativeMessage` arrives here and is handed to the Mezcla app as
/// a distributed notification (a string payload is what the sandbox allows). Mezcla answers through
/// `SFSafariApplication.dispatchMessage`, which reaches the extension directly.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    static let notification = Notification.Name("dev.mezcla.safari.message")
    private static let log = Logger(subsystem: "dev.mezcla", category: "safari-extension")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        if let message = item?.userInfo?[SFExtensionMessageKey],
           JSONSerialization.isValidJSONObject(message),
           let data = try? JSONSerialization.data(withJSONObject: message),
           let json = String(data: data, encoding: .utf8) {
            DistributedNotificationCenter.default().postNotificationName(Self.notification, object: json, userInfo: nil, deliverImmediately: true)
        } else {
            Self.log.error("Ignored a message that is not JSON")
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response])
    }
}
