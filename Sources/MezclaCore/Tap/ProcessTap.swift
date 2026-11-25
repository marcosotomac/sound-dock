public import CoreAudio
import Foundation
import MezclaDSP

/// Re-plays one app's audio at a different volume.
///
/// The pipeline is: a muted process tap captures the app's mix → a private aggregate device pairs that
/// tap with the real output device → an IOProc applies gain and writes to the output. Everything is
/// private to this process, so the HAL tears it down (and un-mutes the app) even if Mezcla crashes.
///
/// Lifetime is the resource lifetime: creating a `ProcessTap` builds the pipeline, releasing it destroys it.
public final class ProcessTap {
    public struct Configuration: Sendable {
        public var processObjects: [AudioObjectID]
        public var outputDevice: AudioDevice
        public var gain: Float
        /// Gain the first audio is rendered at before gliding to `gain`. When an app that is already
        /// playing gets a tap, starting at unity (the level it was audible at) makes the change a fade.
        public var startGain: Float?
        /// Ducking gain to glide to; see `ProcessTap.duck`.
        public var duck: Float

        public init(processObjects: [AudioObjectID], outputDevice: AudioDevice, gain: Float, startGain: Float? = nil, duck: Float = 1) {
            self.processObjects = processObjects
            self.outputDevice = outputDevice
            self.gain = gain
            self.startGain = startGain
            self.duck = duck
        }
    }

    /// Stream layout of the aggregate device, useful for diagnostics.
    public struct Topology: Sendable, CustomStringConvertible {
        public let tapChannels: UInt32
        public let deviceInputStreams: Int
        public let aggregateInputStreams: Int
        public let aggregateOutputStreams: Int
        public let stereoPair: AudioDevice.StereoPair

        public var description: String {
            "tap \(tapChannels)ch, input streams \(aggregateInputStreams) (device \(deviceInputStreams)), "
                + "output streams \(aggregateOutputStreams), stereo \(stereoPair.left + 1)/\(stereoPair.right + 1)"
        }
    }

    /// Prefix of our private aggregate devices, so they can be told apart from user devices.
    public static let aggregateUIDPrefix = "dev.mezcla.aggregate."

    public let outputDevice: AudioDevice
    public let topology: Topology
    public private(set) var processObjects: [AudioObjectID]
    public private(set) var isRunning = false

    private let kernel: GainKernel
    private let tapID: AudioObjectID
    private let tapDescription: CATapDescription
    private let aggregateID: AudioObjectID
    private let ioProcID: AudioDeviceIOProcID

    public var aggregateDeviceID: AudioObjectID { aggregateID }

    public var gain: Float {
        get { kernel.gain }
        set { kernel.gain = newValue }
    }

    /// Lowers the app while a call is in progress, on top of `gain`. Ramps slowly in both directions.
    public var duck: Float {
        get { kernel.duck }
        set { kernel.duck = newValue }
    }

