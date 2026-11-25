import Foundation
import MezclaCore

struct Preferences: Codable, Equatable {
    /// Ducking levels offered in Settings, as slider positions.
    static let duckingLevels: [Double] = [0.15, 0.3, 0.5]

    var allowsBoost = false
    var showsIdleApps = true
    var hidesTabControlSuggestion = false
    var ducksDuringCalls = true
    /// How far other apps go down during a call, as a slider position (30 % ≈ −21 dB).
    var duckingLevel = 0.3

    init(
        allowsBoost: Bool = false,
        showsIdleApps: Bool = true,
        hidesTabControlSuggestion: Bool = false,
        ducksDuringCalls: Bool = true,
        duckingLevel: Double = 0.3
    ) {
        self.allowsBoost = allowsBoost
        self.showsIdleApps = showsIdleApps
        self.hidesTabControlSuggestion = hidesTabControlSuggestion
        self.ducksDuringCalls = ducksDuringCalls
        self.duckingLevel = duckingLevel
    }

    /// Tolerates preferences saved by older versions, which lack newer keys.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        allowsBoost = try container.decodeIfPresent(Bool.self, forKey: .allowsBoost) ?? defaults.allowsBoost
        showsIdleApps = try container.decodeIfPresent(Bool.self, forKey: .showsIdleApps) ?? defaults.showsIdleApps
        hidesTabControlSuggestion = try container.decodeIfPresent(Bool.self, forKey: .hidesTabControlSuggestion)
            ?? defaults.hidesTabControlSuggestion
        ducksDuringCalls = try container.decodeIfPresent(Bool.self, forKey: .ducksDuringCalls) ?? defaults.ducksDuringCalls
        duckingLevel = try container.decodeIfPresent(Double.self, forKey: .duckingLevel) ?? defaults.duckingLevel
    }

    /// Gain the engine applies to other apps during calls, or `nil` when ducking is off.
    var duckingGain: Float? {
        ducksDuringCalls ? VolumeCurve.gain(forLevel: duckingLevel) : nil
    }
}

/// An app's chosen output. The name is kept so a disconnected device can still be shown by name.
struct OutputRoute: Codable, Equatable {
    var deviceUID: String
    var deviceName: String
}

/// Persists the user's choices. Abstracted so the view model can be exercised without UserDefaults.
protocol SettingsStore {
    func loadVolumes() -> [AppID: AppVolume]
    func saveVolumes(_ volumes: [AppID: AppVolume])
    func loadRoutes() -> [AppID: OutputRoute]
    func saveRoutes(_ routes: [AppID: OutputRoute])
    func loadPreferences() -> Preferences
    func savePreferences(_ preferences: Preferences)
}

final class UserDefaultsSettingsStore: SettingsStore {
    private enum Key {
        static let volumes = "volumes.v1"
        static let routes = "routes.v1"
        static let preferences = "preferences.v1"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadVolumes() -> [AppID: AppVolume] {
        decode([AppID: AppVolume].self, forKey: Key.volumes) ?? [:]
    }

    func saveVolumes(_ volumes: [AppID: AppVolume]) {
        encode(volumes, forKey: Key.volumes)
    }

    func loadRoutes() -> [AppID: OutputRoute] {
        decode([AppID: OutputRoute].self, forKey: Key.routes) ?? [:]
    }

    func saveRoutes(_ routes: [AppID: OutputRoute]) {
        encode(routes, forKey: Key.routes)
    }

    func loadPreferences() -> Preferences {
        decode(Preferences.self, forKey: Key.preferences) ?? Preferences()
    }

    func savePreferences(_ preferences: Preferences) {
        encode(preferences, forKey: Key.preferences)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? decoder.decode(type, from: $0) }
    }

    private func encode(_ value: some Encodable, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
