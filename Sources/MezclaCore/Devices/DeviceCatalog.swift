import Foundation
import os

/// What macOS knows about a Bluetooth audio device beyond Core Audio: its class, maker and battery.
public struct BluetoothDetails: Equatable, Sendable {
    public struct Battery: Equatable, Sendable {
        public var main: Int?
        public var left: Int?
        public var right: Int?
        public var chargingCase: Int?

        public init(main: Int? = nil, left: Int? = nil, right: Int? = nil, chargingCase: Int? = nil) {
            self.main = main
            self.left = left
            self.right = right
            self.chargingCase = chargingCase
        }

        /// The number worth showing: earbuds report the lower bud, other devices their single battery.
        public var summary: Int? {
            switch (left, right) {
            case let (left?, right?): min(left, right)
            case let (left?, nil): left
            case let (nil, right?): right
            default: main
            }
        }
    }

    public var minorType: String?
    public var vendorID: Int?
    public var productID: Int?
    public var battery: Battery?

    public init(minorType: String? = nil, vendorID: Int? = nil, productID: Int? = nil, battery: Battery? = nil) {
        self.minorType = minorType
        self.vendorID = vendorID
        self.productID = productID
        self.battery = battery
    }
}

/// Reads Bluetooth details through `system_profiler`, which needs no Bluetooth permission prompt.
/// Runs off the main thread and only when the set of output devices changes.
public enum BluetoothDirectory {
    private static let log = Logger(subsystem: "dev.mezcla", category: "bluetooth")

    /// Details of connected Bluetooth devices, keyed by normalized address (`aa-bb-cc-dd-ee-ff`).
    public static func connectedDevices() async -> [String: BluetoothDetails] {
        await Task.detached(priority: .utility) { read() }.value
    }

    /// Core Audio names Bluetooth devices by address: `AC-BD-70-5B-31-BF:output`.
    public static func address(fromDeviceUID uid: String) -> String? {
        let pattern = /([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}/
        return uid.firstMatch(of: pattern).map { normalize(String($0.output.0)) }
    }

    private static func normalize(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    private static func read() -> [String: BluetoothDetails] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("system_profiler failed: \(error, privacy: .public)")
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controller = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = controller["device_connected"] as? [[String: [String: Any]]]
        else { return [:] }

        var devices: [String: BluetoothDetails] = [:]
        for entry in connected {
            for (_, info) in entry {
                guard let address = info["device_address"] as? String else { continue }
                devices[normalize(address)] = BluetoothDetails(
                    minorType: info["device_minorType"] as? String,
                    vendorID: hex(info["device_vendorID"]),
                    productID: hex(info["device_productID"]),
                    battery: battery(info)
                )
            }
        }
        return devices
    }

    private static func battery(_ info: [String: Any]) -> BluetoothDetails.Battery? {
        func percent(_ key: String) -> Int? {
            (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        }
        let battery = BluetoothDetails.Battery(
            main: percent("device_batteryLevelMain"),
            left: percent("device_batteryLevelLeft"),
            right: percent("device_batteryLevelRight"),
            chargingCase: percent("device_batteryLevelCase")
        )
        return battery.summary == nil && battery.chargingCase == nil ? nil : battery
    }

    private static func hex(_ value: Any?) -> Int? {
        (value as? String).flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
    }
}

/// The glyph macOS itself would use for an output: Apple's own symbols for AirPods, Beats and HomePod,
/// and the right kind of device (earbuds, over-ear headphones, speaker, TV) for everything else.
public enum DeviceSymbol {
    private static let appleVendor = 0x004C

    /// Apple product IDs as reported over Bluetooth.
    private static let appleProducts: [Int: String] = [
        0x2002: "airpods", 0x200F: "airpods", 0x2013: "airpods.gen3", 0x2019: "airpods.gen4", 0x201B: "airpods.gen4",
        0x200E: "airpods.pro", 0x2014: "airpods.pro", 0x2024: "airpods.pro", 0x2027: "airpods.pro",
        0x200A: "airpods.max", 0x201F: "airpods.max",
        0x2006: "beats.headphones", 0x2009: "beats.headphones", 0x2017: "beats.headphones", 0x2025: "beats.headphones",
        0x2011: "beats.studiobuds", 0x2016: "beats.studiobuds", 0x2012: "beats.fitpro",
        0x200B: "beats.powerbeats.pro", 0x201D: "beats.powerbeats.pro",
    ]

    public static func name(for device: OutputDevice, details: BluetoothDetails?) -> String {
        let name = device.name.lowercased()
        switch device.transport {
        case .builtIn:
            if name.contains("display") { return "display" }
            return Host.current().localizedName?.lowercased().contains("macbook") == true || name.contains("macbook")
                ? "laptopcomputer" : "desktopcomputer"
        case .bluetooth:
            return bluetoothSymbol(name: name, details: details)
        case .airPlay:
            if name.contains("homepod mini") { return "homepod.mini" }
            if name.contains("homepod") { return "homepod" }
            if name.contains("apple tv") { return "appletv" }
            return name.contains("tv") ? "tv" : "airplayaudio"
        case .hdmi, .displayPort:
            return name.contains("tv") ? "tv" : "display"
        case .usb, .thunderbolt:
            return name.contains("headset") || name.contains("headphone") ? "headphones" : "hifispeaker"
        case .virtual:
            return "waveform"
        case .aggregate:
            return "square.stack.3d.up"
        case .other:
            return "hifispeaker"
        }
    }

    private static func bluetoothSymbol(name: String, details: BluetoothDetails?) -> String {
        if details?.vendorID == appleVendor, let product = details?.productID, let symbol = appleProducts[product] {
            return symbol
        }
        // Names users and makers give are the most reliable signal for everything else.
        if name.contains("airpods max") { return "airpods.max" }
        if name.contains("airpods pro") { return "airpods.pro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("homepod") { return "homepod" }
        if name.contains("beats") { return name.contains("buds") ? "beats.studiobuds" : "beats.headphones" }
        if name.contains("car") || details?.minorType == "Car Audio" { return "car" }

        let earbuds = ["buds", "freebuds", "earbud", "tune flex", "wf-", "liberty", "elite", "pods", "true wireless", "tws"]
        if earbuds.contains(where: name.contains) { return "earbuds" }
        let overEar = ["wh-", "headphone", "max", "qc", "quietcomfort", "momentum", "xm", "studio", "solo", "live 6", "tune 7"]
        if overEar.contains(where: name.contains) { return "headphones.over.ear" }

        switch details?.minorType {
        case "Speaker", "Loudspeaker", "Portable Audio", "HiFi Audio": return "hifispeaker.fill"
        case "Headphones", "Headset", "Hands-Free": return "headphones"
        default: return ["flip", "charge", "boom", "soundlink", "speaker", "pill", "xtreme", "go "].contains(where: name.contains)
            ? "hifispeaker.fill" : "headphones"
        }
    }
}
