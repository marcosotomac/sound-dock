import MezclaCore

/// Composition root: the one place that knows the concrete implementations.
@MainActor
enum AppComposition {
    struct Services {
        let model: MixerViewModel
        let safari: SafariIntegration
    }

    static func makeServices() -> Services {
        let bridge = BrowserBridge()
        let model = MixerViewModel(
            engine: MixerEngine(),
            browserBridge: bridge,
            store: UserDefaultsSettingsStore(),
            permission: SystemAudioCapturePermission(),
            loginItem: MainAppLoginItem(),
            icons: AppIconProvider()
        )
        return Services(model: model, safari: SafariIntegration(bridge: bridge))
    }

    static func makeViewModel() -> MixerViewModel {
        makeServices().model
    }
}
