import MezclaCore
import Testing

@Suite("PlaybackActivity")
struct PlaybackActivityTests {
    private let start = ContinuousClock.now

    private func app(playing: Bool) -> AudioApp {
        AudioApp(id: "com.t3tools.t3code", name: "T3 Code", path: nil, kind: .application, isPlaying: playing, issue: nil)
    }

    @Test func playingAppIsActive() {
        var activity = PlaybackActivity()
        activity.update(with: [app(playing: true)], now: start)
        #expect(activity.isActive("com.t3tools.t3code"))
        #expect(activity.nextExpiry == nil)
    }

    @Test func shortSoundStaysActiveForTheGracePeriod() {
        var activity = PlaybackActivity()
        activity.update(with: [app(playing: true)], now: start)
        activity.update(with: [app(playing: false)], now: start + .seconds(1))
        #expect(activity.isActive("com.t3tools.t3code"))
        #expect(activity.nextExpiry == start + .seconds(1) + PlaybackActivity.gracePeriod)

        activity.expire(now: start + .seconds(1) + PlaybackActivity.gracePeriod)
        #expect(!activity.isActive("com.t3tools.t3code"))
        #expect(activity.nextExpiry == nil)
    }

    @Test func playingAgainCancelsTheCountdown() {
        var activity = PlaybackActivity()
        activity.update(with: [app(playing: true)], now: start)
        activity.update(with: [app(playing: false)], now: start + .seconds(1))
        activity.update(with: [app(playing: true)], now: start + .seconds(2))
        activity.expire(now: start + .seconds(60))
        #expect(activity.isActive("com.t3tools.t3code"))
    }

    @Test func appThatNeverPlayedIsNotActive() {
        var activity = PlaybackActivity()
        activity.update(with: [app(playing: false)], now: start)
        #expect(!activity.isActive("com.t3tools.t3code"))
    }
}
