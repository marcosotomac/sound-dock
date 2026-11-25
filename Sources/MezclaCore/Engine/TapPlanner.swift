public import CoreAudio
public import Foundation

/// Decides which taps should exist and what state they should be in. Pure: no Core Audio, no clocks.
///
/// An app gets a tap when it needs one: a custom volume, an output other than where it would play
/// anyway, or ducking because a call is in progress. Policies that keep Mezcla light:
/// - An app that needs none of that has no tap: zero overhead and bit-exact audio.
/// - A tap only renders while its app is producing sound; after `idleStopDelay` of silence the IOProc
///   stops so the output device can sleep.
/// - When a tap stops being needed it lingers at unity for `neutralTeardownDelay`, so dragging a slider
///   through 100 % (or a call's fade-back) does not rebuild the pipeline.
public struct TapPlanner: Sendable {
    public struct Policy: Equatable, Sendable {
        public var idleStopDelay: TimeInterval
        public var neutralTeardownDelay: TimeInterval

        public init(idleStopDelay: TimeInterval = 15, neutralTeardownDelay: TimeInterval = 3) {
            self.idleStopDelay = idleStopDelay
            self.neutralTeardownDelay = neutralTeardownDelay
        }
    }

    /// All the audio processes of one app.
    public struct Group: Equatable, Sendable {
        public var id: AppID
        public var kind: AppIdentity.Kind
        public var processObjects: Set<AudioObjectID>
        public var isPlaying: Bool
        /// True while one of its processes records from an input device.
        public var isCapturing: Bool
        /// Devices the app sends audio to, excluding Mezcla's own aggregate devices.
        public var outputDevices: [AudioDeviceID]

        public init(
            id: AppID,
            kind: AppIdentity.Kind = .application,
            processObjects: Set<AudioObjectID>,
            isPlaying: Bool,
            isCapturing: Bool = false,
            outputDevices: [AudioDeviceID]
        ) {
            self.id = id
            self.kind = kind
            self.processObjects = processObjects
            self.isPlaying = isPlaying
            self.isCapturing = isCapturing
            self.outputDevices = outputDevices
        }
    }

    /// What a tap is built from. A tap must be rebuilt when its device changes.
    public struct Spec: Hashable, Sendable {
        public var processObjects: Set<AudioObjectID>
        public var deviceID: AudioDeviceID

        public init(processObjects: Set<AudioObjectID>, deviceID: AudioDeviceID) {
            self.processObjects = processObjects
            self.deviceID = deviceID
        }
    }

    public struct TapState: Equatable, Sendable {
        public var spec: Spec
        public var isRunning: Bool
        public var gain: Float
        public var duck: Float

        public init(spec: Spec, isRunning: Bool, gain: Float, duck: Float = 1) {
            self.spec = spec
            self.isRunning = isRunning
            self.gain = gain
            self.duck = duck
        }
    }

    /// When a tap entered a state that ends after a delay.
    public struct Timeline: Equatable, Sendable {
        public var idleSince: TimeInterval?
        public var neutralSince: TimeInterval?

        public init(idleSince: TimeInterval? = nil, neutralSince: TimeInterval? = nil) {
            self.idleSince = idleSince
            self.neutralSince = neutralSince
        }
    }

    public struct Input: Sendable {
        public var groups: [Group]
        public var volumes: [AppID: AppVolume]
        /// Output chosen per app, already resolved to devices that are connected.
        public var routes: [AppID: AudioDeviceID]
        /// Gain applied to everything else while a call is in progress; `nil` disables ducking.
        public var duckingGain: Float?
        public var taps: [AppID: TapState]
        public var timelines: [AppID: Timeline]
        /// Specs that failed to build; not retried until something about them changes.
        public var failedSpecs: [AppID: Spec]
        public var defaultOutputDevice: AudioDeviceID?
        public var captureAuthorized: Bool
        public var now: TimeInterval

        public init(
            groups: [Group],
            volumes: [AppID: AppVolume],
            routes: [AppID: AudioDeviceID] = [:],
            duckingGain: Float? = nil,
            taps: [AppID: TapState] = [:],
            timelines: [AppID: Timeline] = [:],
            failedSpecs: [AppID: Spec] = [:],
            defaultOutputDevice: AudioDeviceID?,
            captureAuthorized: Bool,
            now: TimeInterval
        ) {
            self.groups = groups
            self.volumes = volumes
            self.routes = routes
            self.duckingGain = duckingGain
            self.taps = taps
            self.timelines = timelines
            self.failedSpecs = failedSpecs
            self.defaultOutputDevice = defaultOutputDevice
            self.captureAuthorized = captureAuthorized
            self.now = now
        }
    }

    public enum Action: Equatable, Sendable {
        case create(AppID, Spec, gain: Float, duck: Float = 1)
        case rebuild(AppID, Spec, gain: Float, duck: Float = 1)
        case updateProcesses(AppID, Set<AudioObjectID>)
        case setGain(AppID, Float)
        case setDuck(AppID, Float)
        case start(AppID)
        case stop(AppID)
        case destroy(AppID)
    }

    public struct Plan: Equatable, Sendable {
        public var actions: [Action] = []
        public var timelines: [AppID: Timeline] = [:]
        /// Apps in a call right now.
        public var calls: Set<AppID> = []
        /// When the plan should be re-evaluated even if nothing else changes.
        public var nextDeadline: TimeInterval?

        mutating func schedule(at deadline: TimeInterval) {
            nextDeadline = min(nextDeadline ?? deadline, deadline)
        }
    }