    public init(configuration: Configuration) throws(CoreAudioError) {
        var rollback: [() -> Void] = []
        var succeeded = false
        defer {
            if !succeeded { rollback.reversed().forEach { $0() } }
        }

        let kernel = GainKernel(startGain: configuration.startGain ?? configuration.gain, targetGain: configuration.gain)
        kernel.duck = configuration.duck

        let description = CATapDescription(stereoMixdownOfProcesses: configuration.processObjects)
        description.uuid = UUID()
        description.name = "Mezcla"
        description.isPrivate = true
        description.muteBehavior = .muted // Stay silent while our IOProc is idle; never leak full volume.

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try AudioHardwareCreateProcessTap(description, &tapID).check("Create process tap")
        rollback.append { AudioHardwareDestroyProcessTap(tapID) }

        guard let outputUID = configuration.outputDevice.uid else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "Read output device UID")
        }
        let aggregateID = try Self.createAggregateDevice(outputUID: outputUID, tapUUID: description.uuid)
        rollback.append { AudioHardwareDestroyAggregateDevice(aggregateID) }

        var ioProcID: AudioDeviceIOProcID?
        try AudioDeviceCreateIOProcID(aggregateID, MZGainKernelIOProc(), UnsafeMutableRawPointer(kernel.pointer), &ioProcID)
            .check("Create IOProc")
        guard let ioProcID else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "Create IOProc")
        }
        rollback.append { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }

        let topology = try Self.configureRouting(
            kernel: kernel, tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID, outputDevice: configuration.outputDevice
        )

        self.kernel = kernel
        self.tapID = tapID
        self.tapDescription = description
        self.aggregateID = aggregateID
        self.ioProcID = ioProcID
        self.outputDevice = configuration.outputDevice
        self.processObjects = configuration.processObjects
        self.topology = topology
        succeeded = true
    }

    deinit {
        stop()
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    public func start() throws(CoreAudioError) {
        guard !isRunning else { return }
        try AudioDeviceStart(aggregateID, ioProcID).check("Start aggregate device")
        isRunning = true
    }

    /// Stops rendering. The app stays muted (its audio only reaches the speakers through us).
    public func stop() {
        guard isRunning else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        isRunning = false
    }

    /// Retargets the tap in place, e.g. when an app spawns a new helper process that plays audio.
    public func updateProcesses(_ processObjects: [AudioObjectID]) throws(CoreAudioError) {
        tapDescription.processes = processObjects
        try AudioObjectIO.write(tapID, .init(kAudioTapPropertyDescription), tapDescription)
        self.processObjects = processObjects
    }

    // MARK: Diagnostics

    public func setMeteringEnabled(_ enabled: Bool) { kernel.setMeteringEnabled(enabled) }
    public func takePeak() -> Float { kernel.takePeak() }
    public var renderedCycles: UInt64 { kernel.cycleCount }

    // MARK: Construction

    private static func createAggregateDevice(outputUID: String, tapUUID: UUID) throws(CoreAudioError) -> AudioObjectID {
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mezcla",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try AudioHardwareCreateAggregateDevice(composition as CFDictionary, &id).check("Create aggregate device")
        return id
    }

    private static func configureRouting(
        kernel: GainKernel,
        tapID: AudioObjectID,
        aggregateID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        outputDevice: AudioDevice
    ) throws(CoreAudioError) -> Topology {
        let aggregate = AudioDevice(id: aggregateID)
        let format = try? AudioObjectIO.read(tapID, .init(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription())
        let tapChannels = max(format?.mChannelsPerFrame ?? 2, 1)
        let stereo = outputDevice.preferredStereoChannels ?? .init(left: 0, right: 1)
        if let sampleRate = aggregate.nominalSampleRate {
            kernel.setSampleRate(sampleRate)
        }
        kernel.setRouting(tapChannels: tapChannels, outputLeft: stereo.left, outputRight: stereo.right)

        // An aggregate built on a headset also exposes the headset microphone. Disable those streams for
        // our IOProc so the mic never turns on (and Bluetooth never drops to the low-quality call profile).
        let deviceInputStreams = outputDevice.streams(scope: kAudioObjectPropertyScopeInput).count
        let aggregateInputStreams = aggregate.streams(scope: kAudioObjectPropertyScopeInput).count
        if deviceInputStreams > 0, aggregateInputStreams > deviceInputStreams {
            let flags = (0..<aggregateInputStreams).map { UInt32($0 < deviceInputStreams ? 0 : 1) }
            try MZSetInputStreamUsage(aggregateID, ioProcID, flags, UInt32(flags.count)).check("Disable device input streams")
        }

        return Topology(
            tapChannels: tapChannels,
            deviceInputStreams: deviceInputStreams,
            aggregateInputStreams: aggregateInputStreams,
            aggregateOutputStreams: aggregate.streams(scope: kAudioObjectPropertyScopeOutput).count,
            stereoPair: stereo
        )
    }
}
