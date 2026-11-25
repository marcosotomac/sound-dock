import MezclaCore

/// What the view model needs from an audio engine. `MixerEngine` is the real one; the demo mixer
/// stands in for it when rendering the panel without touching the system's audio.
protocol MixerControlling: Sendable {
    var snapshots: AsyncStream<MixerSnapshot> { get }
    func start(settings: MixerSettings) async
    func send(_ command: MixerCommand)
}

extension MixerEngine: MixerControlling {}

/// What the view model needs from the browser extension link.
protocol BrowserBridging: Sendable {
    var snapshots: AsyncStream<BrowserSnapshot> { get }
    func start() async
    func send(_ command: BrowserCommand)
}

extension BrowserBridge: BrowserBridging {}

/// Where Bluetooth class and battery come from, keyed by Core Audio device UID.
protocol BluetoothDetailsProviding: Sendable {
    func details(for devices: [OutputDevice]) async -> [String: BluetoothDetails]
}

/// What macOS reports through `system_profiler`, matched to Core Audio devices by Bluetooth address.
struct SystemBluetoothDetails: BluetoothDetailsProviding {
    func details(for devices: [OutputDevice]) async -> [String: BluetoothDetails] {
        let bluetooth = devices.filter { $0.transport == .bluetooth }
        guard !bluetooth.isEmpty else { return [:] }
        let connected = await BluetoothDirectory.connectedDevices()
        return Dictionary(uniqueKeysWithValues: bluetooth.compactMap { device in
            BluetoothDirectory.address(fromDeviceUID: device.uid).flatMap { connected[$0] }.map { (device.uid, $0) }
        })
    }
}

/// Navigation the panel cannot do by itself, like leaving the panel to show a window.
@MainActor
protocol PanelRouting: AnyObject {
    func showBrowserSetup()
    /// A brief card under the menu bar when headphones or speakers connect.
    func showConnected(_ device: OutputDevice, symbol: String, battery: BluetoothDetails.Battery?)
}
