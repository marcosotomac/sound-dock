public import CoreAudio

/// Everything the UI needs to draw, published by the engine whenever it changes.
public struct MixerSnapshot: Equatable, Sendable {
    public var apps: [AudioApp]
    public var outputDevices: [OutputDevice]
    public var defaultOutputID: AudioDeviceID?
    public var systemVolume: SystemVolume
    /// Apps in a call right now (recording and playing at the same time).
    public var calls: [AppID]

    public init(apps: [AudioApp], outputDevices: [OutputDevice], defaultOutputID: AudioDeviceID?, systemVolume: SystemVolume, calls: [AppID] = []) {
        self.apps = apps
        self.outputDevices = outputDevices
        self.defaultOutputID = defaultOutputID
        self.systemVolume = systemVolume
        self.calls = calls
    }

    public static let empty = MixerSnapshot(apps: [], outputDevices: [], defaultOutputID: nil, systemVolume: .unavailable)
}

/// An app that is connected to Core Audio.
public struct AudioApp: Identifiable, Hashable, Sendable {
    public let id: AppID
    public let name: String
    /// Path to the `.app` bundle or executable, used for the icon.
    public let path: String?
    public let kind: AppIdentity.Kind
    public let isPlaying: Bool
    /// True while the app records from the microphone (or another input).
    public let isUsingMicrophone: Bool
    /// Set when the app's volume cannot be controlled right now.
    public let issue: TapIssue?

    public init(
        id: AppID, name: String, path: String?, kind: AppIdentity.Kind,
        isPlaying: Bool, isUsingMicrophone: Bool = false, issue: TapIssue?
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.isPlaying = isPlaying
        self.isUsingMicrophone = isUsingMicrophone
        self.issue = issue
    }
}

public enum TapIssue: Hashable, Sendable {
    /// The output device cannot be part of an aggregate device (some AirPlay receivers, for example).
    case unsupportedOutput(deviceName: String?)
    case failed(CoreAudioError)
}

public struct OutputDevice: Identifiable, Hashable, Sendable {
    public enum Transport: Hashable, Sendable {
        case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, thunderbolt, virtual, aggregate, other

        init(coreAudioValue value: UInt32) {
            switch value {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
            default: self = .other
            }
        }
    }

    public let id: AudioDeviceID
    /// Stable across reconnects and reboots, unlike `id`; used to remember per-app outputs.
    public let uid: String
    public let name: String
    public let transport: Transport

    public init(id: AudioDeviceID, uid: String, name: String, transport: Transport) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }
}

/// Volume of the default output device. `nil` members mean the device does not offer that control.
public struct SystemVolume: Equatable, Sendable {
    public var level: Float?
    public var isMuted: Bool?

    public init(level: Float?, isMuted: Bool?) {
        self.level = level
        self.isMuted = isMuted
    }

    public static let unavailable = SystemVolume(level: nil, isMuted: nil)
}
