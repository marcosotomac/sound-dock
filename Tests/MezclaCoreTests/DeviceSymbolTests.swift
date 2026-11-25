import MezclaCore
import Testing

@Suite("DeviceSymbol")
struct DeviceSymbolTests {
    private func bluetooth(_ name: String) -> OutputDevice {
        OutputDevice(id: 1, uid: "C0-DA-5E-79-C0-F1:output", name: name, transport: .bluetooth)
    }

    @Test(arguments: [
        ("HUAWEI FreeBuds Pro 5", "Headphones", "earbuds"),
        ("FreeBuds 3", "Headphones", "earbuds"),
        ("JBL TUNE FLEX", "Headset", "earbuds"),
        ("JBL Flip 5", "Speaker", "hifispeaker.fill"),
        ("WH-XB910N", "Headset", "headphones.over.ear"),
        ("Marco’s AirPods Pro", "Headphones", "airpods.pro"),
        ("Generic BT Headset", "Headset", "headphones"),
    ])
    func bluetoothDevicesGetTheGlyphMacOSWouldUse(name: String, minorType: String, symbol: String) {
        #expect(DeviceSymbol.name(for: bluetooth(name), details: BluetoothDetails(minorType: minorType)) == symbol)
    }

    @Test func appleProductIDsPickTheExactModel() {
        let renamed = bluetooth("Marco’s Headphones")
        #expect(DeviceSymbol.name(for: renamed, details: BluetoothDetails(vendorID: 0x004C, productID: 0x200A)) == "airpods.max")
        #expect(DeviceSymbol.name(for: renamed, details: BluetoothDetails(vendorID: 0x004C, productID: 0x2012)) == "beats.fitpro")
    }

    @Test func airPlayAndDisplays() {
        #expect(DeviceSymbol.name(for: OutputDevice(id: 2, uid: "a", name: "Living Room HomePod mini", transport: .airPlay), details: nil) == "homepod.mini")
        #expect(DeviceSymbol.name(for: OutputDevice(id: 3, uid: "b", name: "LG TV", transport: .hdmi), details: nil) == "tv")
        #expect(DeviceSymbol.name(for: OutputDevice(id: 4, uid: "c", name: "Studio Display", transport: .displayPort), details: nil) == "display")
    }

    @Test func bluetoothAddressComesFromTheCoreAudioUID() {
        #expect(BluetoothDirectory.address(fromDeviceUID: "C0-DA-5E-79-C0-F1:output") == "c0-da-5e-79-c0-f1")
        #expect(BluetoothDirectory.address(fromDeviceUID: "BuiltInSpeakerDevice") == nil)
    }

    @Test func earbudsReportTheLowerBud() {
        #expect(BluetoothDetails.Battery(left: 80, right: 65, chargingCase: 100).summary == 65)
        #expect(BluetoothDetails.Battery(main: 42).summary == 42)
    }
}
