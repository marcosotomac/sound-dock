/// Who an audio process belongs to, from the user's point of view.
public struct AppIdentity: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A regular app with a Dock icon.
        case application
        /// An agent or menu bar app.
        case backgroundApplication
        /// A command-line tool such as `afplay` or `mpv`.
        case executable
        /// A process that ships with macOS (`corespeechd`, `systemsoundserverd`).
        case systemService
    }

    public let id: AppID
    public let name: String
    public let path: String?
    public let kind: Kind

    public init(id: AppID, name: String, path: String?, kind: Kind) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
    }
}
