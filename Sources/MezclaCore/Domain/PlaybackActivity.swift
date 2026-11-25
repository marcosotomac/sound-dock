/// Keeps an app in "Playing Now" for a moment after it falls silent.
///
/// Sounds are often short (a notification, a chime). Without a grace period the row would appear and
/// vanish before the user could reach its slider, and rows would jump between sections mid-gesture.
public struct PlaybackActivity: Sendable {
    public static let gracePeriod: Duration = .seconds(8)

    private var silencedAt: [AppID: ContinuousClock.Instant] = [:]
    private var playing: Set<AppID> = []

    /// Records a new snapshot of which apps are producing sound.
    public init() {}

    public mutating func update(with apps: [AudioApp], now: ContinuousClock.Instant) {
        let nowPlaying = Set(apps.lazy.filter(\.isPlaying).map(\.id))
        for id in playing.subtracting(nowPlaying) {
            silencedAt[id] = now
        }
        for id in nowPlaying {
            silencedAt[id] = nil
        }
        playing = nowPlaying
        expire(now: now)
    }

    /// Forgets apps whose grace period is over.
    public mutating func expire(now: ContinuousClock.Instant) {
        silencedAt = silencedAt.filter { now - $0.value < Self.gracePeriod }
    }

    public func isActive(_ id: AppID) -> Bool {
        playing.contains(id) || silencedAt[id] != nil
    }

    /// When the next app leaves the "active" set, if any.
    public var nextExpiry: ContinuousClock.Instant? {
        silencedAt.values.min().map { $0 + Self.gracePeriod }
    }
}
