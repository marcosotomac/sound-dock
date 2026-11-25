public import CoreAudio
import AudioToolbox // kAudioHardwareServiceDeviceProperty_VirtualMainVolume

/// A Core Audio device. A thin value type: every property is read live from the HAL.
public struct AudioDevice: Hashable, Sendable, Identifiable {
    /// Zero-based channel indices of the stereo pair the user configured in Audio MIDI Setup.
    public struct StereoPair: Hashable, Sendable {
        public let left: UInt32
        public let right: UInt32
    }

    public let id: AudioDeviceID

    public init(id: AudioDeviceID) {
        self.id = id
    }

    public var uid: String? {
        try? AudioObjectIO.readString(id, .init(kAudioDevicePropertyDeviceUID))
    }

    public var name: String? {
        try? AudioObjectIO.readString(id, .init(kAudioObjectPropertyName))
    }

    public var transportType: UInt32 {
        (try? AudioObjectIO.read(id, .init(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
    }

    public var isHidden: Bool {
        ((try? AudioObjectIO.read(id, .init(kAudioDevicePropertyIsHidden), initial: UInt32(0))) ?? 0) != 0
    }

    public func streams(scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        (try? AudioObjectIO.readArray(id, .init(kAudioDevicePropertyStreams, scope: scope), placeholder: AudioStreamID(0))) ?? []
    }

    public var nominalSampleRate: Double? {
        try? AudioObjectIO.read(id, .init(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
    }

    public var hasOutput: Bool {
        !streams(scope: kAudioObjectPropertyScopeOutput).isEmpty
    }

    public var preferredStereoChannels: StereoPair? {
        let address = AudioObjectPropertyAddress(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        guard
            let channels = try? AudioObjectIO.readArray(id, address, placeholder: UInt32(0)),
            channels.count == 2, channels[0] > 0, channels[1] > 0
        else { return nil }
        return StereoPair(left: channels[0] - 1, right: channels[1] - 1)
    }
}

// MARK: - Output volume

extension AudioDevice {
    // The "virtual main volume" is what the volume keys drive. The HAL synthesizes it even for devices
    // that only expose per-channel controls, and it balances stereo channels the way the system does.
    private static let mainVolume = AudioObjectPropertyAddress(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput
    )
    private static let mute = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)

    /// Properties worth observing to notice volume or mute changes made elsewhere (keyboard, Control Center).
    static var volumeChangeAddresses: [AudioObjectPropertyAddress] {
        [mainVolume, mute] + [kAudioObjectPropertyElementMain, 1, 2].map {
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0)
        }
    }

    public var canSetMainVolume: Bool {
        AudioObjectIO.isSettable(id, Self.mainVolume)
    }

    public var mainVolume: Float? {
        try? AudioObjectIO.read(id, Self.mainVolume, initial: Float32(0))
    }

    public func setMainVolume(_ volume: Float) throws(CoreAudioError) {
        try AudioObjectIO.write(id, Self.mainVolume, Float32(min(max(volume, 0), 1)))
    }

    public var canMute: Bool {
        AudioObjectIO.isSettable(id, Self.mute)
    }

    public var isMuted: Bool? {
        (try? AudioObjectIO.read(id, Self.mute, initial: UInt32(0))).map { $0 != 0 }
    }

    public func setMuted(_ muted: Bool) throws(CoreAudioError) {
        try AudioObjectIO.write(id, Self.mute, UInt32(muted ? 1 : 0))
    }
}
