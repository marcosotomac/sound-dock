import Foundation

/// Wire format between Mezcla and mezcla-bridge: one JSON object per line.
enum BrowserBridgeMessage {
    /// Messages from a browser.
    struct Inbound: Decodable {
        let type: String
        /// `hello`: the browser's bundle identifier and display name.
        let app: String?
        let browser: String?
        /// `tabs`: the tabs worth listing.
        let tabs: [Tab]?
    }

    struct Tab: Decodable {
        let id: Int
        let title: String
        let url: String?
        /// `data:image/png;base64,…`
        let icon: String?
        let audible: Bool
        let muted: Bool
        let level: Double
    }

    /// Volume for one tab, sent to its browser. `level` is the slider position; `gain` is the amplitude the
    /// page applies, on the same square-law curve as app volumes so 50 % sounds the same everywhere.
    struct SetVolume: Encodable {
        let type = "set"
        let tabId: Int
        let level: Double
        let gain: Double
        let muted: Bool
    }

    static func favicon(fromDataURL dataURL: String?) -> Data? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:image/") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }
}
