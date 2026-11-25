public import Foundation

/// A browser tab that is playing (or just played) audio, reported by the Mezcla browser extension.
public struct BrowserTab: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        /// The browser app the tab belongs to, matching the app's row in the mixer.
        public let appID: AppID
        public let tabID: Int

        public init(appID: AppID, tabID: Int) {
            self.appID = appID
            self.tabID = tabID
        }
    }

    public let id: ID
    public let title: String
    public let url: URL?
    /// PNG favicon, when the site has one.
    public let favicon: Data?
    public let isAudible: Bool
    public var isMuted: Bool
    /// Slider position, 0…1.5, applied inside the page on top of the browser's own app volume.
    public var level: Double

    public init(id: ID, title: String, url: URL?, favicon: Data?, isAudible: Bool, isMuted: Bool, level: Double) {
        self.id = id
        self.title = title
        self.url = url
        self.favicon = favicon
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.level = level
    }

    public var volume: AppVolume {
        AppVolume(level: level, isMuted: isMuted)
    }
}

/// What the browsers report, published whenever it changes.
public struct BrowserSnapshot: Equatable, Sendable {
    /// Browsers whose extension is connected right now.
    public var connectedApps: Set<AppID>
    public var tabs: [BrowserTab]

    public init(connectedApps: Set<AppID>, tabs: [BrowserTab]) {
        self.connectedApps = connectedApps
        self.tabs = tabs
    }

    public static let empty = BrowserSnapshot(connectedApps: [], tabs: [])
}
