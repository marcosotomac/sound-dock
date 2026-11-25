/// The volume the user chose for one app. `level` is the slider position: 1 means 100 %.
public struct AppVolume: Codable, Hashable, Sendable {
    public static let unity = AppVolume()
    public static let maximumBoostLevel = 1.5

    public var level: Double
    public var isMuted: Bool

    public init(level: Double = 1, isMuted: Bool = false) {
        self.level = level
        self.isMuted = isMuted
    }

    /// A neutral volume needs no processing at all, so the app plays untouched.
    public var isNeutral: Bool {
        !isMuted && abs(level - 1) < 0.005
    }

    /// Linear amplitude applied to the samples.
    public var gain: Float {
        isMuted ? 0 : VolumeCurve.gain(forLevel: level)
    }
}

/// Maps slider positions to amplitude.
public enum VolumeCurve {
    /// A square law tracks perceived loudness far better than a linear slider:
    /// 50 % ≈ −12 dB, 71 % ≈ −6 dB, 150 % ≈ +7 dB.
    public static func gain(forLevel level: Double) -> Float {
        let clamped = min(max(level, 0), AppVolume.maximumBoostLevel)
        return Float(clamped * clamped)
    }
}
