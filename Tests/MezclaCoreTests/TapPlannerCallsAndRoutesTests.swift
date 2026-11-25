import CoreAudio
import MezclaCore
import Testing

@Suite("TapPlanner: calls and per-app outputs")
struct TapPlannerCallsAndRoutesTests {
    private let planner = TapPlanner()
    private let zoom: AppID = "us.zoom.xos"
    private let spotify: AppID = "com.spotify.client"
    private let speakers: AudioDeviceID = 70
    private let headphones: AudioDeviceID = 90

    private func group(_ id: AppID, kind: AppIdentity.Kind = .application, playing: Bool = true, capturing: Bool = false, object: AudioObjectID) -> TapPlanner.Group {
        .init(id: id, kind: kind, processObjects: [object], isPlaying: playing, isCapturing: capturing, outputDevices: [])
    }

    private func input(_ groups: [TapPlanner.Group], volumes: [AppID: AppVolume] = [:], routes: [AppID: AudioDeviceID] = [:],
                       duck: Float? = 0.09, taps: [AppID: TapPlanner.TapState] = [:]) -> TapPlanner.Input {
        .init(groups: groups, volumes: volumes, routes: routes, duckingGain: duck, taps: taps,
              defaultOutputDevice: speakers, captureAuthorized: true, now: 100)
    }

    // MARK: Call detection

    @Test func appRecordingAndPlayingIsACall() {
        let calls = TapPlanner.calls(in: [group(zoom, capturing: true, object: 1), group(spotify, object: 2)])
        #expect(calls == [zoom])
    }

    @Test func dictationAndSiriAreNotCalls() {
        let dictation = group("com.prakashjoshipax.VoiceInk", playing: false, capturing: true, object: 1)
        let siri = group("exe:/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd", kind: .systemService, capturing: true, object: 2)
        #expect(TapPlanner.calls(in: [dictation, siri]).isEmpty)
    }

    @Test func faceTimeServiceIsACall() {
        let faceTime = group("exe:/usr/libexec/avconferenced", kind: .systemService, capturing: true, object: 3)
        #expect(TapPlanner.calls(in: [faceTime]) == ["exe:/usr/libexec/avconferenced"])
    }

    // MARK: Ducking

    @Test func otherAppsAreDuckedDuringACall() {
        let plan = planner.plan(input([group(zoom, capturing: true, object: 1), group(spotify, object: 2)]))
        #expect(plan.calls == [zoom])
        #expect(plan.actions == [
            .create(spotify, .init(processObjects: [2], deviceID: speakers), gain: 1, duck: 0.09),
            .start(spotify),
        ])
    }

    @Test func noDuckingWhenTurnedOff() {
        let plan = planner.plan(input([group(zoom, capturing: true, object: 1), group(spotify, object: 2)], duck: nil))
        #expect(plan.actions.isEmpty)
    }

    @Test func silentAppsAreNotTappedJustToDuckThem() {
        let plan = planner.plan(input([group(zoom, capturing: true, object: 1), group(spotify, playing: false, object: 2)]))
        #expect(plan.actions.isEmpty)
    }

    @Test func endOfCallFadesBackThenTearsDown() {
        let tap = TapPlanner.TapState(spec: .init(processObjects: [2], deviceID: speakers), isRunning: true, gain: 1, duck: 0.09)
        let plan = planner.plan(input([group(zoom, capturing: false, object: 1), group(spotify, object: 2)], taps: [spotify: tap]))
        #expect(plan.actions == [.setDuck(spotify, 1)])
        #expect(plan.nextDeadline != nil)
    }

    @Test func duckingStacksWithTheUsersVolume() {
        let volume = AppVolume(level: 0.5)
        let plan = planner.plan(input([group(zoom, capturing: true, object: 1), group(spotify, object: 2)], volumes: [spotify: volume]))
        #expect(plan.actions.first == .create(spotify, .init(processObjects: [2], deviceID: speakers), gain: volume.gain, duck: 0.09))
    }

    // MARK: Per-app outputs

    @Test func routedAppGetsATapOnItsDevice() {
        let plan = planner.plan(input([group(spotify, object: 2)], routes: [spotify: headphones]))
        #expect(plan.actions == [
            .create(spotify, .init(processObjects: [2], deviceID: headphones), gain: 1),
            .start(spotify),
        ])
    }

    @Test func routeToTheDeviceItAlreadyUsesNeedsNoTap() {
        let plan = planner.plan(input([group(spotify, object: 2)], routes: [spotify: speakers]))
        #expect(plan.actions.isEmpty)
    }

    @Test func changingTheRouteRebuildsOnTheNewDevice() {
        let tap = TapPlanner.TapState(spec: .init(processObjects: [2], deviceID: headphones), isRunning: true, gain: 1)
        let externalSpeaker: AudioDeviceID = 120
        let plan = planner.plan(input([group(spotify, object: 2)], routes: [spotify: externalSpeaker], taps: [spotify: tap]))
        #expect(plan.actions == [
            .rebuild(spotify, .init(processObjects: [2], deviceID: externalSpeaker), gain: 1),
            .start(spotify),
        ])
    }

    @Test func clearingTheRouteStopsImmediatelyInsteadOfLingeringOnTheOldDevice() {
        let tap = TapPlanner.TapState(spec: .init(processObjects: [2], deviceID: headphones), isRunning: true, gain: 1)
        let plan = planner.plan(input([group(spotify, object: 2)], taps: [spotify: tap]))
        #expect(plan.actions == [.destroy(spotify)])
    }
}
