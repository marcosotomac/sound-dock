public import CoreAudio

/// Everything the engine needs to know about the user's choices when it starts.
public struct MixerSettings: Sendable {
    public var volumes: [AppID: AppVolume]
    /// Output device UID per app.
    public var routes: [AppID: String]
    public var duckingGain: Float?
    public var captureAuthorized: Bool

    public init(volumes: [AppID: AppVolume], routes: [AppID: String], duckingGain: Float?, captureAuthorized: Bool) {
        self.volumes = volumes
        self.routes = routes
        self.duckingGain = duckingGain
        self.captureAuthorized = captureAuthorized
    }
}

/// Intents sent from the UI to the engine. Delivered in order through a single stream.
public enum MixerCommand: Sendable {
    case setVolume(AppVolume, for: AppID)
    /// Sends an app to a specific output device (by UID), or back to the system default with `nil`.
    case setOutputRoute(String?, for: AppID)
    /// Gain for other apps while a call is in progress; `nil` turns ducking off.
    case setDucking(Float?)
    case setCaptureAuthorized(Bool)
    case setSystemVolume(Float)
    case setSystemMuted(Bool)
    case selectOutputDevice(AudioDeviceID)
    /// Tears down and rebuilds every tap, e.g. after the Mac wakes from sleep.
    case rebuildTaps
}
