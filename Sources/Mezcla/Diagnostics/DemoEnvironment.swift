import AppKit
import MezclaCore

/// Stand-ins used by `--preview demo`: the real UI with a fixed, representative state and no side effects.
enum DemoEnvironment {
    @MainActor
    static func makeViewModel() -> MixerViewModel {
        MixerViewModel(
            engine: DemoMixer(snapshot: snapshot),
            browserBridge: DemoBrowserBridge(snapshot: browsers),
            bluetooth: DemoBluetooth(),
            store: InMemorySettingsStore(
                volumes: [
                    "net.imput.helium": AppVolume(level: 0.9),
                    "net.whatsapp.WhatsApp": AppVolume(level: 0.8, isMuted: true),
                    "md.obsidian": AppVolume(level: 0.45),
                ],
                routes: ["com.apple.Music": OutputRoute(deviceUID: "jbl-flip", deviceName: "JBL Flip 5")],
                preferences: Preferences(allowsBoost: true, showsIdleApps: true)
            ),
            permission: GrantedPermission(),
            loginItem: DisabledLoginItem(),
            icons: AppIconProvider()
        )
    }

    private static var snapshot: MixerSnapshot {
        func app(_ id: AppID, _ name: String, _ path: String, playing: Bool, microphone: Bool = false) -> AudioApp {
            AudioApp(id: id, name: name, path: path, kind: .application, isPlaying: playing, isUsingMicrophone: microphone, issue: nil)
        }
        return MixerSnapshot(
            apps: [
                app("com.apple.FaceTime", "FaceTime", "/System/Applications/FaceTime.app", playing: true, microphone: true),
                app("net.imput.helium", "Helium", "/Applications/Helium.app", playing: true),
                app("com.apple.Music", "Music", "/System/Applications/Music.app", playing: true),
                app("org.betterwispr.app", "BetterWispr", "/Applications/BetterWispr.app", playing: false, microphone: true),
                app("net.whatsapp.WhatsApp", "WhatsApp", "/Applications/WhatsApp.app", playing: false),
                app("md.obsidian", "Obsidian", "/Applications/Obsidian.app", playing: false),
            ],
            outputDevices: [
                OutputDevice(id: 1, uid: "builtin", name: "MacBook Pro Speakers", transport: .builtIn),
                OutputDevice(id: 2, uid: "freebuds", name: "HUAWEI FreeBuds Pro 5", transport: .bluetooth),
                OutputDevice(id: 3, uid: "jbl-flip", name: "JBL Flip 5", transport: .bluetooth),
                OutputDevice(id: 4, uid: "airpods", name: "Marco’s AirPods Pro", transport: .bluetooth),
            ],
            defaultOutputID: 2,
            systemVolume: SystemVolume(level: 0.62, isMuted: false),
            calls: ["com.apple.FaceTime"]
        )
    }

    @MainActor
    private static var browsers: BrowserSnapshot {
        func tab(_ id: Int, _ title: String, _ host: String, icon: Data?, audible: Bool = true, level: Double = 1, muted: Bool = false) -> BrowserTab {
            BrowserTab(
                id: .init(appID: "net.imput.helium", tabID: id), title: title, url: URL(string: "https://\(host)/"),
                favicon: icon, isAudible: audible, isMuted: muted, level: level
            )
        }
        let video = symbolPNG("play.rectangle.fill", color: .systemRed)
        let stream = symbolPNG("dot.radiowaves.left.and.right", color: .systemPurple)
        return BrowserSnapshot(connectedApps: ["net.imput.helium"], tabs: [
            tab(1, "Lo-fi beats to study to", "youtube.com", icon: video, level: 0.35),
            tab(2, "Apple Event — Keynote", "youtube.com", icon: video, level: 1.3),
            tab(3, "Live: Late night coding", "twitch.tv", icon: stream, muted: true),
        ])
    }

    /// Stand-in favicons drawn from SF Symbols.
    @MainActor
    private static func symbolPNG(_ name: String, color: NSColor) -> Data? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold).applying(.init(hierarchicalColor: color))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size, flipped: false) { rect in
            let fitted = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2, width: fitted.width, height: fitted.height))
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Batteries for the demo's Bluetooth devices.
private struct DemoBluetooth: BluetoothDetailsProviding {
    func details(for devices: [OutputDevice]) async -> [String: BluetoothDetails] {
        [
            "freebuds": BluetoothDetails(minorType: "Headphones", battery: .init(left: 80, right: 75, chargingCase: 100)),
            "jbl-flip": BluetoothDetails(minorType: "Speaker", battery: .init(main: 64)),
            "airpods": BluetoothDetails(minorType: "Headphones", vendorID: 0x004C, productID: 0x200E, battery: .init(left: 18, right: 22, chargingCase: 90)),
        ]
    }
}

private final class DemoMixer: MixerControlling {
    let snapshots: AsyncStream<MixerSnapshot>

    init(snapshot: MixerSnapshot) {
        snapshots = AsyncStream { $0.yield(snapshot) }
    }

    func start(settings: MixerSettings) async {}
    func send(_ command: MixerCommand) {}
}

private final class DemoBrowserBridge: BrowserBridging {
    let snapshots: AsyncStream<BrowserSnapshot>

    init(snapshot: BrowserSnapshot) {
        snapshots = AsyncStream { $0.yield(snapshot) }
    }

    func start() async {}
    func send(_ command: BrowserCommand) {}
}

private final class InMemorySettingsStore: SettingsStore {
    private var volumes: [AppID: AppVolume]
    private var routes: [AppID: OutputRoute]
    private var preferences: Preferences

    init(volumes: [AppID: AppVolume], routes: [AppID: OutputRoute], preferences: Preferences) {
        self.volumes = volumes
        self.routes = routes
        self.preferences = preferences
    }

    func loadVolumes() -> [AppID: AppVolume] { volumes }
    func saveVolumes(_ volumes: [AppID: AppVolume]) { self.volumes = volumes }
    func loadRoutes() -> [AppID: OutputRoute] { routes }
    func saveRoutes(_ routes: [AppID: OutputRoute]) { self.routes = routes }
    func loadPreferences() -> Preferences { preferences }
    func savePreferences(_ preferences: Preferences) { self.preferences = preferences }
}

private struct GrantedPermission: AudioCapturePermissionProviding {
    func status() -> CapturePermissionStatus { .authorized }
    func request() async -> Bool { true }
}

private struct DisabledLoginItem: LoginItemControlling {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
}
