import AppKit
import CoreAudio
import MezclaCore
import Observation
import os

/// State and intents for the panel. Owns the user's volume choices and forwards them to the engine.
@MainActor
@Observable
final class MixerViewModel {
    private(set) var snapshot = MixerSnapshot.empty
    private(set) var volumes: [AppID: AppVolume]
    private(set) var routes: [AppID: OutputRoute]
    private(set) var permission: CapturePermissionStatus
    private(set) var launchesAtLogin: Bool
    private(set) var browsers = BrowserSnapshot.empty
    /// Bluetooth class and battery of connected outputs, keyed by Core Audio device UID.
    private(set) var bluetoothDetails: [String: BluetoothDetails] = [:]
    private var activity = PlaybackActivity()

    var preferences: Preferences {
        didSet { preferencesDidChange(from: oldValue) }
    }

    @ObservationIgnored let icons: AppIconProvider
    @ObservationIgnored weak var router: (any PanelRouting)?
    @ObservationIgnored private let engine: any MixerControlling
    @ObservationIgnored private let browserBridge: any BrowserBridging
    @ObservationIgnored private let bluetooth: any BluetoothDetailsProviding
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let permissionProvider: any AudioCapturePermissionProviding
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var browserTask: Task<Void, Never>?
    @ObservationIgnored private var activityExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var isRequestingPermission = false
    @ObservationIgnored private var knownOutputUIDs: Set<String>?
    @ObservationIgnored private var bluetoothTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "dev.mezcla", category: "ui")
    /// Slider positions this close to 100 % snap to it, so "back to normal" is easy to hit.
    private static let unitySnapDistance = 0.03

    init(
        engine: any MixerControlling,
        browserBridge: any BrowserBridging,
        bluetooth: any BluetoothDetailsProviding = SystemBluetoothDetails(),
        store: any SettingsStore,
        permission: any AudioCapturePermissionProviding,
        loginItem: any LoginItemControlling,
        icons: AppIconProvider
    ) {
        self.engine = engine
        self.browserBridge = browserBridge
        self.bluetooth = bluetooth
        self.store = store
        self.permissionProvider = permission
        self.loginItem = loginItem
        self.icons = icons
        self.volumes = store.loadVolumes().filter { !$0.value.isNeutral }
        self.routes = store.loadRoutes()
        self.preferences = store.loadPreferences()
        self.permission = permission.status()
        self.launchesAtLogin = loginItem.isEnabled
    }

    func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self, engine] in
            for await snapshot in engine.snapshots {
                self?.receive(snapshot)
            }
        }
        browserTask = Task { [weak self, browserBridge] in
            for await snapshot in browserBridge.snapshots {
                self?.browsers = snapshot
            }
        }
        let settings = MixerSettings(
            volumes: volumes,
            routes: routes.mapValues(\.deviceUID),
            duckingGain: preferences.duckingGain,
            captureAuthorized: permission == .authorized
        )
        Task { [engine] in await engine.start(settings: settings) }
        Task { [browserBridge] in await browserBridge.start() }

        if permission == .undetermined {
            requestPermission()
        }
    }

    private func receive(_ snapshot: MixerSnapshot) {
        let devicesChanged = snapshot.outputDevices != self.snapshot.outputDevices
        self.snapshot = snapshot
        if devicesChanged {
            outputDevicesDidChange(snapshot.outputDevices)
        }
        activity.update(with: snapshot.apps, now: .now)
        scheduleActivityExpiry()
    }

    private func scheduleActivityExpiry() {
        activityExpiryTask?.cancel()
        guard let expiry = activity.nextExpiry else { return }
        activityExpiryTask = Task { [weak self] in
            try? await Task.sleep(until: expiry, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            activity.expire(now: .now)
            scheduleActivityExpiry()
        }
    }

    // MARK: - Derived state

    /// Apps producing sound, or that did a moment ago.
    var playingApps: [AudioApp] {
        visibleApps.filter { activity.isActive($0.id) }
    }

    /// Apps that record from the microphone without playing, such as dictation tools.
    var microphoneOnlyApps: [AudioApp] {
        visibleApps.filter { $0.isUsingMicrophone && !activity.isActive($0.id) }
    }

    /// Apps that use audio but are quiet, so their volume can be set before they play.
    var idleApps: [AudioApp] {
        guard preferences.showsIdleApps else { return [] }
        return visibleApps.filter { $0.kind == .application && !activity.isActive($0.id) && !$0.isUsingMicrophone }
    }

    /// Names of the apps in a call while ducking is on, for the banner.
    var duckingCallNames: [String] {
        guard preferences.ducksDuringCalls else { return [] }
        return snapshot.calls.compactMap { id in snapshot.apps.first { $0.id == id }.map(DisplayName.of) }
    }

    var maximumLevel: Double {
        preferences.allowsBoost ? AppVolume.maximumBoostLevel : 1
    }

    var hasCustomVolumes: Bool {
        !volumes.isEmpty || !routes.isEmpty
    }

    var defaultOutputName: String {
        snapshot.outputDevices.first { $0.id == snapshot.defaultOutputID }?.name ?? String(localized: "No Output")
    }

    func volume(for id: AppID) -> AppVolume {
        volumes[id] ?? .unity
    }

    private var visibleApps: [AudioApp] {
        snapshot.apps
            .filter { isVisible($0) }
            .sorted { DisplayName.of($0).localizedStandardCompare(DisplayName.of($1)) == .orderedAscending }
    }

    /// Apps are listed whenever they use audio; agents and tools only while they make sound; macOS
    /// services only when they are something the user recognises, like system sounds.
    private func isVisible(_ app: AudioApp) -> Bool {
        switch app.kind {
        case .application: true
        case .backgroundApplication, .executable: activity.isActive(app.id) || app.isUsingMicrophone
        case .systemService: activity.isActive(app.id) && DisplayName.isRecognized(app)
        }
    }

    // MARK: - Output devices

    /// The glyph macOS would use for this output (AirPods, earbuds, speaker, TV…).
    func symbol(for device: OutputDevice) -> String {
        DeviceSymbol.name(for: device, details: bluetoothDetails[device.uid])
    }

    func battery(of device: OutputDevice) -> BluetoothDetails.Battery? {
        bluetoothDetails[device.uid]?.battery
    }

    /// All batteries of connected Bluetooth outputs, for the panel's battery row.
    /// Connected devices with a battery, other than the active output, whose battery the header already shows.
    var connectedBatteries: [(device: OutputDevice, battery: BluetoothDetails.Battery)] {
        snapshot.outputDevices.compactMap { device in
            device.id == snapshot.defaultOutputID ? nil : battery(of: device).map { (device, $0) }
        }
    }

    var defaultOutputDevice: OutputDevice? {
        snapshot.outputDevices.first { $0.id == snapshot.defaultOutputID }
    }

    /// Learns about newly connected devices and announces them, like iOS does for AirPods.
    private func outputDevicesDidChange(_ devices: [OutputDevice]) {
        let uids = Set(devices.map(\.uid))
        let arrived = knownOutputUIDs.map { uids.subtracting($0) } ?? [] // Nothing to announce at launch.
        knownOutputUIDs = uids
        loadBluetoothDetails(for: devices, announcing: arrived)
    }

    /// Reads Bluetooth class and battery for `devices`, then shows the connection card for `arrived` ones.
    private func loadBluetoothDetails(for devices: [OutputDevice], announcing arrived: Set<String>) {
        bluetoothTask?.cancel()
        guard devices.contains(where: { $0.transport == .bluetooth }) || !arrived.isEmpty else {
            bluetoothDetails = [:]
            return
        }
        bluetoothTask = Task { [weak self, bluetooth] in
            // Battery levels appear a moment after a headset connects.
            let details = await bluetooth.details(for: devices)
            guard let self, !Task.isCancelled else { return }
            bluetoothDetails = details
            for device in devices where arrived.contains(device.uid) && Self.announcesConnection(of: device) {
                router?.showConnected(device, symbol: symbol(for: device), battery: battery(of: device))
            }
        }
    }

    /// Headphones, speakers and displays coming and going; not virtual or aggregate plumbing.
    private static func announcesConnection(of device: OutputDevice) -> Bool {
        switch device.transport {
        case .bluetooth, .usb, .hdmi, .displayPort, .airPlay, .thunderbolt: true
        case .builtIn, .virtual, .aggregate, .other: false
        }
    }

    // MARK: - Per-app output

    enum RouteState: Equatable {
        case systemDefault
        case device(OutputDevice)
        /// Chosen device is not connected; the app plays on the default output meanwhile.
        case unavailable(name: String)
    }

    func routeState(for id: AppID) -> RouteState {
        guard let route = routes[id] else { return .systemDefault }
        if let device = snapshot.outputDevices.first(where: { $0.uid == route.deviceUID }) {
            return .device(device)
        }
        return .unavailable(name: route.deviceName)
    }

    /// `nil` sends the app back to the system output.
    func setOutput(_ device: OutputDevice?, for id: AppID) {
        routes[id] = device.map { OutputRoute(deviceUID: $0.uid, deviceName: $0.name) }
        store.saveRoutes(routes)
        engine.send(.setOutputRoute(device?.uid, for: id))
        if device != nil, permission == .undetermined {
            requestPermission()
        }
    }

    // MARK: - Browser tabs

    /// Tabs of one browser that are playing, just played, or have their own volume.
    func tabs(for appID: AppID) -> [BrowserTab] {
        browsers.tabs
            .filter { $0.id.appID == appID }
            .sorted { ($0.isAudible ? 0 : 1, $0.title) < ($1.isAudible ? 0 : 1, $1.title) }
    }

    var hasBrowserTabs: Bool {
        !browsers.tabs.isEmpty
    }

    /// Offers per-tab control under a browser that is playing but has no extension yet.
    func suggestsTabControl(for app: AudioApp) -> Bool {
        !preferences.hidesTabControlSuggestion
            && BrowserIntegration.isBrowser(app.id)
            && !browsers.connectedApps.contains(app.id)
            && activity.isActive(app.id)
    }

    func isBrowser(_ app: AudioApp) -> Bool {
        BrowserIntegration.isBrowser(app.id)
    }

    func setTabLevel(_ level: Double, for id: BrowserTab.ID) {
        updateTab(id) { tab in
            tab.level = abs(level - 1) < Self.unitySnapDistance ? 1 : min(max(level, 0), maximumLevel)
            tab.isMuted = false
        }
    }

    func toggleTabMute(_ id: BrowserTab.ID) {
        updateTab(id) { $0.isMuted.toggle() }
    }

    func resetTab(_ id: BrowserTab.ID) {
        updateTab(id) { tab in
            tab.level = 1
            tab.isMuted = false
        }
    }

    func showBrowserSetup(for browser: AudioApp? = nil) {
        router?.showBrowserSetup(for: browser)
    }

    func hideTabControlSuggestion() {
        preferences.hidesTabControlSuggestion = true
    }

    /// Applies the change locally right away (the slider must not lag), then tells the browser.
    private func updateTab(_ id: BrowserTab.ID, _ change: (inout BrowserTab) -> Void) {
        guard let index = browsers.tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&browsers.tabs[index])
        browserBridge.send(.setVolume(browsers.tabs[index].volume, for: id))
    }

    // MARK: - App volume intents

    func setLevel(_ level: Double, for id: AppID) {
        let snapped = abs(level - 1) < Self.unitySnapDistance ? 1 : level
        apply(AppVolume(level: snapped, isMuted: false), to: id, persist: false)
    }

    /// Called when a slider drag ends, so a drag writes to disk once.
    func commitVolumes() {
        store.saveVolumes(volumes)
    }

    func toggleMute(_ id: AppID) {
        var volume = volume(for: id)
        volume.isMuted.toggle()
        apply(volume, to: id, persist: true)
    }

    func reset(_ id: AppID) {
        apply(.unity, to: id, persist: true)
    }

    /// Back to 100 % and the system output for every app.
    func resetAll() {
        for id in volumes.keys {
            engine.send(.setVolume(.unity, for: id))
        }
        for id in routes.keys {
            engine.send(.setOutputRoute(nil, for: id))
        }
        volumes.removeAll()
        routes.removeAll()
        store.saveVolumes(volumes)
        store.saveRoutes(routes)
    }

    private func apply(_ volume: AppVolume, to id: AppID, persist: Bool) {
        volumes[id] = volume.isNeutral ? nil : volume
        engine.send(.setVolume(volume, for: id))
        if persist {
            store.saveVolumes(volumes)
        }
        if !volume.isNeutral, permission == .undetermined {
            requestPermission()
        }
    }

    // MARK: - System output intents

    func setSystemVolume(_ level: Float) {
        snapshot.systemVolume.level = level // Optimistic; the engine confirms through the next snapshot.
        engine.send(.setSystemVolume(level))
    }

    func toggleSystemMute() {
        guard let muted = snapshot.systemVolume.isMuted else { return }
        snapshot.systemVolume.isMuted = !muted
        engine.send(.setSystemMuted(!muted))
    }

    func selectOutputDevice(_ id: AudioDeviceID) {
        engine.send(.selectOutputDevice(id))
    }

    // MARK: - Permission

    func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        Task {
            _ = await permissionProvider.request()
            isRequestingPermission = false
            refreshPermission()
        }
    }

    /// Re-reads the permission, e.g. when the panel opens after the user visited System Settings.
    func refreshPermission() {
        permission = permissionProvider.status()
        engine.send(.setCaptureAuthorized(permission == .authorized))
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - App lifecycle

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            Self.log.error("Login item update failed: \(error, privacy: .public)")
        }
        launchesAtLogin = loginItem.isEnabled
    }

    func systemDidWake() {
        engine.send(.rebuildTaps)
    }

    func applicationWillOpenPanel() {
        refreshPermission()
        // Batteries drain while the panel is closed; read them fresh each time it opens.
        if snapshot.outputDevices.contains(where: { $0.transport == .bluetooth }) {
            loadBluetoothDetails(for: snapshot.outputDevices, announcing: [])
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func preferencesDidChange(from oldValue: Preferences) {
        guard preferences != oldValue else { return }
        store.savePreferences(preferences)
        if preferences.duckingGain != oldValue.duckingGain {
            engine.send(.setDucking(preferences.duckingGain))
        }
        if oldValue.allowsBoost, !preferences.allowsBoost {
            for (id, volume) in volumes where volume.level > 1 {
                apply(AppVolume(level: 1, isMuted: volume.isMuted), to: id, persist: false)
            }
            store.saveVolumes(volumes)
        }
    }
}
