import CoreAudio
import MezclaCore
import Testing

@Suite("TapPlanner")
struct TapPlannerTests {
    private let planner = TapPlanner(policy: .init(idleStopDelay: 15, neutralTeardownDelay: 3))
    private let spotify: AppID = "com.spotify.client"
    private let speakers: AudioDeviceID = 70
    private let headphones: AudioDeviceID = 90

    private func group(playing: Bool = true, processes: Set<AudioObjectID> = [1], devices: [AudioDeviceID] = []) -> TapPlanner.Group {
        .init(id: spotify, processObjects: processes, isPlaying: playing, outputDevices: devices)
    }

    private func tap(device: AudioDeviceID? = nil, processes: Set<AudioObjectID> = [1], running: Bool = true, gain: Float) -> TapPlanner.TapState {
        .init(spec: .init(processObjects: processes, deviceID: device ?? speakers), isRunning: running, gain: gain)
    }

    private func input(
        groups: [TapPlanner.Group],
        volume: AppVolume? = nil,
        tap: TapPlanner.TapState? = nil,
        timeline: TapPlanner.Timeline? = nil,
        failed: TapPlanner.Spec? = nil,
        authorized: Bool = true,
        now: TimeInterval = 100
    ) -> TapPlanner.Input {
        .init(
            groups: groups,
            volumes: volume.map { [spotify: $0] } ?? [:],
            taps: tap.map { [spotify: $0] } ?? [:],
            timelines: timeline.map { [spotify: $0] } ?? [:],
            failedSpecs: failed.map { [spotify: $0] } ?? [:],
            defaultOutputDevice: speakers,
            captureAuthorized: authorized,
            now: now
        )
    }

    @Test func appsAtFullVolumeAreLeftUntouched() {
        let plan = planner.plan(input(groups: [group()]))
        #expect(plan.actions.isEmpty)
        #expect(plan.nextDeadline == nil)
    }

    @Test func customVolumeOnPlayingAppCreatesAndStartsTap() {
        let volume = AppVolume(level: 0.5)
        let plan = planner.plan(input(groups: [group()], volume: volume))
        #expect(plan.actions == [
            .create(spotify, .init(processObjects: [1], deviceID: speakers), gain: volume.gain),
            .start(spotify),
        ])
    }

    @Test func silentAppGetsTapReadyButNotRunning() {
        let plan = planner.plan(input(groups: [group(playing: false)], volume: AppVolume(level: 0.3)))
        #expect(plan.actions.count == 1)
        guard case .create = plan.actions.first else {
            Issue.record("Expected a create action")
            return
        }
    }

    @Test func nothingHappensWithoutCapturePermission() {
        let plan = planner.plan(input(groups: [group()], volume: AppVolume(level: 0.5), authorized: false))
        #expect(plan.actions.isEmpty)
    }

    @Test func revokingPermissionDestroysExistingTaps() {
        let plan = planner.plan(input(groups: [group()], volume: AppVolume(level: 0.5), tap: tap(gain: 0.25), authorized: false))
        #expect(plan.actions == [.destroy(spotify)])
    }

    @Test func failedSpecIsNotRetriedUntilItChanges() {
        let spec = TapPlanner.Spec(processObjects: [1], deviceID: speakers)
        let blocked = planner.plan(input(groups: [group()], volume: AppVolume(level: 0.5), failed: spec))
        #expect(blocked.actions.isEmpty)

        let changed = planner.plan(input(groups: [group(processes: [1, 2])], volume: AppVolume(level: 0.5), failed: spec))
        #expect(changed.actions.first == .create(spotify, .init(processObjects: [1, 2], deviceID: speakers), gain: AppVolume(level: 0.5).gain))
    }

    @Test func movingTheSliderOnlyChangesGain() {
        let volume = AppVolume(level: 0.8)
        let plan = planner.plan(input(groups: [group()], volume: volume, tap: tap(gain: 0.25)))
        #expect(plan.actions == [.setGain(spotify, volume.gain)])
    }

    @Test func mutingSetsGainToZero() {
        let plan = planner.plan(input(groups: [group()], volume: AppVolume(level: 0.8, isMuted: true), tap: tap(gain: 0.64)))
        #expect(plan.actions == [.setGain(spotify, 0)])
    }

    @Test func outputDeviceChangeRebuildsTap() {
        var request = input(groups: [group()], volume: AppVolume(level: 0.5), tap: tap(gain: 0.25))
        request.defaultOutputDevice = headphones
        let plan = planner.plan(request)
        #expect(plan.actions == [
            .rebuild(spotify, .init(processObjects: [1], deviceID: headphones), gain: AppVolume(level: 0.5).gain),
            .start(spotify),
        ])
    }

    @Test func newHelperProcessIsAddedInPlace() {
        let plan = planner.plan(input(groups: [group(processes: [1, 2])], volume: AppVolume(level: 0.5), tap: tap(gain: 0.25)))
        #expect(plan.actions == [.updateProcesses(spotify, [1, 2])])
    }

    @Test func appOnAnotherDeviceIsFollowed() {
        let playingElsewhere = group(devices: [headphones])
        #expect(TapPlanner.outputDevice(for: playingElsewhere, defaultDevice: speakers) == headphones)
        #expect(TapPlanner.outputDevice(for: group(devices: [speakers, headphones]), defaultDevice: speakers) == speakers)
        #expect(TapPlanner.outputDevice(for: group(devices: []), defaultDevice: speakers) == speakers)
    }

    @Test func idleTapStopsOnlyAfterDelay() {
        let volume = AppVolume(level: 0.5)
        let first = planner.plan(input(groups: [group(playing: false)], volume: volume, tap: tap(gain: volume.gain), now: 100))
        #expect(first.actions.isEmpty)
        #expect(first.nextDeadline == 115)
        #expect(first.timelines[spotify]?.idleSince == 100)

        let later = planner.plan(input(
            groups: [group(playing: false)], volume: volume, tap: tap(gain: volume.gain),
            timeline: first.timelines[spotify], now: 115
        ))
        #expect(later.actions == [.stop(spotify)])
        #expect(later.nextDeadline == nil)
    }

    @Test func playingAgainRestartsStoppedTap() {
        let volume = AppVolume(level: 0.5)
        let plan = planner.plan(input(groups: [group()], volume: volume, tap: tap(running: false, gain: volume.gain)))
        #expect(plan.actions == [.start(spotify)])
    }

    @Test func returningToFullVolumeLingersAtUnityThenTearsDown() {
        let first = planner.plan(input(groups: [group()], volume: .unity, tap: tap(gain: 0.25), now: 100))
        #expect(first.actions == [.setGain(spotify, 1)])
        #expect(first.nextDeadline == 103)

        let later = planner.plan(input(groups: [group()], volume: .unity, tap: tap(gain: 1), timeline: first.timelines[spotify], now: 103))
        #expect(later.actions == [.destroy(spotify)])
    }

    @Test func leavingNeutralBeforeTeardownKeepsTheTap() {
        let volume = AppVolume(level: 0.7)
        let plan = planner.plan(input(
            groups: [group()], volume: volume, tap: tap(gain: 1),
            timeline: .init(neutralSince: 100), now: 101
        ))
        #expect(plan.actions == [.setGain(spotify, volume.gain)])
        #expect(plan.timelines[spotify]?.neutralSince == nil)
    }

    @Test func quitAppTapIsDestroyed() {
        let plan = planner.plan(input(groups: [], volume: AppVolume(level: 0.5), tap: tap(gain: 0.25)))
        #expect(plan.actions == [.destroy(spotify)])
    }
}