    /// macOS services that carry calls for apps: FaceTime and iPhone calls run in avconferenced.
    public static let callServices: Set<AppID> = ["exe:/usr/libexec/avconferenced"]

    public let policy: Policy

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    public func plan(_ input: Input) -> Plan {
        var plan = Plan()
        plan.calls = Self.calls(in: input.groups)
        let groups = input.groups.sorted { $0.id < $1.id }
        let liveIDs = Set(groups.map(\.id))

        for group in groups {
            planGroup(group, input: input, calls: plan.calls, into: &plan)
        }
        for id in input.taps.keys.sorted() where !liveIDs.contains(id) {
            plan.actions.append(.destroy(id))
        }
        return plan
    }

    /// A call is an app that records and plays at the same time: Zoom, Teams, Meet in a browser, FaceTime.
    /// Dictation apps only record and Siri is a system service, so neither counts.
    public static func calls(in groups: [Group]) -> Set<AppID> {
        Set(groups.lazy.filter { group in
            group.isCapturing && group.isPlaying && (group.kind == .application || callServices.contains(group.id))
        }.map(\.id))
    }

    /// The app's own device when it plays somewhere other than the default output; otherwise the default.
    public static func outputDevice(for group: Group, defaultDevice: AudioDeviceID?) -> AudioDeviceID? {
        if let defaultDevice, group.outputDevices.isEmpty || group.outputDevices.contains(defaultDevice) {
            return defaultDevice
        }
        return group.outputDevices.first ?? defaultDevice
    }

    // MARK: - Per app

    private func planGroup(_ group: Group, input: Input, calls: Set<AppID>, into plan: inout Plan) {
        let volume = input.volumes[group.id] ?? .unity
        let natural = Self.outputDevice(for: group, defaultDevice: input.defaultOutputDevice)
        let route = input.routes[group.id]
        let target = route ?? natural
        let tap = input.taps[group.id]

        let isDucked = input.duckingGain != nil && !calls.isEmpty && !calls.contains(group.id) && (group.isPlaying || tap != nil)
        let duck = isDucked ? input.duckingGain ?? 1 : 1
        let needsRoute = route != nil && route != natural
        let wantsTap = input.captureAuthorized && target != nil && (!volume.isNeutral || duck < 1 || needsRoute)

        guard let tap else {
            guard wantsTap, let target else { return }
            planMissingTap(group, spec: Spec(processObjects: group.processObjects, deviceID: target), volume: volume, duck: duck, input: input, into: &plan)
            return
        }
        guard input.captureAuthorized, let target else {
            plan.actions.append(.destroy(group.id))
            return
        }

        var timeline = input.timelines[group.id] ?? Timeline()
        if !wantsTap {
            // Lingering is only seamless on the device the app is heading back to.
            if tap.spec.deviceID == target {
                planNeutralTap(group.id, tap: tap, timeline: &timeline, now: input.now, into: &plan)
            } else {
                plan.actions.append(.destroy(group.id))
            }
            return
        }
        timeline.neutralSince = nil

        let spec = Spec(processObjects: group.processObjects, deviceID: target)
        if tap.spec.deviceID != target {
            plan.actions.append(.rebuild(group.id, spec, gain: volume.gain, duck: duck))
            if group.isPlaying {
                plan.actions.append(.start(group.id))
            }
            plan.timelines[group.id] = Timeline()
            return
        }
        if tap.spec.processObjects != group.processObjects {
            plan.actions.append(.updateProcesses(group.id, group.processObjects))
        }
        if tap.gain != volume.gain {
            plan.actions.append(.setGain(group.id, volume.gain))
        }
        if tap.duck != duck {
            plan.actions.append(.setDuck(group.id, duck))
        }
        planActivity(group, tap: tap, timeline: &timeline, now: input.now, into: &plan)
        plan.timelines[group.id] = timeline
    }

    private func planMissingTap(_ group: Group, spec: Spec, volume: AppVolume, duck: Float, input: Input, into plan: inout Plan) {
        guard input.failedSpecs[group.id] != spec else { return }
        plan.actions.append(.create(group.id, spec, gain: volume.gain, duck: duck))
        if group.isPlaying {
            plan.actions.append(.start(group.id))
        }
        plan.timelines[group.id] = Timeline()
    }

    private func planNeutralTap(_ id: AppID, tap: TapState, timeline: inout Timeline, now: TimeInterval, into plan: inout Plan) {
        let since = timeline.neutralSince ?? now
        let deadline = since + policy.neutralTeardownDelay
        guard now < deadline else {
            plan.actions.append(.destroy(id))
            return
        }
        if tap.gain != 1 {
            plan.actions.append(.setGain(id, 1))
        }
        if tap.duck != 1 {
            plan.actions.append(.setDuck(id, 1))
        }
        timeline.neutralSince = since
        plan.timelines[id] = timeline
        plan.schedule(at: deadline)
    }

    private func planActivity(_ group: Group, tap: TapState, timeline: inout Timeline, now: TimeInterval, into plan: inout Plan) {
        if group.isPlaying {
            timeline.idleSince = nil
            if !tap.isRunning {
                plan.actions.append(.start(group.id))
            }
            return
        }
        guard tap.isRunning else {
            timeline.idleSince = nil
            return
        }
        let since = timeline.idleSince ?? now
        let deadline = since + policy.idleStopDelay
        if now >= deadline {
            plan.actions.append(.stop(group.id))
            timeline.idleSince = nil
        } else {
            timeline.idleSince = since
            plan.schedule(at: deadline)
        }
    }
}
