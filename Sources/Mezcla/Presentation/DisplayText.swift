import MezclaCore

/// User-facing names for processes that have no app bundle.
enum DisplayName {
    private static let knownExecutables: [String: String] = [
        "systemsoundserverd": String(localized: "System Sounds"),
        "SpeechSynthesisServer": String(localized: "System Voice"),
        "com.apple.speech.speechsynthesisd": String(localized: "System Voice"),
        "NotificationCenter": String(localized: "Notifications"),
    ]

    static func of(_ app: AudioApp) -> String {
        knownExecutables[app.name] ?? app.name
    }

    static func isRecognized(_ app: AudioApp) -> Bool {
        knownExecutables[app.name] != nil
    }

    /// macOS services borrow the System Settings icon rather than the generic executable one.
    static func iconPath(of app: AudioApp) -> String? {
        app.kind == .systemService ? "/System/Applications/System Settings.app" : app.path
    }
}

extension TapIssue {
    var message: String {
        switch self {
        case let .unsupportedOutput(deviceName):
            if let deviceName {
                String(localized: "This app’s volume can’t be changed on “\(deviceName)”.")
            } else {
                String(localized: "This app’s volume can’t be changed on the current output.")
            }
        case let .failed(error):
            String(localized: "Core Audio rejected the change (\(error.description)).")
        }
    }
}
