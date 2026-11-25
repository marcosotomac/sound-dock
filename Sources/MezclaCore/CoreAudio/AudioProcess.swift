public import CoreAudio

/// A process that has connected to Core Audio. Identity is read once; activity is read live.
public struct AudioProcess: Hashable, Sendable, Identifiable {
    public let id: AudioObjectID
    public let pid: pid_t?
    public let bundleID: String?

    public init(id: AudioObjectID) {
        self.id = id
        self.pid = try? AudioObjectIO.read(id, .init(kAudioProcessPropertyPID), initial: pid_t(-1))
        self.bundleID = (try? AudioObjectIO.readString(id, .init(kAudioProcessPropertyBundleID))).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// True while the process is running IO on an output device.
    public var isRunningOutput: Bool {
        ((try? AudioObjectIO.read(id, Self.isRunningOutputAddress, initial: UInt32(0))) ?? 0) != 0
    }

    /// True while the process is recording from an input device, such as a microphone.
    public var isRunningInput: Bool {
        ((try? AudioObjectIO.read(id, Self.isRunningInputAddress, initial: UInt32(0))) ?? 0) != 0
    }

    /// Devices the process is currently sending audio to.
    public var outputDeviceIDs: [AudioDeviceID] {
        (try? AudioObjectIO.readArray(id, Self.outputDevicesAddress, placeholder: AudioDeviceID(0))) ?? []
    }

    static let isRunningOutputAddress = AudioObjectPropertyAddress(kAudioProcessPropertyIsRunningOutput)
    static let isRunningInputAddress = AudioObjectPropertyAddress(kAudioProcessPropertyIsRunningInput)
    static let outputDevicesAddress = AudioObjectPropertyAddress(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
}
