public import CoreAudio
import Dispatch
import Foundation
import os

/// Observes Core Audio and keeps one `ProcessTap` per app that needs one: a custom volume, its own output
/// device, or ducking during a call.
///
/// Data flows one way: the UI sends `MixerCommand`s through `send(_:)` and receives `MixerSnapshot`s from
/// `snapshots`. The actor runs on its own serial queue, and Core Audio property listeners are delivered
/// on that same queue, so every callback is already isolated to the actor and no locks are needed.
/// Nothing is polled: work only happens when Core Audio reports a change or the user moves a slider.
public actor MixerEngine {
    public nonisolated let snapshots: AsyncStream<MixerSnapshot>

    private nonisolated let queue = DispatchSerialQueue(label: "dev.mezcla.engine", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private nonisolated let commandSink: AsyncStream<MixerCommand>.Continuation
    private nonisolated let snapshotSink: AsyncStream<MixerSnapshot>.Continuation
    private let commands: AsyncStream<MixerCommand>

    private static let log = Logger(subsystem: "dev.mezcla", category: "engine")

    private let planner: TapPlanner
    private let resolver: AppIdentityResolver
    private let ownPID = getpid()
    /// Other copies of Mezcla (a `--preview` window, a second build) are never listed either.
    private let ownBundleID = Bundle.main.bundleIdentifier

    // Inputs
    private var volumes: [AppID: AppVolume] = [:]
    private var routes: [AppID: String] = [:]
    private var duckingGain: Float?
    private var captureAuthorized = false

    // Observed state
    private var processes: [AudioObjectID: TrackedProcess] = [:]
    private var ignoredProcesses: Set<AudioObjectID> = []
    private var groups: [TapPlanner.Group] = []
    private var calls: Set<AppID> = []
    private var identities: [AppID: AppIdentity] = [:]
    private var outputDevices: [OutputDevice] = []
    private var defaultOutput: AudioDevice?
    private var systemVolume = SystemVolume.unavailable

    // Owned resources
    private var taps: [AppID: ProcessTap] = [:]
    private var timelines: [AppID: TapPlanner.Timeline] = [:]
    private var failedSpecs: [AppID: TapPlanner.Spec] = [:]
    private var issues: [AppID: TapIssue] = [:]
    private var systemListeners: [PropertyListener] = []
    private var volumeListeners: [PropertyListener] = []

    // Scheduling
    private var isStarted = false
    private var refreshScheduled = false
    private var commandTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var lastSnapshot: MixerSnapshot?

    public init(planner: TapPlanner = TapPlanner()) {
        self.planner = planner
        self.resolver = AppIdentityResolver(bundles: BundleMetadataCache())
        (commands, commandSink) = AsyncStream.makeStream(of: MixerCommand.self)
        (snapshots, snapshotSink) = AsyncStream.makeStream(of: MixerSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        commandSink.finish()
        snapshotSink.finish()
    }

    /// Enqueues a command. Safe to call from any thread; commands are applied in order.
    public nonisolated func send(_ command: MixerCommand) {
        commandSink.yield(command)
    }

    public func start(settings: MixerSettings) {
        guard !isStarted else { return }
        isStarted = true
        volumes = settings.volumes.filter { !$0.value.isNeutral }
        routes = settings.routes
        duckingGain = settings.duckingGain
        captureAuthorized = settings.captureAuthorized

        installSystemListeners()
        reloadDevices()
        refresh()

        commandTask = Task { [commands] in
            for await command in commands {
                handle(command)
            }
        }
    }

    /// Releases every tap, which un-mutes the apps immediately.
    public func stop() {
        commandTask?.cancel()
        deadlineTask?.cancel()
        taps.removeAll()
        processes.removeAll()
        systemListeners.removeAll()
        volumeListeners.removeAll()
        isStarted = false
    }

    // MARK: - Commands

    private func handle(_ command: MixerCommand) {
        switch command {
        case let .setVolume(volume, id):
            volumes[id] = volume.isNeutral ? nil : volume
            reconcile()
        case let .setOutputRoute(uid, id):
            routes[id] = uid
            reconcile()
        case let .setDucking(gain):
            duckingGain = gain
            reconcile()
        case let .setCaptureAuthorized(authorized):
            guard authorized != captureAuthorized else { return }
            captureAuthorized = authorized
            failedSpecs.removeAll()
            reconcile()
        case let .setSystemVolume(level):
            perform("set system volume") { try defaultOutput?.setMainVolume(level) }
        case let .setSystemMuted(muted):
            perform("set system mute") { try defaultOutput?.setMuted(muted) }
        case let .selectOutputDevice(id):
            perform("select output device") { try AudioSystem.setDefaultOutputDevice(AudioDevice(id: id)) }
        case .rebuildTaps:
            taps.removeAll()
            timelines.removeAll()
            failedSpecs.removeAll()
            issues.removeAll()
            reloadDevices()
            refresh()
        }
    }

    // MARK: - Observation

    private func installSystemListeners() {
        systemListeners = [
            listen(AudioSystem.object, AudioSystem.processListAddress) { $0.setNeedsRefresh() },
            listen(AudioSystem.object, AudioSystem.devicesAddress) { $0.devicesDidChange() },
            listen(AudioSystem.object, AudioSystem.defaultOutputAddress) { $0.devicesDidChange() },
        ].compactMap { $0 }
    }

    private func listen(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ handler: @escaping @Sendable (isolated MixerEngine) -> Void
    ) -> PropertyListener? {
        PropertyListener(object: object, address: address, queue: queue) { [weak self] in
            // Listeners run on `queue`, which is this actor's executor.
            self?.assumeIsolated(handler)
        }
    }

    private func devicesDidChange() {
        reloadDevices()
        setNeedsRefresh()
    }

    /// Coalesces bursts of notifications (an app launching fires several) into one refresh.
    private func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            refreshScheduled = false
            refresh()
        }
    }

    private func reloadDevices() {
        defaultOutput = AudioSystem.defaultOutputDevice()
        outputDevices = AudioSystem.devices().compactMap { device in
            guard device.hasOutput, !device.isHidden,
                  let uid = device.uid, !uid.hasPrefix(ProcessTap.aggregateUIDPrefix)
            else { return nil }
            return OutputDevice(id: device.id, uid: uid, name: device.name ?? uid, transport: .init(coreAudioValue: device.transportType))
        }
        volumeListeners = defaultOutput.map { device in
            AudioDevice.volumeChangeAddresses.compactMap { address in
                listen(device.id, address) { $0.systemVolumeDidChange() }
            }
        } ?? []
        readSystemVolume()
    }

    private func systemVolumeDidChange() {
        readSystemVolume()
        publish()
    }

    private func readSystemVolume() {
        guard let device = defaultOutput else {
            systemVolume = .unavailable
            return
        }
        systemVolume = SystemVolume(
            level: device.canSetMainVolume ? device.mainVolume : nil,
            isMuted: device.canMute ? device.isMuted : nil
        )
    }

    // MARK: - Processes

    private func refresh() {
        syncProcesses()
        reconcile()
    }

    private func syncProcesses() {
        let current = AudioSystem.processObjectIDs()
        let live = Set(current)
        processes = processes.filter { live.contains($0.key) }
        ignoredProcesses.formIntersection(live)

        for id in current where processes[id] == nil && !ignoredProcesses.contains(id) {
            let process = AudioProcess(id: id)
            guard let pid = process.pid, pid > 0, pid != ownPID, ownBundleID == nil || process.bundleID != ownBundleID else {
                ignoredProcesses.insert(id)
                continue
            }
            let identity = resolver.resolve(SystemProcessFacts.facts(pid: pid, coreAudioBundleID: process.bundleID))
            let addresses = [AudioProcess.isRunningOutputAddress, AudioProcess.isRunningInputAddress, AudioProcess.outputDevicesAddress]
            let listeners = addresses.compactMap {
                listen(id, $0) { $0.setNeedsRefresh() }
            }
            processes[id] = TrackedProcess(process: process, identity: identity, listeners: listeners)
        }
        for id in processes.keys {
            processes[id]?.reloadActivity()
        }
    }

    private func makeGroups() -> [TapPlanner.Group] {
        let ownDevices = Set(taps.values.map(\.aggregateDeviceID))
        var identities: [AppID: AppIdentity] = [:]
        var groups: [AppID: TapPlanner.Group] = [:]

        for tracked in processes.values {
            let id = tracked.identity.id
            identities[id] = tracked.identity
            var group = groups[id] ?? TapPlanner.Group(id: id, kind: tracked.identity.kind, processObjects: [], isPlaying: false, outputDevices: [])
            group.processObjects.insert(tracked.process.id)
            group.isPlaying = group.isPlaying || tracked.isRunningOutput
            group.isCapturing = group.isCapturing || tracked.isRunningInput
            for device in tracked.outputDevices where !ownDevices.contains(device) && !group.outputDevices.contains(device) {
                group.outputDevices.append(device)
            }
            groups[id] = group
        }
        self.identities = identities
        return groups.values.sorted { $0.id < $1.id }
    }

    // MARK: - Reconciliation

    private func reconcile() {
        groups = makeGroups()
        let plan = planner.plan(TapPlanner.Input(
            groups: groups,
            volumes: volumes,
            routes: routes.compactMapValues { uid in outputDevices.first { $0.uid == uid }?.id },
            duckingGain: duckingGain,
            taps: taps.mapValues(\.plannerState),
            timelines: timelines,
            failedSpecs: failedSpecs,
            defaultOutputDevice: defaultOutput?.id,
            captureAuthorized: captureAuthorized,
            now: ProcessInfo.processInfo.systemUptime
        ))
        timelines = plan.timelines
        calls = plan.calls
        plan.actions.forEach(apply)
        scheduleReconcile(at: plan.nextDeadline)
        publish()
    }

    private func apply(_ action: TapPlanner.Action) {
        Self.log.debug("Applying \(String(describing: action), privacy: .public)")
        switch action {
        case let .create(id, spec, gain, duck):
            createTap(id, spec: spec, gain: gain, duck: duck)
        case let .rebuild(id, spec, gain, duck):
            taps[id] = nil
            createTap(id, spec: spec, gain: gain, duck: duck)
        case let .updateProcesses(id, processObjects):
            guard let tap = taps[id] else { return }
            do {
                try tap.updateProcesses(processObjects.sorted())
            } catch {
                Self.log.notice("Rebuilding tap for \(id, privacy: .public): \(error, privacy: .public)")
                taps[id] = nil
                createTap(id, spec: .init(processObjects: processObjects, deviceID: tap.outputDevice.id), gain: tap.gain, duck: tap.duck)
                setNeedsRefresh()
            }
        case let .setGain(id, gain):
            taps[id]?.gain = gain
        case let .setDuck(id, duck):
            taps[id]?.duck = duck
        case let .start(id):
            guard let tap = taps[id] else { return }
            do {
                try tap.start()
            } catch {
                Self.log.error("Starting tap for \(id, privacy: .public) failed: \(error, privacy: .public)")
                issues[id] = .failed(error)
            }
        case let .stop(id):
            taps[id]?.stop()
        case let .destroy(id):
            taps[id] = nil
            timelines[id] = nil
            issues[id] = nil
        }
    }

    private func createTap(_ id: AppID, spec: TapPlanner.Spec, gain: Float, duck: Float) {
        let device = AudioDevice(id: spec.deviceID)
        // An app that is audible right now fades from where it was instead of jumping.
        let isAudible = groups.contains { $0.id == id && $0.isPlaying }
        let configuration = ProcessTap.Configuration(
            processObjects: spec.processObjects.sorted(), outputDevice: device, gain: gain, startGain: isAudible ? 1 : nil, duck: duck
        )
        do {
            taps[id] = try ProcessTap(configuration: configuration)
            failedSpecs[id] = nil
            issues[id] = nil
        } catch {
            Self.log.error("Creating tap for \(id, privacy: .public) on \(device.name ?? "?", privacy: .public) failed: \(error, privacy: .public)")
            failedSpecs[id] = spec
            issues[id] = .unsupportedOutput(deviceName: device.name)
        }
    }

    private func scheduleReconcile(at deadline: TimeInterval?) {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        deadlineTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            reconcile()
        }
    }

    private func perform(_ operation: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Self.log.error("Could not \(operation, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Publishing

    private func publish() {
        let apps = groups.compactMap { group -> AudioApp? in
            guard let identity = identities[group.id] else { return nil }
            return AudioApp(
                id: group.id,
                name: identity.name,
                path: identity.path,
                kind: identity.kind,
                isPlaying: group.isPlaying,
                isUsingMicrophone: group.isCapturing,
                issue: volumes[group.id] == nil && routes[group.id] == nil ? nil : issues[group.id]
            )
        }
        let snapshot = MixerSnapshot(
            apps: apps,
            outputDevices: outputDevices,
            defaultOutputID: defaultOutput?.id,
            systemVolume: systemVolume,
            calls: calls.sorted()
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        snapshotSink.yield(snapshot)
    }
}

/// A process the engine is watching, with its listeners kept alive alongside it.
private struct TrackedProcess {
    let process: AudioProcess
    let identity: AppIdentity
    let listeners: [PropertyListener]
    private(set) var isRunningOutput = false
    private(set) var isRunningInput = false
    private(set) var outputDevices: [AudioDeviceID] = []

    init(process: AudioProcess, identity: AppIdentity, listeners: [PropertyListener]) {
        self.process = process
        self.identity = identity
        self.listeners = listeners
    }

    mutating func reloadActivity() {
        isRunningOutput = process.isRunningOutput
        isRunningInput = process.isRunningInput
        outputDevices = process.outputDeviceIDs
    }
}

private extension ProcessTap {
    var plannerState: TapPlanner.TapState {
        TapPlanner.TapState(
            spec: .init(processObjects: Set(processObjects), deviceID: outputDevice.id),
            isRunning: isRunning,
            gain: gain,
            duck: duck
        )
    }
}
